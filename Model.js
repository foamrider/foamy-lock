// Commons.Util.fileUrl with a cache-busting version, so a rewritten
// wallpaper at the same path reloads.
function fileUrl(path, version) {
  if (!path) return ""
  return "file://" + String(path).split("/").map(encodeURIComponent).join("/") + "?v=" + Number(version || 0)
}

function defaults() {
  return { timeFormat: "24h", showUserInfo: true, showMedia: true, showBrowserMedia: false,
    blankAfterSec: 30, showArtwork: true, artworkHosts: [], artworkFileRoots: [] }
}

// Cover art, as Lock Studio offers it (setCoverArt): three fixed pairs of
// showArtwork and artworkHosts. "player": the player's local file:// art
// (under artworkFileRoots) only; "spotify": also Spotify's cover host,
// exactly the host its MPRIS mpris:artUrl names (https://i.scdn.co/image/…).
// No other host ever comes from here.
var COVER_ART_MODES = ["off", "player", "spotify"]
var SPOTIFY_ART_HOST = "i.scdn.co"

function coverArtSettings(mode) {
  switch (mode) {
  case "off": return { showArtwork: false, artworkHosts: [] }
  case "player": return { showArtwork: true, artworkHosts: [] }
  case "spotify": return { showArtwork: true, artworkHosts: [SPOTIFY_ART_HOST] }
  }
  return null
}

// The mode of a parsed settings object: one of COVER_ART_MODES, or
// "custom" when artworkHosts names other hosts.
function coverArtMode(settings) {
  if (!settings || settings.showArtwork === false) return "off"
  var hosts = Array.isArray(settings.artworkHosts) ? settings.artworkHosts : []
  if (hosts.length === 0) return "player"
  if (hosts.length === 1 && hosts[0] === SPOTIFY_ART_HOST) return "spotify"
  return "custom"
}

// Omarchy loads a first-party plugin unless it is listed in disabledPlugins,
// so a foamy.lock entry without that line runs two lock services at once.
function stockLockEnabled(config) {
  return !(config && Array.isArray(config.disabledPlugins)
    && config.disabledPlugins.indexOf("omarchy.lock") !== -1)
}

// Returns { valid, settings, error, stockLockEnabled, entry }. `entry` is the
// foamy.lock entry whenever the file has exactly one, even when a setting in
// it is invalid: the look keys in it (Layout.parseLook) are validated on
// their own, so a mistake there never resets these settings, and the other
// way round.
function parseConfig(text) {
  var entry = null
  try {
    var config = JSON.parse(text)
    if (!config || config.version !== 1 || !Array.isArray(config.plugins))
      throw new Error("Expected version: 1 and a plugins array in shell.json")
    var entries = config.plugins.filter(function(entry) {
      return entry && entry.id === "foamy.lock"
    })
    if (entries.length !== 1) throw new Error("Keep exactly one foamy.lock entry in plugins")
    entry = entries[0]
    var settings = defaults()
    for (var key in settings) {
      if (entries[0][key] !== undefined) settings[key] = entries[0][key]
    }
    if (["24h", "12h"].indexOf(settings.timeFormat) === -1)
      throw new Error("timeFormat must be 24h or 12h")
    if (typeof settings.showUserInfo !== "boolean")
      throw new Error("showUserInfo must be true or false")
    if (typeof settings.showMedia !== "boolean")
      throw new Error("showMedia must be true or false")
    if (typeof settings.showBrowserMedia !== "boolean")
      throw new Error("showBrowserMedia must be true or false")
    if (typeof settings.showArtwork !== "boolean")
      throw new Error("showArtwork must be true or false")
    if (!Array.isArray(settings.artworkHosts) || settings.artworkHosts.length > 32
        || settings.artworkHosts.some(function(host) {
          return typeof host !== "string" || host.length > 253
            || !/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(host)
        })) throw new Error("artworkHosts must contain at most 32 exact lowercase DNS hostnames")
    if (!Array.isArray(settings.artworkFileRoots) || settings.artworkFileRoots.length > 14
        || settings.artworkFileRoots.some(function(path) {
          return typeof path !== "string" || path[0] !== "/" || path === "/"
            || path.length > 4096 || path.indexOf("\u0000") !== -1 || path.split("/").indexOf("..") !== -1
        })) throw new Error("artworkFileRoots must contain at most 14 absolute directories, without parent traversal")
    var timeout = settings.blankAfterSec
    // QML Timer uses signed 32-bit milliseconds; null explicitly disables it.
    if (timeout !== null && (typeof timeout !== "number" || !isFinite(timeout)
        || Math.floor(timeout) !== timeout || timeout < 1 || timeout > 2147483))
      throw new Error("blankAfterSec must be null or an integer from 1 to 2147483")
    return { valid: true, settings: settings, error: "", stockLockEnabled: stockLockEnabled(config), entry: entry }
  } catch (error) {
    return { valid: false, settings: null, error: String(error.message || error), stockLockEnabled: null, entry: entry }
  }
}

