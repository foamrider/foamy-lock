#!/bin/bash
# Tests for sddm/foamy-lock-login-screen, the login-screen publisher, without
# root: FOAMY_LOCK_PUBLISH_ROOT points every system path into a temporary
# root per case, and the publisher then runs its transaction text without
# pkexec or setpriv. Staging folders come from the committed helper
# (`studio login-screen stage`), or are made by hand for the snapshot
# escapes. `status` (the helper) reads the result back where it matters.
#   tests/login-screen-publish.sh [CASE…]
# Nonzero when a case fails. The temporary tree is removed afterwards.
set -uo pipefail
cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")/.." || exit 1
repo=$PWD
publisher=$repo/sddm/foamy-lock-login-screen
helper=$repo/bin/x86_64/foamy-lock-helper
for tool in jq flock setpriv sha256sum python3 "$helper"; do
  command -v "$tool" >/dev/null || {
    echo "login-screen-publish.sh: $tool is missing" >&2
    exit 1
  }
done
tmp=$(mktemp -d "${TMPDIR:-/tmp}/foamy-publish-XXXXXX") || exit 1
tmp=$(realpath -e -- "$tmp")
# A case may leave a read-only folder behind; make it removable first.
trap 'chmod -R u+rwX -- "$tmp" 2>/dev/null; rm -rf -- "$tmp"' EXIT

marker='# Foamy Lock login screen (foamy-lock-login-screen)'
expected_dropin="$marker
[Theme]
Current=foamy-lock
ThemeDir=/usr/share/sddm/themes"

# Each case runs in its own subshell; `fail` ends it.
fail() {
  echo "    $*" >&2
  exit 1
}

# A fresh system root: SDDM's folders (0755, as the checks need), SDDM as
# the display manager (for status), and the user's runtime folder.
new_root() {
  root=$tmp/$1
  themes=$root/usr/share/sddm/themes
  confd=$root/etc/sddm.conf.d
  theme=$themes/foamy-lock
  dropin=$confd/99-zz-foamy-lock.conf
  runtime=$root/run/user/$EUID
  mkdir -p -- "$themes" "$confd" "$runtime" "$root/etc/systemd/system" "$root/usr/bin" "$root/cache"
  chmod 0755 -- "$root" "$root/usr" "$root/usr/share" "$root/usr/share/sddm" "$themes" "$root/etc" "$confd"
  chmod 0700 -- "$runtime"
  ln -s /usr/lib/systemd/system/sddm.service "$root/etc/systemd/system/display-manager.service"
  printf '#!/bin/sh\nexit 0\n' >"$root/usr/bin/sddm-greeter-qt6"
  chmod 0755 -- "$root/usr/bin/sddm-greeter-qt6"
}

colors=$(jq -cn '["background", "foreground", "accent", "muted", "urgent",
  "lockBackground", "lockBorder", "lockBorderError", "lockPlaceholder",
  "lockSelection", "lockText", "lockTextError", "popupsBackground",
  "popupsBorder", "popupsText", "warning", "success", "error", "info"]
  | map({(.): "#1a2b3c"}) | add')

# A staging folder from the real helper; $1 is a jq filter on the request.
# Sets stage_dir and stage_hash.
stage() {
  local avatar=$root/cache/omarchy/foamy.lock/avatar.png request reply
  mkdir -p -- "${avatar%/*}"
  python3 -I -c 'import sys; sys.path.insert(0, sys.argv[1]); import png_fixture as p
sys.stdout.buffer.write(p.encode_png(bytes(range(256)) * 768))' "$repo/tests" >"$avatar"
  request=$(jq -cn --argjson colors "$colors" --arg avatar "$avatar" '{
    look: {preset: "foamy", layout: {}}, showsPicture: false,
    timeFormat: "24h", showUserInfo: true, language: "nb",
    formatLocale: "nb-NO", rightToLeft: false, colors: $colors,
    lockThemed: ["lockText"], background: null, avatar: $avatar}' | jq -c "${1:-.}")
  reply=$(FOAMY_LOCK_PLUGIN_DIR=$repo XDG_RUNTIME_DIR=$runtime XDG_CACHE_HOME=$root/cache \
    "$helper" studio login-screen stage <<<"$request")
  jq -e .ok <<<"$reply" >/dev/null || fail "stage failed: $reply"
  stage_dir=$(jq -r .dir <<<"$reply")
  stage_hash=$(jq -r .hash <<<"$reply")
}

