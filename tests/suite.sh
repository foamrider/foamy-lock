#!/bin/bash
# foamy-lock's own tests; tests/validate.sh runs this after the linters.
#   --ci    no Quickshell, no Omarchy host: the node tests and artwork_test.py
#           (the committed helper as a process; its sandbox cases skip
#           without user namespaces, the real decoder without ImageMagick)
#   --fast  skip the offscreen tests (artwork_runtime.py, the kit's i18n
#           check and tests/harness.sh's suites)
# The offscreen runs keep their temporary trees under one directory, removed
# when everything passed and named when something failed (the evidence).
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1
ci=0 fast=0
for arg in "$@"; do
  case $arg in
    --ci) ci=1 ;;
    --fast) fast=1 ;;
    *)
      echo "suite.sh: unknown argument $arg" >&2
      exit 2
      ;;
  esac
done
status=0
run() {
  echo "== $*"
  "$@" || status=1
}
skip() { echo "SKIP $*"; }

run node --test tests/*.test.cjs
run python3 -I -B -m unittest discover -s tests -p artwork_test.py
# The aarch64 helper runs through qemu-user's binfmt handler.
if [[ -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]]; then
  FOAMY_HELPER='["bin/aarch64/foamy-lock-helper"]' run python3 -I -B -m unittest discover -s tests -p artwork_test.py
else
  skip "the aarch64 helper: no qemu-aarch64 binfmt handler"
fi
if ((ci)); then
  skip "the harness's unit tests: Rust (tests/harness) isn't on the CI runner"
  skip "artwork_runtime.py, the i18n check, tests/harness.sh: offscreen Quickshell"
  exit $status
fi
export CARGO_TARGET_DIR=${CARGO_TARGET_DIR:-${FOAMY_NATIVE_CACHE:-$HOME/.cache/foamy-native}/foamy-lock-harness}
run cargo test --quiet --manifest-path tests/harness/Cargo.toml
if ((fast)); then
  skip "artwork_runtime.py, the i18n check, tests/harness.sh: offscreen Quickshell (--fast)"
  exit $status
fi
# A short name: Quickshell's IPC socket lies four levels below each run's
# tree, and a Unix socket path has room for 107 bytes.
TMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/fls-XXXX") || exit 1
export TMPDIR
unset LD_LIBRARY_PATH
# Both use foamy-kit's preview helpers (harness, hostenv, i18n_runtime).
kit=${FOAMY_KIT:-$HOME/GitHub/Personal/foamy-kit}
if [[ -f $kit/preview/i18n_runtime.py ]]; then
  export FOAMY_KIT=$kit
  run python3 -I -B tests/artwork_runtime.py
  run python3 "$kit/preview/i18n_runtime.py" .
else
  skip "artwork_runtime.py, the i18n check: no foamy-kit at $kit (set FOAMY_KIT)"
fi
for suite in render parity layout runtime studio video; do
  run bash tests/harness.sh "$suite"
done
if ((status)); then
  echo "suite.sh: the offscreen runs' trees are in $TMPDIR"
else
  rm -rf -- "$TMPDIR"
fi
exit $status
