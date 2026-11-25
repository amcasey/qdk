#!/usr/bin/env bash
# Fetches the crates of each extra revision build_images.py snapshotted under /extra-deps, such as
# the other end of a review, into CARGO_HOME. cargo fetch runs no package code. With --offline,
# it only checks that every crate is already present.
set -euo pipefail
shopt -s nullglob
for manifest in /extra-deps/*/Cargo.toml; do
    echo "Fetching crates for ${manifest%/Cargo.toml} $*"
    cargo fetch --locked "$@" --manifest-path "$manifest"
done
