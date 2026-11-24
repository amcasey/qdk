#!/usr/bin/env bash
# Prepares rootless Podman on a GitHub-hosted Ubuntu runner for the sandbox prototype workflow,
# and reports the host facts the sandbox depends on. Fails fast, before any long image build,
# if a container with the sandbox's restrictions can't start.
set -euo pipefail

relax_userns=${1:-false}
# Experiment: fuse-overlayfs presents image layers under another ID mapping without copying them.
fuse_overlayfs=${2:-false}
uid=$(id -u)
here=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)

group() { printf '::group::%s\n' "$1"; }
endgroup() { printf '::endgroup::\n'; }

group "Host"
uname -a
grep -E '^(PRETTY_NAME|VERSION_ID)=' /etc/os-release
echo "CPUs: $(nproc)"
free -h
df -h / /mnt 2>/dev/null || df -h /
for name in kernel.apparmor_restrict_unprivileged_userns user.max_user_namespaces; do
    sysctl "$name" 2>/dev/null || echo "$name: unavailable"
done
grep -H "^$USER:" /etc/subuid /etc/subgid || echo "No subordinate ID ranges for $USER"
podman --version
endgroup

if [[ $relax_userns == true ]]; then
    group "Relaxing the AppArmor user-namespace restriction"
    sudo sysctl -w kernel.apparmor_restrict_unprivileged_userns=0
    endgroup
fi

group "Packages"
missing=()
for tool in newuidmap:uidmap slirp4netns:slirp4netns pasta:passt zstd:zstd; do
    command -v "${tool%%:*}" >/dev/null || missing+=("${tool#*:}")
done
# Podman's systemd cgroup manager talks to the user session over D-Bus.
[[ -e /usr/lib/systemd/user/dbus.socket ]] || missing+=(dbus-user-session)
if [[ $fuse_overlayfs == true ]] && ! command -v fuse-overlayfs >/dev/null; then
    missing+=(fuse-overlayfs)
fi
if ((${#missing[@]})); then
    sudo apt-get update -qq
    sudo apt-get install -y -qq --no-install-recommends "${missing[@]}"
else
    echo "All required packages are present."
fi
if ! grep -q "^$USER:" /etc/subuid || ! grep -q "^$USER:" /etc/subgid; then
    sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"
fi
endgroup

# Storage must be configured before Podman first initializes it. It stays on the runner's
# temporary directory: plan against the documented runner SSD, not any extra space a host has.
group "Storage"
scratch=$RUNNER_TEMP/sandbox
mkdir -p "$scratch/storage" "$HOME/.config/containers"
printf '[storage]\ndriver = "overlay"\ngraphroot = "%s"\n' "$scratch/storage" \
    > "$HOME/.config/containers/storage.conf"
if [[ $fuse_overlayfs == true ]]; then
    printf '[storage.options.overlay]\nmount_program = "%s"\n' "$(command -v fuse-overlayfs)" \
        >> "$HOME/.config/containers/storage.conf"
    echo "Using fuse-overlayfs."
fi
baseline=$(df --output=used -B1 "$scratch" | tail -n 1)
# Leave TMPDIR alone: the crun with Podman 5.7 (ubuntu-26.04) puts mount points there, and a
# TMPDIR under /home/runner is out of reach of containers that don't map the runner's user,
# such as the proxy.
{
    echo "SANDBOX_SCRATCH=$scratch"
    echo "SANDBOX_DISK_BASELINE=$baseline"
} >> "$GITHUB_ENV"
echo "Podman storage: $scratch/storage"
# Record the peak disk use until the job ends; disk-report.sh reads it.
nohup bash -c '
peak=0
while :; do
    used=$(df --output=used -B1 "$1" | tail -n 1)
    if ((used > peak)); then
        peak=$used
        echo "$peak" > "$2.tmp" && mv "$2.tmp" "$2"
    fi
    sleep 2
done' sampler "$scratch" "$scratch/disk-peak" > /dev/null 2>&1 &
endgroup

# Rootless resource limits such as --pids-limit need cgroup delegation from a systemd user session.
group "User session"
sudo loginctl enable-linger "$USER"
for _ in $(seq 100); do
    [[ -S /run/user/$uid/bus ]] && break
    sleep 0.1
done
export XDG_RUNTIME_DIR=/run/user/$uid
echo "XDG_RUNTIME_DIR=$XDG_RUNTIME_DIR" >> "$GITHUB_ENV"
if [[ -S $XDG_RUNTIME_DIR/bus ]]; then
    export DBUS_SESSION_BUS_ADDRESS=unix:path=$XDG_RUNTIME_DIR/bus
    echo "DBUS_SESSION_BUS_ADDRESS=$DBUS_SESSION_BUS_ADDRESS" >> "$GITHUB_ENV"
else
    echo "::warning::No user D-Bus session for $USER; Podman may fall back to cgroupfs, which can't apply limits."
fi
controllers=/sys/fs/cgroup/user.slice/user-$uid.slice/user@$uid.service/cgroup.controllers
echo "Delegated controllers: $(cat "$controllers" 2>/dev/null || echo unknown)"
endgroup

group "Podman"
podman info --format json | python3 -c '
import json, sys
info = json.load(sys.stdin)
host, store = info.get("host", {}), info.get("store", {})
security = host.get("security", {})
for name, value in (
    ("version", info.get("version", {}).get("Version")),
    ("rootless", security.get("rootless")),
    ("seccomp", security.get("seccompEnabled")),
    ("cgroups", host.get("cgroupVersion")),
    ("cgroup manager", host.get("cgroupManager")),
    ("OCI runtime", host.get("ociRuntime", {}).get("name")),
    ("rootless network", host.get("rootlessNetworkCmd") or "unreported (launcher assumes slirp4netns)"),
    ("graph root", store.get("graphRoot")),
):
    print(f"{name}: {value}")
'
endgroup

# The restrictions the launcher applies to the agent, on the base image the build uses.
group "Smoke test"
podman run --rm --pull=missing --network=none --pids-limit=64 --cap-drop=ALL \
    --security-opt=no-new-privileges --security-opt="seccomp=$here/../seccomp.json" \
    --userns=keep-id:uid=1000,gid=1000 --user 1000:1000 \
    mcr.microsoft.com/azurelinux/base/core:3.0 sh -c 'echo "Restricted container: uid $(id -u)"'
endgroup