function artworkKey(player) {
  if (!player) return ""
  var url = String(player.trackArtUrl || "")
  if (!url || url.length > 8192) return ""
  // Bound metadata retained by the service and distinguish tracks that reuse
  // one artwork URL. No URL or track text is used as a filename or command.
  return JSON.stringify([String(player.uniqueId || "").slice(0, 512),
    String(player.trackTitle || "").slice(0, 512), String(player.trackArtist || "").slice(0, 512), url])
}

// Shared with foamy-idle-suspend (see its Policy.js): media "is playing" when
// any MPRIS player reports PlaybackStatus Playing. Paused or stopped players,
// and players without metadata, do not count.
function mediaPlaying(players) {
  var list = players || []
  for (var i = 0; i < list.length; i++) {
    if (list[i] && list[i].isPlaying === true) return true
  }
  return false
}

// Browsers publish the page or tab title as the track title, so their media
// stays off the lock screen unless showBrowserMedia opts in.
var BROWSER_PATTERN = /(^|[^a-z])(firefox|librewolf|waterfox|floorp|zen|chromium|chrome|brave|vivaldi|opera|msedge|microsoft-edge|edge|epiphany|qutebrowser|falkon|midori|thorium|helium|plasma-browser-integration)([^a-z]|$)/

function isBrowserPlayer(player) {
  if (!player) return false
  var names = [player.desktopEntry, player.dbusName, player.identity].map(function(value) {
    return String(value || "").toLowerCase()
  }).join(" ")
  return BROWSER_PATTERN.test(names) || /web browser/.test(names)
}

function selectPlayer(players, includeBrowsers) {
  var fallback = null
  for (var i = 0; i < players.length; i++) {
    var player = players[i]
    if (!player || (!player.trackTitle && !player.trackArtist)) continue
    if (includeBrowsers !== true && isBrowserPlayer(player)) continue
    // Prefer a playing track, retaining a paused track when nothing is playing.
    if (player.isPlaying) return player
    if (!fallback) fallback = player
  }
  return fallback
}

// Python's posixpath.normpath for an absolute path, which the helper applies
// to each root (as os.path.abspath did in the former artwork.py): "." and
// empty parts go, ".." pops, and exactly two leading slashes are kept (POSIX
// leaves "//" implementation-defined).
function normalizeRoot(path) {
  var text = String(path)
  var initial = text.charAt(0) === "/" ? 1 : 0
  if (initial && text.slice(0, 2) === "//" && text.slice(0, 3) !== "///") initial = 2
  var parts = []
  var pieces = text.split("/")
  for (var i = 0; i < pieces.length; i++) {
    var piece = pieces[i]
    if (piece === "" || piece === ".") continue
    if (piece !== ".." || (!initial && parts.length === 0) || (parts.length && parts[parts.length - 1] === ".."))
      parts.push(piece)
    else if (parts.length) parts.pop()
  }
  var joined = "/".repeat(initial) + parts.join("/")
  return joined || "."
}

// The helper's option check: one bad root or host refuses every request.
var HOST_PATTERN = /^(?=.{1,253}$)(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)+[a-z](?:[a-z0-9-]{0,61}[a-z0-9])?$/
function optionsError(hosts, roots) {
  if (!Array.isArray(hosts) || hosts.length > 32 || hosts.some(function(host) {
    return typeof host !== "string" || !HOST_PATTERN.test(host)
  })) return "invalid-hosts"
  if (!Array.isArray(roots) || roots.length > 16 || roots.some(function(root) {
    return typeof root !== "string" || root.charAt(0) !== "/" || root.length > 4096
      || root.indexOf("\u0000") !== -1 || root === "/" || root.split("/").indexOf("..") !== -1
  })) return "invalid-roots"
  return ""
}

