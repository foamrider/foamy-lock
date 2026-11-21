.pragma library
.import "Layout.js" as Layout
// Lock Studio's login-screen copy, the pure part: the replies of the
// helper's `studio login-screen status` and `stage`, of its sandboxed
// `artwork` kinds and of the publisher (`sddm/foamy-lock-login-screen`),
// checked and turned into reports; the `stage` request; the section's state
// and what a look leaves out. No I/O, no QML types: node tests load it
// (tests/studio-login.test.cjs) with Layout.js as `Layout`. LoginScreen.qml
// runs the processes; docs/plans/lock-login-screen.md has the contract.

// `status` states (native/src/studio/login_screen/status.rs).
var STATES = ["unavailable", "not-installed", "installed", "overridden", "broken"]
// The login screen's pictures: at most this size (stage.rs MAX_WIDTH and
// MAX_HEIGHT).
var MAX_WIDTH = 3840
var MAX_HEIGHT = 2160
// The colour keys `stage` takes, in its order (stage.rs COLOR_KEYS).
var COLOR_KEYS = ["background", "foreground", "accent", "muted", "urgent", "lockBackground", "lockBorder",
  "lockBorderError", "lockPlaceholder", "lockSelection", "lockText", "lockTextError", "popupsBackground",
  "popupsBorder", "popupsText", "warning", "success", "error", "info"]
// The `lock*` keys a theme can set itself (LockView's `lockThemed`).
var THEMED_KEYS = ["lockBackground", "lockBorder", "lockPlaceholder", "lockSelection", "lockText"]
// What the login screen leaves out, in the dialog's order.
var LEFT_OUT = ["media", "weather", "status", "system", "video", "fingerprint"]
// The look keys `stage` takes (its check_look; the link to a user preset
// stays in Studio).
var LOOK_KEYS = ["preset", "layout", "background", "glass"]
// Longest theme name and file path shown as they are (the rest is cut with
// "…"): both come from SDDM's config files.
var MAX_THEME_TEXT = 64
var MAX_PATH_TEXT = 256
// Longest avatar path taken from the lock's `status` (PATH_MAX).
var MAX_AVATAR_PATH = 4096

var HASH = /^[0-9a-f]{64}$/
var HEX_COLOR = /^#([0-9a-f]{6}|[0-9a-f]{8})$/
var TAG = /^[A-Za-z0-9_-]{1,35}$/
var CODE = /^[A-Z_]{1,40}$/
var KIND_CODE = /^[a-z-]{1,48}$/

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

// The last line of `text` as a JSON object, or null.
function replyOf(text) {
  var lines = String(text || "").trim().split("\n")
  try {
    var data = JSON.parse(lines[lines.length - 1])
    return isPlainObject(data) ? data : null
  } catch (error) {
    return null
  }
}

// Why a finite job gave no answer: `timeout` stopped it (124, or 137 after
// --kill-after), it couldn't start (-1: Quickshell reports no exit), or
// the bundled helper isn't there for this CPU (126, 127).
function exitProblem(exitCode) {
  if (exitCode === 124 || exitCode === 137) return "timeout"
  // -1: Quickshell couldn't start it; 70: the publisher isn't an executable
  // file (LoginScreen.runPublisher checks before exec).
  if (exitCode === -1 || exitCode === 70) return "start-failed"
  if (exitCode === 126 || exitCode === 127) return "helper-unavailable"
  return ""
}

// A helper failure's code: its own (`IO`, `BACKGROUND_MISSING`, …), else
// "unexpected".
function failureCode(exitCode, data) {
  var problem = exitProblem(exitCode)
  if (problem) return problem
  if (exitCode === 1 && data && data.ok === false && typeof data.code === "string" && CODE.test(data.code)) return data.code
  return "unexpected"
}

function shortText(text, limit) {
  return text.length > limit ? text.slice(0, limit - 1) + "…" : text
}

