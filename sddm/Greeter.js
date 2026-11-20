// The login screen's data: theme.conf's `snapshot` (stage's snapshot.json,
// native/src/studio/login_screen/stage.rs) read into what Main.qml gives
// LockLayout. Pure functions over plain data; the node tests load this file.
//
// The publisher checked the snapshot with jq, but the greeter reads it again
// with no trust in it: every field is optional here, a wrong one takes its
// default, and a snapshot that doesn't parse at all gives the defaults. The
// look itself is Layout.parseLook's job, in Main.qml.

var VERSION = 1

// The elements the greeter has no data for (no player, status services or
// Foamy Weather): never shown, whatever the look says.
var WITHHELD = ["media", "status", "weather"]

// The look shown when the snapshot's look is missing or Layout.js rejects
// it: the default preset, without the withheld elements.
function fallbackEntry() {
  return { preset: "foamy", layout: withheldLayout({}) }
}

function isPlainObject(value) {
  return value !== null && typeof value === "object" && !Array.isArray(value)
}

function withheldLayout(layout) {
  var result = {}
  for (var name in layout) result[name] = layout[name]
  for (var i = 0; i < WITHHELD.length; i++) result[WITHHELD[i]] = { hidden: true }
  return result
}

// A language or locale tag as stage writes it (1 to 35 ASCII letters,
// digits, "-" and "_"), else `fallback`.
function tag(value, fallback) {
  return typeof value === "string" && /^[A-Za-z0-9_-]{1,35}$/.test(value) ? value : fallback
}

// { snapshot, error }: `snapshot` always has every field the greeter reads;
// `error` is "" or why the text was not a version 1 snapshot (its fields
// are then all defaults).
function parseSnapshot(text) {
  var raw = null
  var error = ""
  if (typeof text !== "string" || text === "") {
    error = "theme.conf has no snapshot"
  } else {
    try {
      raw = JSON.parse(text)
    } catch (e) {
      error = "the snapshot is not JSON: " + e.message
    }
  }
  if (!error && !isPlainObject(raw)) error = "the snapshot is not an object"
  if (!error && raw.version !== VERSION) error = "the snapshot's version is not " + VERSION
  var source = error ? {} : raw
  var files = isPlainObject(source.files) ? source.files : {}
  return {
    error: error,
    snapshot: {
      user: typeof source.user === "string" ? source.user : "",
      timeFormat: source.timeFormat === "12h" ? "12h" : "24h",
      showUserInfo: source.showUserInfo !== false,
      language: tag(source.language, "en"),
      formatLocale: tag(source.formatLocale, "en-US"),
      rightToLeft: source.rightToLeft === true,
      look: isPlainObject(source.look) ? source.look : null,
      colors: isPlainObject(source.colors) ? source.colors : {},
      lockThemed: Array.isArray(source.lockThemed) ? source.lockThemed.filter(function(key) {
        return typeof key === "string"
      }) : [],
      strings: isPlainObject(source.strings) ? source.strings : {},
      background: files.background === "background.png",
      avatar: files.avatar === "avatar.png"
    }
  }
}

// The entry for Layout.parseLook: the snapshot's look without the withheld
// elements, a picture source pointing at `backgroundPath` (the copied
// picture beside Main.qml; "" without one), or the fallback without a look.
function lookEntry(snapshot, backgroundPath) {
  if (!snapshot.look) return fallbackEntry()
  var entry = {}
  for (var key in snapshot.look) entry[key] = snapshot.look[key]
  entry.layout = withheldLayout(isPlainObject(entry.layout) ? entry.layout : {})
  if (isPlainObject(entry.background) && entry.background.source === "picture") {
    var background = {}
    for (var b in entry.background) background[b] = entry.background[b]
    background.path = backgroundPath
    entry.background = background
  }
  return entry
}

// Who logs in: SDDM's last user, else (a fresh system, where SDDM
// remembers nobody yet) the user who copied the look, so the field can
// always log someone in.
function loginUser(snapshot, lastUser) {
  return lastUser !== "" ? lastUser : snapshot.user
}

// The copied avatar shows only for the user who copied the look, so one
// user's picture never shows over another user's login.
function showsAvatar(snapshot, lastUser) {
  return snapshot.avatar && snapshot.user !== "" && snapshot.user === lastUser
}

// The session Omarchy's own theme picks: the first whose name has "uwsm",
// else SDDM's last one. `names` are the session model's display names.
function sessionIndex(names, lastIndex) {
  for (var i = 0; i < names.length; i++) {
    if (String(names[i] || "").indexOf("uwsm") !== -1) return i
  }
  return lastIndex
}

if (typeof module !== "undefined") {
  module.exports = {
    VERSION: VERSION,
    WITHHELD: WITHHELD,
    fallbackEntry: fallbackEntry,
    parseSnapshot: parseSnapshot,
    lookEntry: lookEntry,
    loginUser: loginUser,
    showsAvatar: showsAvatar,
    sessionIndex: sessionIndex
  }
}
