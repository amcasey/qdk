#!/usr/bin/env bash
# Appends this job's disk use to the job summary, measured from the baseline setup-podman.sh
# recorded, and warns when the peak exceeds the 14 GB of SSD GitHub documents for standard
# runners. Hosts often have more, but only the documented amount is guaranteed.
set -euo pipefail

budget=14000000000
used=$(df --output=used -B1 "$SANDBOX_SCRATCH" | tail -n 1)
peak=$(cat "$SANDBOX_SCRATCH/disk-peak" 2>/dev/null || echo 0)
((peak > used)) || peak=$used
current=$((used - SANDBOX_DISK_BASELINE))
peak=$((peak - SANDBOX_DISK_BASELINE))
gb() { awk -v bytes="$1" 'BEGIN { printf "%.1f GB", bytes / 1e9 }'; }

# Inside Podman's user namespace, so files owned by subordinate IDs are counted too. Each path
# is measured separately: one du would count files under storage only once, not per subfolder.
breakdown=$(podman unshare sh -c 'for path in "$@"; do du -s --block-size=1M "$path"; done' sh \
    "$SANDBOX_SCRATCH"/* "$SANDBOX_SCRATCH"/storage/* "$GITHUB_WORKSPACE" 2>/dev/null || true)
layers=$(find "$SANDBOX_SCRATCH/storage/overlay" -mindepth 1 -maxdepth 1 -type d ! -name l 2>/dev/null | wc -l)

{
    echo "- Disk used by this job: $(gb "$peak") at peak, $(gb "$current") at the end (documented runner SSD: 14 GB)"
    podman system df --format '  - Podman {{.Type}}: {{.Size}}' 2>/dev/null || true
    echo "  - Overlay layer directories: $layers"
    echo "  - At the end, in MB:"
    sort -rn <<< "$breakdown" | awk -v scratch="$SANDBOX_SCRATCH/" -v workspace="$GITHUB_WORKSPACE" '
        $1 > 0 {
            path = $2
            if (path == workspace) path = "checkout"
            else if (index(path, scratch) == 1) path = substr(path, length(scratch) + 1)
            printf "    - %s: %s\n", path, $1
        }'
} >> "$GITHUB_STEP_SUMMARY"
if ((peak > budget)); then
    echo "::warning::This job used $(gb "$peak") of disk at peak, more than the 14 GB GitHub documents for its runner."
fi
