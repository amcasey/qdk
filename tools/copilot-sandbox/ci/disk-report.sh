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

{
    echo "- Disk used by this job: $(gb "$peak") at peak, $(gb "$current") at the end (documented runner SSD: 14 GB)"
    podman system df --format '  - Podman {{.Type}}: {{.Size}}' 2>/dev/null || true
} >> "$GITHUB_STEP_SUMMARY"
if ((peak > budget)); then
    echo "::warning::This job used $(gb "$peak") of disk at peak, more than the 14 GB GitHub documents for its runner."
fi
