#!/usr/bin/env bash
# Compile the drawn backgrounds' shaders (needs Qt's Shader Baker, qsb):
#   elements/shaders/build.sh
# Run it after changing any .frag, .vert or .glsl here, and commit the .qsb
# files with them. GLSL 330 and ES 300 beside the SPIR-V qsb always writes.
set -euo pipefail
dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
qsb_bin=${QSB:-/usr/lib/qt6/bin/qsb}
if [[ ! -x "$qsb_bin" ]]; then
  printf 'Qt Shader Baker is missing: %s (set QSB to its path)\n' "$qsb_bin" >&2
  exit 1
fi
for source in "$dir"/*.vert "$dir"/*.frag; do
  "$qsb_bin" --glsl '330,300 es' -o "$source.qsb" "$source"
done
