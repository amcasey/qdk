#!/usr/bin/env bash
# Experiment: builds each revision offline the way the review kit does (release `qdk` library,
# worktrees sharing one target directory, no incremental compilation) and writes timings, warning
# counts and disk use to /exchange/from_copilot/build-revisions.md, with each build's log.
# Run in the sandbox from /work/qdk: build-revisions.sh REVISION...
set -euo pipefail

output=/exchange/from_copilot
report=$output/build-revisions.md
work=/work/build-revisions
export CARGO_TARGET_DIR=$work/target CARGO_INCREMENTAL=0
mkdir -p "$work" "$output/logs"

{
    echo "# Offline builds"
    echo
    echo "- $(rustc --version)"
    echo "- CPUs: $(nproc)"
    echo "- Cargo home: $(du -sh "$CARGO_HOME" | cut -f1)"
    echo
    echo "| Revision | Commit | Toolchain in ci.yml | Result | Time | Warnings | Target dir after |"
    echo "| --- | --- | --- | --- | --- | --- | --- |"
} > "$report"

status=0
for revision in "$@"; do
    if ! commit=$(git rev-parse --verify --quiet "$revision^{commit}"); then
        git fetch --quiet --no-tags origin main
        commit=$(git rev-parse --verify "$revision^{commit}")
    fi
    short=${commit:0:12}
    tree=$work/$short
    [[ -d $tree ]] || git worktree add --quiet --detach "$tree" "$commit"
    toolchain=$(sed -nE 's/^ *RUST_TOOLCHAIN_VERSION: *"([^"]+)".*/\1/p' "$tree/.github/workflows/ci.yml" | head -n 1)
    log=$output/logs/$short.log
    start=$SECONDS
    result=ok
    (cd "$tree" && cargo build --locked --release -p qdk --lib) > "$log" 2>&1 || {
        result="failed ($?)"
        status=1
    }
    warnings=$(grep -c '^warning: ' "$log" || true)
    echo "| \`$revision\` | $short | ${toolchain:-unknown} | $result | $((SECONDS - start)) s | $warnings | $(du -sh "$CARGO_TARGET_DIR" | cut -f1) |" >> "$report"
done

cat "$report"
exit "$status"