# A staging folder made by hand from name=text pairs, with a valid manifest
# (stage's hash rule). Sets stage_dir.
hand_stage() {
  local pair name text lines="plugin 9.9.9"$'\n' entries=() size sha
  stage_dir=$runtime/foamy-lock/login-screen/stage-hand0001
  mkdir -p -- "$stage_dir"
  for pair in "$@"; do
    name=${pair%%=*} text=${pair#*=}
    mkdir -p -- "$(dirname -- "$stage_dir/$name")"
    printf '%s' "$text" >"$stage_dir/$name"
    size=$(stat -c %s -- "$stage_dir/$name")
    sha=$(sha256sum -- "$stage_dir/$name")
    sha=${sha%% *}
    lines+="$name $size $sha"$'\n'
    entries+=("$(jq -cn --arg n "$name" --argjson s "$size" --arg h "$sha" '{name: $n, size: $s, sha256: $h}')")
  done
  local hash
  hash=$(printf '%s' "$lines" | sha256sum)
  printf '%s\n' "${entries[@]}" | jq -cs --arg hash "${hash%% *}" \
    '{version: 1, plugin: "9.9.9", hash: $hash, files: .}' >"$stage_dir/manifest.json"
}

# Sets out and rc. Never without a test root: the publisher would ask
# pkexec for the real system.
publish() {
  [[ ${root-} == "$tmp"/?* ]] || fail "no test root"
  out=$(FOAMY_LOCK_PUBLISH_ROOT=$root "$publisher" "$@" 2>"$tmp/stderr")
  rc=$?
}

# `ok`, or the error code the reply must carry, with exit 0 or 1 and one
# JSON line; $2, when given, must appear in the error text.
expect() {
  local lines
  lines=$(printf '%s\n' "$out" | wc -l)
  ((lines == 1)) || fail "expected one line, got: $out"
  if [[ $1 == ok ]]; then
    ((rc == 0)) || fail "exit $rc, reply $out ($(cat "$tmp/stderr"))"
    jq -e '. == {"ok": true}' <<<"$out" >/dev/null || fail "reply $out"
  else
    ((rc == 1)) || fail "exit $rc, expected 1; reply $out"
    jq -e --arg code "$1" '.ok == false and .code == $code and (.error | type) == "string"' \
      <<<"$out" >/dev/null || fail "expected $1, got $out"
    if [[ -n ${2-} ]]; then
      jq -e --arg text "$2" '.error | contains($text)' <<<"$out" >/dev/null \
        || fail "expected the error to mention \"$2\", got $out"
    fi
  fi
}

# Every path under usr and etc with its type, mode and content hash.
system_state() {
  (
    cd "$root" || exit 1
    find usr etc -printf '%p %y %m %l\n' | sort
    find usr etc -type f -exec sha256sum -- {} + | sort
  )
}

status() {
  FOAMY_LOCK_SYSTEM_ROOT=$root "$helper" studio login-screen status
}

# The snapshot that theme.conf carries, unescaped as QSettings reads a
# quoted value, against snapshot.json.
expect_theme_conf() {
  python3 -I - "$theme" <<'EOF' || fail "theme.conf doesn't carry snapshot.json"
import json, re, sys
theme = sys.argv[1]
lines = open(f"{theme}/theme.conf", encoding="utf-8").read().split("\n")
assert lines[0] == "[General]" and lines[2:] == [""], lines
assert lines[1].startswith('snapshot="') and lines[1].endswith('"'), lines[1]
value = re.sub(r'\\(.)', r"\1", lines[1][len('snapshot="'):-1])
assert json.loads(value) == json.load(open(f"{theme}/snapshot.json", encoding="utf-8"))
EOF
}

# Folders 0755, files 0644, nothing else, no symlinks.
expect_modes() {
  local bad
  bad=$(find "$theme" \( -type d ! -perm 0755 \) -o \( -type f ! -perm 0644 \) -o \( ! -type d ! -type f \))
  [[ -z $bad ]] || fail "wrong modes or types: $bad"
}

expect_no_leftovers() {
  local left
  left=$(find "$themes" "$confd" -mindepth 1 -maxdepth 1 -name '.*')
  [[ -z $left ]] || fail "left behind: $left"
}

# The installed manifest: stage's, plus theme.conf; status reads it as
# installed with stage's hash.
expect_installed() {
  local reply
  jq -e --slurpfile staged "$stage_dir/manifest.json" '
    .version == 1 and .hash == $staged[0].hash and .plugin == $staged[0].plugin
    and .files[:-1] == $staged[0].files and .files[-1].name == "theme.conf"' \
    "$theme/manifest.json" >/dev/null || fail "installed manifest.json: $(cat "$theme/manifest.json")"
  reply=$(status)
  jq -e --arg hash "$1" '.state == "installed" and .installed.hash == $hash' <<<"$reply" >/dev/null \
    || fail "status: $reply"
}

case_good_publish() {
  new_root good
  stage
  publish publish "$stage_dir"
  expect ok
  [[ $(cat "$dropin") == "$expected_dropin" ]] || fail "drop-in: $(cat "$dropin")"
  [[ $(stat -c %a -- "$dropin") == 644 ]] || fail "drop-in mode $(stat -c %a -- "$dropin")"
  cmp -s -- "$stage_dir/avatar.png" "$theme/avatar.png" || fail "avatar.png differs"
  cmp -s -- "$stage_dir/Main.qml" "$theme/Main.qml" || fail "Main.qml differs"
  expect_theme_conf
  expect_modes
  expect_installed "$stage_hash"
  expect_no_leftovers
}

# The escapes of the "Step 3 contract", against a fixed text.
case_theme_conf_escapes() {
  new_root escapes
  hand_stage 'snapshot.json={"version":1,"q":"a\"b\\c Ø, d"}' 'Main.qml=Item {}'
  publish publish "$stage_dir"
  expect ok
  local expected
  expected=$(printf '%s\n' '[General]' 'snapshot="{\"version\":1,\"q\":\"a\\\"b\\\\c Ø, d\"}"')
  [[ $(cat "$theme/theme.conf") == "$expected" ]] || fail "theme.conf: $(cat "$theme/theme.conf")"
}

case_second_publish_replaces() {
  new_root second
  stage
  publish publish "$stage_dir"
  expect ok
  stage '.timeFormat = "12h"'
  local second=$stage_hash
  publish publish "$stage_dir"
  expect ok
  jq -e '.timeFormat == "12h"' "$theme/snapshot.json" >/dev/null || fail "the first look is still there"
  expect_theme_conf
  expect_installed "$second"
  expect_no_leftovers
}

case_missing_config_folder() {
  new_root noconfd
  rmdir -- "$confd"
  stage
  publish publish "$stage_dir"
  expect ok
  [[ $(stat -c %a -- "$confd") == 755 ]] || fail "sddm.conf.d mode $(stat -c %a -- "$confd")"
  [[ $(cat "$dropin") == "$expected_dropin" ]] || fail "drop-in: $(cat "$dropin")"
}

case_restore() {
  new_root restore
  stage
  publish publish "$stage_dir"
  expect ok
  publish restore
  expect ok
  [[ ! -e $theme && ! -e $dropin ]] || fail "restore left the theme or drop-in"
  expect_no_leftovers
  jq -e '.state == "not-installed"' <<<"$(status)" >/dev/null || fail "status: $(status)"
  # Nothing there is fine too.
  publish restore
  expect ok
}

# A symlink is read with the user's rights: one to a file with the listed
# content is copied as a plain file; one to other content or to a file the
# user can't read is refused.
case_symlink_same_content() {
  new_root symlink-same
  stage
  cp -- "$stage_dir/LICENSE" "$root/elsewhere"
  rm -- "$stage_dir/LICENSE"
  ln -s -- "$root/elsewhere" "$stage_dir/LICENSE"
  publish publish "$stage_dir"
  expect ok
  [[ -f $theme/LICENSE && ! -L $theme/LICENSE ]] || fail "LICENSE isn't a plain file"
}

case_symlink_other_content() {
  new_root symlink-other
  stage
  printf 'other\n' >"$root/elsewhere"
  rm -- "$stage_dir/LICENSE"
  ln -s -- "$root/elsewhere" "$stage_dir/LICENSE"
  publish publish "$stage_dir"
  expect INVALID_STAGE LICENSE
  [[ ! -e $theme ]] || fail "a theme was published"
  expect_no_leftovers
}

case_symlink_unreadable() {
  new_root symlink-unreadable
  stage
  cp -- "$stage_dir/LICENSE" "$root/secret"
  chmod 0000 -- "$root/secret"
  rm -- "$stage_dir/LICENSE"
  ln -s -- "$root/secret" "$stage_dir/LICENSE"
  publish publish "$stage_dir"
  expect INVALID_STAGE "cannot read LICENSE"
  expect_no_leftovers
}

# A staged file that doesn't match manifest.json; the previous theme stays.
case_file_mismatch() {
  local how
  for how in longer same-size; do
    new_root "mismatch-$how"
    stage
    publish publish "$stage_dir"
    expect ok
    local before
    before=$(system_state)
    stage '.timeFormat = "12h"'
    if [[ $how == longer ]]; then
      printf 'x' >>"$stage_dir/Main.qml"
      publish publish "$stage_dir"
      expect INVALID_STAGE "Main.qml in the staging folder doesn't match its size"
    else
      local size
      size=$(stat -c %s -- "$stage_dir/Main.qml")
      head -c "$size" /dev/zero >"$stage_dir/Main.qml"
      publish publish "$stage_dir"
      expect INVALID_STAGE "Main.qml in the staging folder doesn't match its sha256"
    fi
    [[ $(system_state) == "$before" ]] || fail "$how: the previous theme changed"
  done
}

# Each row: a jq edit of stage's manifest.json, and a word of the error.
bad_manifests=(
  '.extra = 1|unknown key'
  '.files[0].extra = 1|files[0] has an unknown key'
  '.files[1].name = "../x"|files[1] is not a relative path'
  '.files[1].name = "a/./b"|files[1] is not a relative path'
  '.files[1].name = "/abs"|files[1] is not a relative path'
  '.files[1].name = "a/b/c/d/e"|at most 4 levels'
  '.files[1].name = "manifest.json"|is the manifest itself'
  '.files += [range(256) | {name: "f\(.)", size: 0, sha256: ("0" * 64)}]|more than 255 files'
  '.files = [.files[0]] + [range(254) | {name: "f\(.)", size: 0, sha256: ("0" * 64)}]|more than 254 files'
  '.version = 2|unknown version'
  '.files[1].size = 1.0|files[1] has no size'
  '.files[1].size = -1|files[1] has no size'
  '.files[1].sha256 |= ascii_upcase|files[1] has no sha256'
  '.hash |= ascii_upcase|has no hash'
  '.plugin = ""|no plugin version'
  '.files += [.files[1]]|lists a file twice'
  '.files |= map(select(.name != "snapshot.json"))|does not list snapshot.json'
  '.files += [{name: "theme.conf", size: 0, sha256: ("0" * 64)}]|lists theme.conf'
  '.files += [{name: "theme.conf.user", size: 0, sha256: ("0" * 64)}]|lists theme.conf'
  '.files += [{name: "Main.qml/x", size: 0, sha256: ("0" * 64)}]|also a folder'
  '.files[1].size = 26214401|over 25 MiB'
  '.files[0].size = 262145|snapshot.json over 256 KiB'
  '.files += [range(3) | {name: "big\(.)", size: 26214400, sha256: ("0" * 64)}]|more than 64 MiB'
  '.hash = ("0" * 64)|wrong hash'
)

case_bad_manifest() {
  new_root bad-manifest
  stage
  cp -- "$stage_dir/manifest.json" "$root/good-manifest"
  local row edit text before
  before=$(system_state)
  for row in "${bad_manifests[@]}" "not json|isn't JSON" 'two|is not one JSON value'; do
    edit=${row%|*} text=${row##*|}
    case $edit in
      'not json') printf '{"version": 1,' >"$stage_dir/manifest.json" ;;
      two) cat "$root/good-manifest" "$root/good-manifest" >"$stage_dir/manifest.json" ;;
      *) jq -c "$edit" "$root/good-manifest" >"$stage_dir/manifest.json" || fail "bad row: $edit" ;;
    esac
    publish publish "$stage_dir"
    (expect INVALID_STAGE "$text") || fail "row: $edit"
    [[ $(system_state) == "$before" ]] || fail "row $edit changed the system"
  done
  expect_no_leftovers
}

