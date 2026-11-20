#!/bin/bash
# The login screen's theme in the real greeter (development only): a theme
# folder assembled in a temporary directory from sddm/bundle.txt (mapped as
# stage maps it: sddm/X is X), a fixture snapshot (tests/greeter/
# snapshot.cjs, stage's schema) with a fixture picture and avatar, and
# theme.conf written as the publisher writes it (`snapshot="…"`, each \ as
# \\ and each " as \"). It runs `sddm-greeter-qt6 --test-mode --theme DIR`
# with a test-only MainScript (tests/greeter/Shot.qml) that loads the real
# Main.qml, sets the state and saves a PNG.
#   tests/greeter.sh [--preset NAME] [--size WxH] [--colors dark|light]
#                    [--language CODE] [--failed] [--typed] [--long-name]
#                    [--snapshot good|broken|none] [--window] [--out FILE]
# Offscreen (QT_QPA_PLATFORM=offscreen, software rendering) by default;
# --window draws it as Wayland windows on the desktop (GPU) for a few
# seconds, then stops it. Nonzero when the greeter fails, logs a QML warning
# from the theme, or saves no picture. The folder is removed afterwards
# unless the run failed (then its path is printed).
set -euo pipefail
root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
preset=foamy size=1920x1080 colors=dark language=en snapshot=good
failed=false typed=false long=false window=false out=""
while (($#)); do
  case $1 in
    --preset) preset=${2:?--preset needs a name} && shift ;;
    --size) size=${2:?--size needs WxH} && shift ;;
    --colors) colors=${2:?--colors needs dark or light} && shift ;;
    --language) language=${2:?--language needs a code} && shift ;;
    --snapshot) snapshot=${2:?--snapshot needs good, broken or none} && shift ;;
    --failed) failed=true ;;
    --typed) typed=true ;;
    --long-name) long=true ;;
    --window) window=true ;;
    --out) out=${2:?--out needs a file} && shift ;;
    *)
      echo "greeter.sh: unknown argument $1" >&2
      exit 2
      ;;
  esac
  shift
done
if [[ ! $size =~ ^([0-9]{3,4})x([0-9]{3,4})$ ]]; then
  echo "greeter.sh: --size must be WxH, not $size" >&2
  exit 2
fi
width=${BASH_REMATCH[1]} height=${BASH_REMATCH[2]}
case $snapshot in good | broken | none) ;; *)
  echo "greeter.sh: --snapshot must be good, broken or none" >&2
  exit 2
  ;;
esac
greeter=/usr/bin/sddm-greeter-qt6
for tool in "$greeter" node magick; do
  command -v "$tool" >/dev/null || {
    echo "greeter.sh: $tool is missing" >&2
    exit 1
  }
done

tmp=$(mktemp -d "${TMPDIR:-/tmp}/foamy-greeter-XXXXXX")
theme=$tmp/theme
mkdir -p "$theme" "$tmp/home" "$tmp/runtime"
chmod 700 "$tmp/runtime"
[[ -n $out ]] || out=$tmp/shot.png