// `status`'s reply: { ok: true, state, theme, themeSetIn, themeDir,
// autologin, installed: { plugin, hash } | null, managed: { theme, dropin }
// }, or { ok: false, code }. `managed`: Foamy's theme folder and drop-in
// exist, whether SDDM uses them or not.
// Anything off the contract is "unexpected", never a state: a failed check
// must not hide the section.
function statusReport(exitCode, text) {
  var data = replyOf(text)
  if (exitCode !== 0 || !data || data.ok !== true) return { ok: false, code: failureCode(exitCode, data) }
  var bad = { ok: false, code: "unexpected" }
  if (STATES.indexOf(data.state) === -1 || typeof data.theme !== "string" || typeof data.themeDir !== "string"
      || typeof data.autologin !== "boolean") return bad
  if (data.themeSetIn !== null && typeof data.themeSetIn !== "string") return bad
  if (!isPlainObject(data.managed) || typeof data.managed.theme !== "boolean" || typeof data.managed.dropin !== "boolean")
    return bad
  var installed = null
  if (data.installed !== null) {
    if (!isPlainObject(data.installed) || typeof data.installed.plugin !== "string" || !HASH.test(String(data.installed.hash)))
      return bad
    installed = { plugin: data.installed.plugin, hash: data.installed.hash }
  }
  // `installed` comes with exactly these two states (status.rs).
  if ((installed !== null) !== (data.state === "installed" || data.state === "overridden")) return bad
  return {
    ok: true, state: data.state, theme: shortText(data.theme, MAX_THEME_TEXT),
    themeSetIn: data.themeSetIn === null ? null : shortText(data.themeSetIn, MAX_PATH_TEXT),
    themeDir: shortText(data.themeDir, MAX_PATH_TEXT), autologin: data.autologin, installed: installed,
    managed: { theme: data.managed.theme, dropin: data.managed.dropin }
  }
}

// The look shows a picture: an Omarchy wallpaper or a custom image (a
// video's still frame for a video), the preset's own source when the entry
// doesn't say. `look` is an effective look (Layout.parseLook).
function showsPicture(look) {
  var source = look && look.background ? look.background.source : ""
  return source === "omarchy" || source === "picture"
}

// The background's size: the screen's, scaled down (keeping its shape) to
// fit MAX_WIDTH × MAX_HEIGHT; at least 16 a side.
function pictureSize(width, height) {
  var w = Math.max(16, Math.round(Number(width) || 0))
  var h = Math.max(16, Math.round(Number(height) || 0))
  var scale = Math.min(1, MAX_WIDTH / w, MAX_HEIGHT / h)
  return [Math.max(16, Math.min(MAX_WIDTH, Math.round(w * scale))), Math.max(16, Math.min(MAX_HEIGHT, Math.round(h * scale)))]
}

// A colour as `stage` takes it: "#rrggbb" or "#aarrggbb" in lower case
// (a QML colour's text), or "" when it is neither.
function colorText(value) {
  var text = String(value === undefined || value === null ? "" : value).toLowerCase()
  return HEX_COLOR.test(text) ? text : ""
}

// The `stage` request (stage.rs), or { error } naming what is missing.
// `input`: entry (the applied look entry), settings (Model.parseConfig's),
// colors ({ key: QML colour } for COLOR_KEYS), lockThemed, language,
// formatLocale, rightToLeft, background and avatar (paths or "").
function stageRequest(input) {
  var parsed = Layout.parseLook(input.entry)
  if (!parsed.valid) return { error: "look" }
  var colors = {}
  for (var i = 0; i < COLOR_KEYS.length; i++) {
    var value = colorText(input.colors[COLOR_KEYS[i]])
    if (!value) return { error: "color " + COLOR_KEYS[i] }
    colors[COLOR_KEYS[i]] = value
  }
  var themed = []
  for (var t = 0; t < THEMED_KEYS.length; t++) {
    if ((input.lockThemed || []).indexOf(THEMED_KEYS[t]) !== -1) themed.push(THEMED_KEYS[t])
  }
  if (!TAG.test(String(input.language)) || !TAG.test(String(input.formatLocale))) return { error: "language" }
  var picture = showsPicture(parsed.look)
  var look = {}
  for (var key in input.entry) {
    if (LOOK_KEYS.indexOf(key) !== -1) look[key] = input.entry[key]
  }
  return {
    request: {
      look: look,
      showsPicture: picture,
      timeFormat: input.settings.timeFormat === "12h" ? "12h" : "24h",
      showUserInfo: input.settings.showUserInfo !== false,
      language: String(input.language),
      formatLocale: String(input.formatLocale),
      rightToLeft: input.rightToLeft === true,
      colors: colors,
      lockThemed: themed,
      background: picture && input.background ? input.background : null,
      avatar: input.avatar ? input.avatar : null
    }
  }
}