case_bad_snapshot() {
  local snapshot
  for snapshot in '{"version":2}' '[1]' '{"version":1'; do
    new_root "bad-snapshot-${#snapshot}"
    hand_stage "snapshot.json=$snapshot" 'Main.qml=Item {}'
    publish publish "$stage_dir"
    expect INVALID_STAGE snapshot.json
    [[ ! -e $theme ]] || fail "$snapshot: a theme was published"
    expect_no_leftovers
  done
}

case_bad_arguments() {
  new_root arguments
  local args words
  for args in '' 'publish' 'restore extra' 'copy x' "publish $runtime/a $runtime/b"; do
    read -r -a words <<<"$args"
    publish "${words[@]}"
    (expect INVALID_ARGUMENT) || fail "arguments: '$args'"
  done
  local path base=$runtime/foamy-lock/login-screen
  mkdir -p -- "$base/stage-abcdefgh"
  for path in /tmp/stage-abcdefgh "$base/stage-ABCDEFGH" "$base/stage-abc" \
    "$base/stage-abcdefgh/../stage-abcdefgh" "$base/stage-abcdefgh/" \
    "$root/run/user/$((EUID + 1))/foamy-lock/login-screen/stage-abcdefgh" \
    "$base/other-abcdefgh" "stage-abcdefgh"; do
    publish publish "$path"
    (expect INVALID_STAGE "studio login-screen stage") || fail "path: $path"
  done
}

