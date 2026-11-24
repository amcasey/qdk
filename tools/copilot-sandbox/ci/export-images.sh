#!/usr/bin/env bash
# Writes the locally built sandbox image pair to one zstd-compressed archive, for transfer to
# another runner, and appends the sizes to the job summary.
# Usage: export-images.sh DESTINATION_DIRECTORY
set -euo pipefail

destination=$1
agent=copilot-sandbox-agent:local
build_id=$(podman image inspect --format '{{index .Config.Labels "qdk.copilot-sandbox.build-id"}}' "$agent")
if [[ ! $build_id =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*$ ]]; then
    echo "::error::Unexpected sandbox build ID: $build_id"
    exit 1
fi
# The launcher pairs the agent with the proxy tagged with the agent's build ID.
images=("$agent" "copilot-sandbox-proxy:$build_id")
mkdir -p "$destination"
archive=$destination/images.tar.zst
podman save --multi-image-archive --format docker-archive "${images[@]}" | zstd -T0 -q -o "$archive"

mib() { echo "$(($1 / 1048576)) MiB"; }
{
    for image in "${images[@]}"; do
        echo "- $image: $(mib "$(podman image inspect --format '{{.Size}}' "$image")")"
    done
    echo "- Compressed archive: $(mib "$(stat -c %s "$archive")")"
} >> "$GITHUB_STEP_SUMMARY"