// `stage`'s reply: { ok: true, dir, hash } with `dir` a stage folder in
// `$XDG_RUNTIME_DIR/foamy-lock/login-screen/`, or { ok: false, code }.
function stageReport(exitCode, text, runtimeDir) {
  var data = replyOf(text)
  if (exitCode !== 0 || !data || data.ok !== true) return { ok: false, code: failureCode(exitCode, data) }
  var parent = String(runtimeDir || "") + "/foamy-lock/login-screen/"
  var dir = typeof data.dir === "string" ? data.dir : ""
  if (parent[0] !== "/" || dir.indexOf(parent) !== 0 || !/^stage-[A-Za-z0-9]{1,32}$/.test(dir.slice(parent.length))
      || !HASH.test(String(data.hash))) return { ok: false, code: "unexpected" }
  return { ok: true, dir: dir, hash: data.hash }
}

// An `artwork` job's reply for the login screen, in the cache under
// `cache` (Studio's own login folder): a background
// (`<cache>/omarchy/foamy.lock/background/<sha256>.png`) or the avatar
// (exactly `<cache>/omarchy/foamy.lock/avatar.png`). { ok, path, code }.
function pictureReport(kind, exitCode, text, cache) {
  var problem = exitProblem(exitCode)
  if (problem) return { ok: false, path: "", code: problem }
  var data = exitCode === 0 ? replyOf(text) : null
  var folder = String(cache) + "/omarchy/foamy.lock/"
  var path = data && data.ok === true && typeof data.path === "string" ? data.path : ""
  var placed = kind === "avatar" ? path === folder + "avatar.png"
    : path.indexOf(folder + "background/") === 0 && /^[0-9a-f]{64}\.png$/.test(path.slice(folder.length + 11))
  if (placed) return { ok: true, path: path, code: "" }
  var code = data && data.ok === false && typeof data.error === "string" && KIND_CODE.test(data.error) ? data.error : kind + "-helper-failed"
  return { ok: false, path: "", code: code }
}

// An avatar path from the lock's `status`: "" or an absolute path of at
// most MAX_AVATAR_PATH characters without NUL or newline.
function avatarPathOk(path) {
  return typeof path === "string" && (path === "" || (path[0] === "/" && path.length <= MAX_AVATAR_PATH && !/[\0\n]/.test(path)))
}

// The lock's own `status` (`omarchy-shell foamy.lock status`): the avatar
// it shows now, `avatarRenderPath` ("" when it shows the initial, as after
// the photo was removed or failed to decode; the cached avatar.png may
// still be on disk then), and the profile photo it renders it from,
// `avatarPath` (`source`, for example ~/.face; Studio watches it). { ok:
// true, path, source } or { ok: false, path: "", source: "", code:
// "lock-status" } when the lock didn't answer or said no usable path: the
// copy then stops, it never guesses an avatar.
function lockAvatarReport(exitCode, text) {
  var data = exitCode === 0 ? replyOf(text) : null
  if (!data || !avatarPathOk(data.avatarRenderPath) || !avatarPathOk(data.avatarPath))
    return { ok: false, path: "", source: "", code: "lock-status" }
  return { ok: true, path: data.avatarRenderPath, source: data.avatarPath, code: "" }
}