# A folder or drop-in by the same name that isn't ours: refused, untouched.
foreign_cases=(folder-file folder-manifest folder-symlink folder-is-file dropin-foreign dropin-symlink)

make_foreign() {
  case $1 in
    folder-file) mkdir -p -- "$theme" && echo x >"$theme/Main.qml" ;;
    folder-manifest) mkdir -p -- "$theme" && echo '{"version": 1}' >"$theme/manifest.json" ;;
    folder-symlink) mkdir -p -- "$root/real" && ln -s -- "$root/real" "$theme" ;;
    folder-is-file) echo x >"$theme" ;;
    dropin-foreign) printf '[Theme]\nCurrent=foamy-lock\n' >"$dropin" ;;
    dropin-symlink) printf '%s\n' "$marker" >"$root/real-dropin" && ln -s -- "$root/real-dropin" "$dropin" ;;
  esac
}

case_not_ours() {
  local name before mode
  for name in "${foreign_cases[@]}"; do
    for mode in publish restore; do
      new_root "foreign-$name-$mode"
      stage
      # Restore must not remove our half either when the other is foreign.
      if [[ $name == dropin-* && $mode == restore ]]; then
        publish publish "$stage_dir"
        expect ok
        rm -f -- "$dropin"
      fi
      make_foreign "$name"
      before=$(system_state)
      if [[ $mode == publish ]]; then
        publish publish "$stage_dir"
      else
        publish restore
      fi
      (expect NOT_OURS) || fail "$name, $mode"
      [[ $(system_state) == "$before" ]] || fail "$name, $mode: changed the system"
    done
  done
}

