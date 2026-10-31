// These helpers are local because Omarchy 4.0.6 has no video-path helper.
function isVideoPath(path) {
  return /\.(mp4|m4v|mov|webm|mkv|avi)$/i.test(String(path || ""))
}

function fileUrl(path, version) {
  if (!path) return ""
  return "file://" + String(path).split("/").map(encodeURIComponent).join("/") + "?v=" + Number(version || 0)
}

function defaults() {
  return { timeFormat: "24h", showUserInfo: true, showMedia: true, showBrowserMedia: false,
    blankAfterSec: 30, showArtwork: true, artworkHosts: [], artworkFileRoots: [] }
}

// Omarchy loads a first-party plugin unless it is listed in disabledPlugins,
// so a foamy.lock entry without that line runs two lock services at once.
function stockLockEnabled(config) {
  return !(config && Array.isArray(config.disabledPlugins)
    && config.disabledPlugins.indexOf("omarchy.lock") !== -1)
}

function parseConfig(text) {
  try {
    var config = JSON.parse(text)
    if (!config || config.version !== 1 || !Array.isArray(config.plugins))
      throw new Error("Expected version: 1 and a plugins array in shell.json")
    var entries = config.plugins.filter(function(entry) {
      return entry && entry.id === "foamy.lock"
    })
    if (entries.length !== 1) throw new Error("Keep exactly one foamy.lock entry in plugins")
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
    return { valid: true, settings: settings, error: "", stockLockEnabled: stockLockEnabled(config) }
  } catch (error) {
    return { valid: false, settings: null, error: String(error.message || error), stockLockEnabled: null }
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

// Python's posixpath.normpath for an absolute path, which artwork.py applies to
// each root via os.path.abspath: "." and empty parts go, ".." pops, and exactly
// two leading slashes are kept (POSIX leaves "//" implementation-defined).
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

// artwork.py validate_options: one bad root or host refuses every request.
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

// A cheap, reject-only copy of artwork.py's string checks, so the default
// settings (no remote hosts) do not start a helper for every track only to
// have it refuse. It rejects exactly what the helper rejects from the strings
// alone (same root normalisation, same prefix rule) and returns "" whenever
// the helper has to decide: unparsable URLs, and everything that depends on
// the filesystem (symlinked roots or parents, ownership, size). artwork.py
// still enforces every rule itself.
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

if (typeof module !== "undefined") module.exports = {
  defaults: defaults, parseConfig: parseConfig, isVideoPath: isVideoPath, fileUrl: fileUrl,
  selectPlayer: selectPlayer, runMediaAction: runMediaAction, artworkKey: artworkKey,
  mediaPlaying: mediaPlaying, isBrowserPlayer: isBrowserPlayer, artworkPrecheck: artworkPrecheck,
  stockLockEnabled: stockLockEnabled, normalizeRoot: normalizeRoot
}