// A cheap, reject-only copy of the helper's string checks, so the default
// settings (no remote hosts) do not start a helper for every track only to
// have it refuse. It rejects exactly what the helper rejects from the strings
// alone (same root normalisation, same prefix rule) and returns "" whenever
// the helper has to decide: unparsable URLs, and everything that depends on
// the filesystem (symlinked roots or parents, ownership, size). The helper
// (native/) still enforces every rule itself.
function artworkPrecheck(url, hosts, roots) {
  var text = String(url || "")
  if (!text) return "invalid-url"
  var scheme = /^([a-z][a-z0-9+.-]*):/i.exec(text)
  if (!scheme) return "unsupported-scheme"
  var name = scheme[1].toLowerCase()
  var options = optionsError(hosts || [], roots || [])
  if (options) return options
  if (name === "https") {
    var match = /^https:\/\/([^\/?#@:\[\]]+)(?::443)?(?:[\/?#]|$)/i.exec(text)
    if (!match) return ""
    var host = match[1].toLowerCase()
    return (hosts || []).indexOf(host) === -1 ? "host-not-allowed" : ""
  }
  if (name === "file") {
    var path = /^file:\/\/(\/[^?#]*)$/.exec(text)
    if (!path) return ""
    var decoded
    try { decoded = decodeURIComponent(path[1]) } catch (error) { return "" }
    // Paths are not normalised by the helper: these refuse outright.
    if (decoded.indexOf("\u0000") !== -1 || decoded.split("/").indexOf("..") !== -1) return "invalid-file-path"
    var list = roots || []
    for (var i = 0; i < list.length; i++) {
      var prefix = normalizeRoot(list[i]).replace(/\/+$/, "") + "/"
      if (decoded.indexOf(prefix) === 0) return ""
    }
    return "file-outside-roots"
  }
  return "unsupported-scheme"
}

function runMediaAction(player, action) {
  if (!player) return false
  if (action === "previous" && player.canGoPrevious) player.previous()
  else if (action === "next" && player.canGoNext) player.next()
  else if (action === "playPause") {
    if (player.canTogglePlaying) player.togglePlaying()
    else if (player.isPlaying && player.canPause) player.pause()
    else if (!player.isPlaying && player.canPlay) player.play()
    else return false
  } else return false
  return true
}

// The ISO 8601 week of a local date: { week, year } (week 1 holds the
// year's first Thursday; 29 December can be week 1 of the next year and
// 1 January week 52 or 53 of the last). toLocaleString has no week number.
function isoWeek(date) {
  var day = new Date(Date.UTC(date.getFullYear(), date.getMonth(), date.getDate()))
  // Move to the Thursday of this week (Monday is day 1, Sunday day 7).
  var weekday = day.getUTCDay() || 7
  day.setUTCDate(day.getUTCDate() + 4 - weekday)
  var year = day.getUTCFullYear()
  var first = new Date(Date.UTC(year, 0, 1))
  return { week: Math.ceil(((day - first) / 86400000 + 1) / 7), year: year }
}

// Foamy Weather's `current()` reply (see its README), read as untrusted
// text: the lock shows only a reply that passes every check here, and only
// as plain text.
var WEATHER_MAX_REPLY = 4096
// Reports older than this are hidden (the service may answer with an old
// forecast while MET Norway or the network is down).
var WEATHER_MAX_AGE_MS = 3 * 3600 * 1000
// A clock a little ahead of ours is not a report from the future.
var WEATHER_SKEW_MS = 10 * 60 * 1000
// One line of printable text: no control, line or bidirectional-override
// characters (a place name can't reorder what the lock screen says).
var UNSAFE_TEXT = /[\u0000-\u001f\u007f-\u009f\u200e\u200f\u2028\u2029\u202a-\u202e\u2066-\u2069\ufeff]/

function weatherText(value, limit, required) {
  if (typeof value !== "string" || value.length > limit || UNSAFE_TEXT.test(value)) return null
  var text = value.trim()
  return required && text === "" ? null : text
}

function weatherDegrees(value, nullable) {
  if (value === null && nullable) return null
  if (typeof value !== "number" || !isFinite(value) || Math.floor(value) !== value || value < -150 || value > 150)
    return undefined
  return value
}

// The condition group a MET Norway symbol code draws as (the lock's own
// icons): clear, partly, cloudy, fog, rain, sleet, snow or thunder. The
// day, night and polar-twilight variants draw the same.
function weatherGroup(code) {
  var base = String(code || "").replace(/_(day|night|polartwilight)$/, "")
  if (base === "clearsky") return "clear"
  if (base === "fair" || base === "partlycloudy") return "partly"
  if (base === "fog") return "fog"
  if (base.indexOf("thunder") !== -1) return "thunder"
  if (base.indexOf("sleet") !== -1) return "sleet"
  if (base.indexOf("snow") !== -1) return "snow"
  if (base.indexOf("rain") !== -1 || base.indexOf("drizzle") !== -1) return "rain"
  return "cloudy"
}

// One reply, at `nowMs`: { state, weather }.
// - state "ok": `weather` is { temperature, unit, code, group, condition,
//   high, low, location, updatedAtMs }, every field checked.
// - "pending": the service is starting or loading; ask again soon.
// - "unavailable": not ok (no location, offline, unsupported, an error).
// - "stale": a valid report more than three hours old (or of unknown age).
// - "invalid": anything else (not JSON, wrong types, out of range, too long).
function parseWeather(text, nowMs) {
  var reply = String(text === undefined || text === null ? "" : text)
  if (reply.length === 0 || reply.length > WEATHER_MAX_REPLY) return { state: "invalid", weather: null }
  var value
  try { value = JSON.parse(reply) } catch (error) { return { state: "invalid", weather: null } }
  if (value === null || typeof value !== "object" || Array.isArray(value)) return { state: "invalid", weather: null }
  if (value.ok === false) return { state: value.reason === "pending" ? "pending" : "unavailable", weather: null }
  if (value.ok !== true) return { state: "invalid", weather: null }
  var temperature = weatherDegrees(value.temperature, false)
  var high = weatherDegrees(value.high === undefined ? null : value.high, true)
  var low = weatherDegrees(value.low === undefined ? null : value.low, true)
  var code = typeof value.code === "string" && /^[a-z0-9_]{1,48}$/.test(value.code) ? value.code : ""
  var condition = weatherText(value.condition, 64, false)
  var location = weatherText(value.location === undefined ? "" : value.location, 80, false)
  var updated = typeof value.updatedAt === "string" && value.updatedAt.length <= 40
    && /^\d{4}-\d\d-\d\dT\d\d:\d\d(:\d\d(\.\d+)?)?(Z|[+-]\d\d:\d\d)$/.test(value.updatedAt) ? Date.parse(value.updatedAt) : NaN
  if (temperature === undefined || high === undefined || low === undefined || !code || condition === null
      || location === null || (value.unit !== "C" && value.unit !== "F")
      || (value.updatedAt !== "" && !isFinite(updated)))
    return { state: "invalid", weather: null }
  var weather = { temperature: temperature, unit: value.unit, code: code, group: weatherGroup(code), condition: condition,
    high: high, low: low, location: location, updatedAtMs: isFinite(updated) ? updated : 0 }
  return { state: weatherFresh(weather, nowMs) ? "ok" : "stale", weather: weather }
}

// A report is shown while it is under three hours old (and not from the
// future beyond a little clock skew); one of unknown age never is.
function weatherFresh(weather, nowMs) {
  if (!weather || !(weather.updatedAtMs > 0)) return false
  var age = Number(nowMs) - weather.updatedAtMs
  return age <= WEATHER_MAX_AGE_MS && age >= -WEATHER_SKEW_MS
}

// The keyboard layout for the status item, from `hyprctl -j devices` (read
// only), as Omarchy's KeyboardLayout widget reads it (its
// KeyboardLayoutModel.js, MIT): the keyboard the last activelayout event
// named, else the one furthest through its layout list, leaving out the
// devices Hyprland calls keyboards that nobody types on. "" when unknown.
var UNTYPED_KEYBOARDS = /^(hl-virtual-keyboard|power-button|sleep-button|lid-switch|video-bus)|(-wmi-hotkeys|-wireless-radio-control)(-\d+)?$/

function isTypedKeyboard(name) {
  return !UNTYPED_KEYBOARDS.test(String(name || ""))
}

function keyboardLayout(text, namedByEvent) {
  var listed
  try { listed = JSON.parse(String(text || "{}")).keyboards } catch (error) { return "" }
  if (!Array.isArray(listed)) return ""
  var typed = listed.filter(function(keyboard) {
    return keyboard && typeof keyboard === "object" && isTypedKeyboard(keyboard.name)
  })
  var index = function(keyboard) { return (keyboard && Number(keyboard.active_layout_index)) || 0 }
  var chosen = null
  for (var i = 0; i < typed.length; i++) if (namedByEvent && typed[i].name === namedByEvent) chosen = typed[i]
  if (!chosen) {
    for (var j = 0; j < typed.length; j++) if (!chosen || index(typed[j]) > index(chosen)) chosen = typed[j]
  }
  var keymap = chosen ? weatherText(chosen.active_keymap, 80, true) : null
  return keymap || ""
}

// The keyboard named by an activelayout event ("<keyboard>,<layout>"), or
// "" for a device nobody types on.
function eventKeyboardName(data) {
  var name = String(data || "").split(",")[0]
  return isTypedKeyboard(name) ? name : ""
}

// A short label for a layout description ("English (US)" → "ENG"): its
// first word, at most three letters, as Omarchy's widget falls back to.
function keyboardShort(description) {
  return String(description || "").split(/\s+/)[0].substring(0, 3).toLocaleUpperCase()
}

// --- video backgrounds -----------------------------------------------------

// The size a video background is converted for and looked up at: the
// largest screen's native pixels. `natives` are Hyprland's monitors
// ({ width, height, transform }: the mode in device pixels before the
// transform; an odd transform turns the screen), `screens` the logical
// sizes ({ width, height }) used without them. [width, height] within the
// helper's 16..7680 x 16..4320; 1920 x 1080 without any screen.
function videoScreenSize(natives, screens) {
  var best = null
  function consider(width, height) {
    width = Math.round(Number(width) || 0)
    height = Math.round(Number(height) || 0)
    if (width <= 0 || height <= 0) return
    if (!best || width * height > best[0] * best[1]) best = [width, height]
  }
  for (var i = 0; i < (natives || []).length; i++) {
    var native = natives[i]
    if (!native) continue
    var turned = Math.abs(Math.round(Number(native.transform) || 0)) % 2 === 1
    consider(turned ? native.height : native.width, turned ? native.width : native.height)
  }
  if (!best) {
    for (var j = 0; j < (screens || []).length; j++) {
      if (screens[j]) consider(screens[j].width, screens[j].height)
    }
  }
  if (!best) return [1920, 1080]
  return [Math.max(16, Math.min(7680, best[0])), Math.max(16, Math.min(4320, best[1]))]
}

// The helper's video-probe reply as the lock and Lock Studio take it: a
// poster and a clip only inside `directory` (the cache's video/, with its
// trailing slash) and named as the helper names them, the clip for exactly
// the output size the reply gives. { ok, error, poster, clip, reply }.
function videoProbeResult(text, directory) {
  var reply = null
  try { reply = JSON.parse(String(text || "").trim().split("\n").pop()) } catch (error) { reply = null }
  if (!reply || typeof reply !== "object" || reply.ok !== true) {
    var code = reply && typeof reply.error === "string" && /^[a-z-]{1,48}$/.test(reply.error)
      ? reply.error : "video-helper-failed"
    return { ok: false, error: code, poster: "", clip: "", reply: null }
  }
  function inside(path, pattern) {
    return typeof path === "string" && path.indexOf(directory) === 0 && pattern.test(path.slice(directory.length))
  }
  var output = reply.output && typeof reply.output === "object" ? reply.output : null
  var poster = inside(reply.poster, /^[0-9a-f]{64}\.png$/) ? reply.poster : ""
  var suffix = output ? "-" + output.width + "x" + output.height + ".mp4" : ""
  var clip = output && inside(reply.clip, /^[0-9a-f]{64}-[1-9][0-9]{1,3}x[1-9][0-9]{1,3}\.mp4$/)
    && reply.clip.slice(-suffix.length) === suffix ? reply.clip : ""
  return { ok: true, error: "", poster: poster, clip: clip, reply: reply }
}

if (typeof module !== "undefined") module.exports = {
  videoScreenSize: videoScreenSize, videoProbeResult: videoProbeResult,
  defaults: defaults, parseConfig: parseConfig, fileUrl: fileUrl,
  selectPlayer: selectPlayer, runMediaAction: runMediaAction, artworkKey: artworkKey,
  mediaPlaying: mediaPlaying, isBrowserPlayer: isBrowserPlayer, artworkPrecheck: artworkPrecheck,
  stockLockEnabled: stockLockEnabled, normalizeRoot: normalizeRoot, isoWeek: isoWeek,
  parseWeather: parseWeather, weatherFresh: weatherFresh, weatherGroup: weatherGroup,
  WEATHER_MAX_AGE_MS: WEATHER_MAX_AGE_MS, keyboardLayout: keyboardLayout, eventKeyboardName: eventKeyboardName,
  keyboardShort: keyboardShort, isTypedKeyboard: isTypedKeyboard,
  COVER_ART_MODES: COVER_ART_MODES, SPOTIFY_ART_HOST: SPOTIFY_ART_HOST, coverArtSettings: coverArtSettings, coverArtMode: coverArtMode
}