# The drop-in can't be written after the new theme is in place: the
# previous theme and drop-in are put back.
case_failure_after_swap() {
  new_root middle
  stage
  publish publish "$stage_dir"
  expect ok
  local before
  before=$(system_state)
  stage '.timeFormat = "12h"'
  chmod 0555 -- "$confd"
  publish publish "$stage_dir"
  chmod 0755 -- "$confd"
  expect IO "cannot write"
  [[ $(system_state) == "$before" ]] || fail "the previous theme changed"
  expect_no_leftovers
}

case_untrusted_folder() {
  new_root untrusted
  stage
  chmod 0775 -- "$themes"
  publish publish "$stage_dir"
  expect IO "not writable by others"
  [[ ! -e $theme ]] || fail "a theme was published"
}

# Another copy or restore holds the theme folder's lock, or a new stage
# holds stage.lock: BUSY after the wait, nothing changed.
case_busy() {
  local which fd before
  for which in themes stage; do
    new_root "busy-$which"
    stage
    before=$(system_state)
    if [[ $which == themes ]]; then
      exec {fd}<"$themes"
    else
      exec {fd}>"${stage_dir%/*}/stage.lock"
    fi
    flock -x "$fd"
    publish publish "$stage_dir"
    exec {fd}>&-
    expect BUSY
    [[ $(system_state) == "$before" ]] || fail "$which: changed the system"
    expect_no_leftovers
  done
}

cases=(good_publish theme_conf_escapes second_publish_replaces missing_config_folder
  restore symlink_same_content symlink_other_content symlink_unreadable file_mismatch
  bad_manifest bad_snapshot bad_arguments not_ours failure_after_swap untrusted_folder busy)
(($#)) && cases=("$@")
failed=()
for name in "${cases[@]}"; do
  if ("case_$name"); then
    echo "ok   $name"
  else
    echo "FAIL $name"
    failed+=("$name")
  fi
done
echo "login-screen-publish.sh: ${#cases[@]} cases, ${#failed[@]} failed ${failed[*]}"
((${#failed[@]} == 0))
