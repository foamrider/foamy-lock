#!/bin/bash
# The offscreen QML tests (tests/harness, Rust, development only):
#   tests/harness.sh render [--host 4.5] [--language CODE]
#   tests/harness.sh parity [--host 4.5] [--baseline REV]
#   tests/harness.sh layout [--host 4.5] [--preset NAME]
#   tests/harness.sh styles [--host 4.5]
#   tests/harness.sh placement [--host 4.5]
#   tests/harness.sh runtime [--host 4.5]
#   tests/harness.sh thumbnails [--host 4.5] [--preset NAME]... [--out DIR]
#   tests/harness.sh studio [--host 4.5] [--language CODE]
# Builds the harness outside the plugin, like foamy-kit's build-native.sh
# (never a target/ inside the plugin), and runs it. parity needs git history.
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-${FOAMY_NATIVE_CACHE:-$HOME/.cache/foamy-native}/foamy-lock-harness}
cd "$root"
exec cargo run --quiet --manifest-path tests/harness/Cargo.toml -- "$@"