# The bundle, mapped as stage maps it.
while IFS= read -r line || [[ -n $line ]]; do
  line=${line#"${line%%[![:space:]]*}"}
  line=${line%"${line##*[![:space:]]}"}
  [[ -z $line || $line == \#* ]] && continue
  target=${line#sddm/}
  mkdir -p "$theme/$(dirname "$target")"
  cp -- "$root/$line" "$theme/$target"
done <"$root/sddm/bundle.txt"

# The pictures stage copies: the fixture wallpaper at the screen's size
# (as the helper prepares it) and a plain avatar.
magick -size "${width}x${height}" -background none "$root/tests/harness/fixtures/wallpaper.svg" -resize "${width}x${height}!" "PNG24:$theme/background.png"
magick -size 256x256 "gradient:#f6c177-#eb6f92" "PNG24:$theme/avatar.png"

case $snapshot in
  good) json=$(node "$root/tests/greeter/snapshot.cjs" "$preset" "$colors" "$language" true) ;;
  broken) json='{"version": 1, "look": ' ;;
  none) json="" ;;
esac
# QSettings' quoted string: each \ as \\, each " as \".
quote() {
  local text=${1//\\/\\\\}
  printf '"%s"' "${text//\"/\\\"}"
}
name="Ada Lovelace"
$long && name="Augusta Ada King-Noel, Countess of Lovelace and Baroness Wentworth of Nettlestead"
{
  echo "[General]"
  [[ $snapshot == none ]] || echo "snapshot=$(quote "$json")"
  echo "testWidth=$(quote "$width")"
  echo "testHeight=$(quote "$height")"
  echo "testOut=$(quote "$out")"
  echo "testUser=$(quote ada)"
  echo "testRealName=$(quote "$name")"
  echo "testAvatar=$(quote "$theme/avatar.png")"
  echo "testFailed=$(quote "$failed")"
  echo "testTyped=$(quote "$typed")"
  $window && echo "testSettle=$(quote 4000)"
} >"$theme/theme.conf"
# The test's MainScript in place of Main.qml (which it loads).
cp -- "$root/tests/greeter/Shot.qml" "$theme/Shot.qml"
sed -i 's/^MainScript=.*/MainScript=Shot.qml/' "$theme/metadata.desktop"

env=(HOME="$tmp/home" XDG_CONFIG_HOME="$tmp/home/.config" XDG_CACHE_HOME="$tmp/home/.cache"
  XDG_DATA_HOME="$tmp/home/.local/share" LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8)
if $window; then
  env+=(XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:?}" WAYLAND_DISPLAY="${WAYLAND_DISPLAY:?--window needs a Wayland session}" QT_QPA_PLATFORM=wayland)
else
  env+=(XDG_RUNTIME_DIR="$tmp/runtime" QT_QPA_PLATFORM=offscreen QT_QUICK_BACKEND=software)
fi
# The greeter's QML can't quit it (QQmlEngine::quit has no receiver in
# sddm-greeter), so the run ends when Shot.qml reports, or at 60 s; then
# the greeter is stopped by its PID.
: >"$tmp/log"
env -i PATH="$PATH" "${env[@]}" QT_FORCE_STDERR_LOGGING=1 "$greeter" --test-mode --theme "$theme" >"$tmp/log" 2>&1 &
pid=$!
status=0
timeout 60s grep -q -m1 -E "GREETER_SHOT|GREETER_FAIL" <(tail -F --pid="$pid" "$tmp/log" 2>/dev/null) || status=$?
kill "$pid" 2>/dev/null || true
wait "$pid" 2>/dev/null || true

# Warnings from the theme's own QML fail the run; a broken or missing
# snapshot must say it shows the default look.
problems=$(grep -E "file://$theme/.*(Warning|Error|error|warning|TypeError|ReferenceError|Unable|Cannot)|GREETER_FAIL" "$tmp/log" | grep -v "Foamy Lock login screen:" || true)
if [[ $snapshot != good ]] && ! grep -q "showing the default look" "$tmp/log"; then
  problems+=$'\n'"no 'showing the default look' warning for a $snapshot snapshot"
fi
if ! grep -q "GREETER_SHOT saved" "$tmp/log"; then
  problems+=$'\n'"no picture saved (wait status $status)"
fi
grep -E "GREETER_(STATE|GEOMETRY)|Foamy Lock login screen:" "$tmp/log" | sed 's/^/  /' || true
if [[ -n ${problems//$'\n'/} ]]; then
  echo "greeter.sh: $preset $size $colors failed:" >&2
  printf '%s\n' "$problems" | sed '/^$/d; s/^/  /' >&2
  echo "greeter.sh: the theme and log are in $tmp" >&2
  exit 1
fi
echo "greeter.sh: $preset $size $colors -> $out"
rm -rf -- "$tmp"
