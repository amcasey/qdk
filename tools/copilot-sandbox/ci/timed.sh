#!/usr/bin/env bash
# Runs a command and appends its wall-clock duration to the job summary.
# Usage: timed.sh LABEL COMMAND [ARGUMENTS...]
set -euo pipefail

label=$1
shift
start=$SECONDS
status=0
"$@" || status=$?
outcome=ok
((status == 0)) || outcome="exit $status"
echo "- $label: $((SECONDS - start)) s ($outcome)" >> "$GITHUB_STEP_SUMMARY"
exit "$status"