// The publisher's answer: { result: "ok" | "cancelled" | "denied" |
// "failed", code }. Its own exits are 0 and 1 with one JSON line; 126 and
// 127 are pkexec's (the prompt was dismissed; not authorized, or no polkit
// agent). Anything else is a failure with a code: never success.
function publishReport(exitCode, text) {
  if (exitCode === 126) return { result: "cancelled", code: "" }
  if (exitCode === 127) return { result: "denied", code: "" }
  var data = replyOf(text)
  if (exitCode === 0 && data && data.ok === true) return { result: "ok", code: "" }
  var problem = exitProblem(exitCode)
  if (problem) return { result: "failed", code: problem }
  if (exitCode === 1 && data && data.ok === false && typeof data.code === "string" && CODE.test(data.code))
    return { result: "failed", code: data.code }
  return { result: "failed", code: exitCode === 0 || exitCode === 1 ? "unexpected" : "exit-" + exitCode }
}

// The section's state: "hidden" (SDDM isn't in use), "checking" (before
// the first answer), "error" (the check failed), "not-installed",
// "current", "outdated", "installed" (in use, not compared: the compare
// failed or runs), "overridden" or "broken". `compareHash` is the hash a
// fresh `stage` of the applied look gave ("" without one).
function sectionState(status, statusError, compareHash) {
  if (statusError) return "error"
  if (!status) return "checking"
  if (status.state === "unavailable") return "hidden"
  if (status.state !== "installed") return status.state
  if (!compareHash) return "installed"
  return compareHash === status.installed.hash ? "current" : "outdated"
}

// What this look shows that the login screen leaves out (LEFT_OUT's
// keys). `look` is an effective look; `wallpaperIsVideo` whether the
// Omarchy wallpaper is a video. The fingerprint is always listed: the
// password field is in every look, and the greeter has no fingerprint.
function leftOut(look, wallpaperIsVideo) {
  var out = []
  var elements = look && look.elements ? look.elements : {}
  function shown(name) {
    return !!elements[name] && !elements[name].hidden
  }
  if (shown("media")) out.push("media")
  if (shown("weather")) out.push("weather")
  if (shown("status")) out.push(elements.status.style === "system" ? "system" : "status")
  var background = look && look.background ? look.background : {}
  if ((background.source === "picture" && Layout.isVideoPath(background.path)) || (background.source === "omarchy" && wallpaperIsVideo))
    out.push("video")
  out.push("fingerprint")
  return out
}

// Foamy's theme folder or drop-in is there (`status`'s `managed`).
function hasManaged(status) {
  return !!status && !!status.managed && (status.managed.theme || status.managed.dropin)
}

// Remove is offered: Foamy's theme is in use or installed, or its files
// are there although SDDM doesn't use them (another file's `Current` or
// `ThemeDir`). Not while hidden, checking or after a failed check.
function restoreOffered(sectionState, status) {
  if (["current", "outdated", "installed", "overridden", "broken"].indexOf(sectionState) !== -1) return true
  return sectionState === "not-installed" && hasManaged(status)
}

// After the publisher said ok, `status` must agree: a copy is ours with
// the staged hash, a restore leaves no Foamy theme in use and none of its
// files. "done", or "unconfirmed" (the publisher's word alone isn't
// trusted).
function confirmed(action, status, hash) {
  if (!status || status.ok !== true) return "unconfirmed"
  if (action === "copy")
    return status.state === "installed" && status.installed.hash === hash ? "done" : "unconfirmed"
  return (status.state === "not-installed" || status.state === "unavailable") && !hasManaged(status) ? "done" : "unconfirmed"
}

if (typeof module !== "undefined") module.exports = {
  STATES: STATES, COLOR_KEYS: COLOR_KEYS, THEMED_KEYS: THEMED_KEYS, LEFT_OUT: LEFT_OUT, MAX_WIDTH: MAX_WIDTH, MAX_HEIGHT: MAX_HEIGHT,
  replyOf: replyOf, exitProblem: exitProblem, statusReport: statusReport, showsPicture: showsPicture, pictureSize: pictureSize,
  colorText: colorText, stageRequest: stageRequest, stageReport: stageReport, pictureReport: pictureReport,
  lockAvatarReport: lockAvatarReport, hasManaged: hasManaged, restoreOffered: restoreOffered,
  publishReport: publishReport, sectionState: sectionState, leftOut: leftOut, confirmed: confirmed
}
