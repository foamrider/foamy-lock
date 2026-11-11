// Style sweep: every style of every element, in each column of its row, on
// one view through two sizes, 12- and 24-hour time, typing and idle, primary
// and secondary; then every style switched on the same view and back to the
// default, which must restore the geometry exactly; then password.reveal
// "always" and "typing" on every field style, typed into on primary and
// secondary screens. The status runs with every item and the weather with its widest
// sample (the full details, a long condition and place). Written into a
// temporary app by the harness, which replaces __CAPTURE__.
import QtQuick
import Quickshell
import "fixtures" as Fixture
import "Layout.js" as Layout
ShellRoot {
  id: shellRoot
  readonly property bool capture: __CAPTURE__
  readonly property var sizes: [[1920, 1080], [800, 1000]]
  readonly property var columns: ["start", "center", "end"]
  readonly property var tracked: ["dateLabel", "clockLabel", "identityBlock", "avatar", "nameLabel", "inputField",
    "editorArea", "passwordInput", "unlockHint", "submitArrow", "fingerprintNotice", "mediaRow", "albumArt",
    "mediaControls", "statusFooter", "networkStatus", "batteryStatus", "calendarBlock", "weatherBlock"]
  // Parts drawn by a style, each inside its element (when visible).
  readonly property var parts: ({
    dateLabel: ["dateDetail", "dateStack"],
    clockLabel: ["clockStacked", "clockOutline", "clockDots", "clockFlip", "clockAnalog", "clockPoster", "clockRing"],
    identityBlock: ["avatar", "nameLabel"],
    inputField: ["editorArea", "passwordInput", "cardGreeting", "cardPill", "terminalPrompt", "submitArrow"],
    mediaRow: ["albumArt", "mediaTitle", "mediaArtist", "mediaControls", "mediaLine", "mediaMinimal"],
    statusFooter: ["networkStatus", "batteryStatus", "volumeStatus", "bluetoothStatus", "keyboardStatus", "uptimeStatus",
      "loadStatus", "memoryStatus", "systemPanel"],
    calendarBlock: ["calendarCard", "calendarTitle"],
    weatherBlock: ["weatherSurface", "weatherHead", "weatherIcon", "weatherTemperature", "weatherCondition", "weatherRange", "weatherLocation",
      "weatherLine", "weatherText"]
  })
  readonly property var elementItems: ({ date: "dateLabel", clock: "clockLabel", account: "identityBlock",
    password: "inputField", media: "mediaRow", status: "statusFooter", calendar: "calendarBlock", weather: "weatherBlock" })
  // The widest weather: every detail, a 64-character condition and an
  // 80-character place (the reply's limits).
  readonly property var widestWeather: ({ temperature: -12, unit: "C", code: "heavyrainandthunder", group: "thunder",
    condition: "Heavy rain and thunder with strong gusts along the coast tonight", high: -3, low: -18,
    location: "Llanfairpwllgwyngyllgogerychwyrndrobwllllantysiliogogogoch, Ynys Môn, Cymru", updatedAtMs: 1 })

  // One case per element, style and column: the layout overrides that put
  // the element (and its usual partner) in that column of its row, moving
  // whatever would share the zone out of the way.
  function layoutFor(element, style, column) {
    var layout = {}
    layout[element] = { style: style }
    if (element === "date" || element === "clock") {
      layout.date = layout.date || {}
      layout.clock = layout.clock || {}
      layout.date.zone = layout.clock.zone = "top-" + column
      if (column === "end") layout.status = { zone: "top-start" }
    } else if (element === "account" || element === "password") {
      layout.account = layout.account || {}
      layout.password = layout.password || {}
      layout.account.zone = layout.password.zone = "bottom-" + column
      if (column === "start") layout.media = { zone: "bottom-end" }
    } else if (element === "media") {
      // In the center, above the account and the field.
      layout.media.zone = "bottom-" + column
      if (column === "center") layout.media.order = -1
    } else if (element === "weather") {
      // Hidden by default: shown in the top row with every detail. Beside
      // the centre the date and clock make room (they'd overlap on a
      // narrow screen), and the status leaves its corner.
      layout.weather.hidden = false
      layout.weather.details = "full"
      layout.weather.location = true
      layout.weather.zone = "top-" + column
      if (column === "center") layout.weather.order = -1
      else layout.date = layout.clock = { hidden: true }
      if (column === "end") layout.status = { zone: "top-start" }
      if (column === "start") layout.status = { zone: "top-end", style: "icons" }
    } else if (element === "calendar") {
      // Hidden by default: shown alone in the middle row.
      layout.calendar.hidden = false
      layout.calendar.zone = "middle-" + column
    } else {
      layout.status.zone = "top-" + column
      // Above the date and clock in the center.
      if (column === "center") layout.status.order = -1
      // The system panel is too large to share the top row on a narrow screen
      // (elements in different zones may not overlap): the date and clock
      // move to the middle.
      if (style === "system" && column !== "center") layout.date = layout.clock = { zone: "middle-center" }
    }
    return layout
  }

  readonly property var cases: {
    var out = []
    for (var i = 0; i < Layout.ELEMENTS.length; i++) {
      var element = Layout.ELEMENTS[i]
      var styles = Layout.STYLES[element]
      for (var s = 0; s < styles.length; s++)
        for (var c = 0; c < columns.length; c++)
          out.push({ element: element, style: styles[s], column: columns[c], layout: layoutFor(element, styles[s], columns[c]) })
    }
    // Every status item at once, in every style and column (the date and
    // clock make room).
    for (var t = 0; t < Layout.STYLES.status.length; t++) {
      for (var k = 0; k < columns.length; k++) {
        var items = { status: { style: Layout.STYLES.status[t], items: Layout.STATUS_ITEMS.slice(), zone: "top-" + columns[k] },
          date: { hidden: true }, clock: { hidden: true } }
        out.push({ element: "status", style: Layout.STYLES.status[t] + " (all items)", column: columns[k], layout: items })
      }
    }
    return out
  }
  // Each state: [size index, 12h, typing, primary].
  readonly property var states: {
    var out = []
    for (var z = 0; z < sizes.length; z++)
      for (var h = 0; h < 2; h++)
        for (var t = 0; t < 2; t++)
          for (var p = 1; p >= 0; p--) out.push([z, h === 1, t === 1, p === 1])
    return out
  }
  // The cycle: each style alone on the default look, then every element's
  // n-th style together, then the default again.
  readonly property var cycle: {
    var out = []
    for (var i = 0; i < Layout.ELEMENTS.length; i++) {
      var element = Layout.ELEMENTS[i]
      for (var s = 1; s < Layout.STYLES[element].length; s++) {
        var layout = {}
        layout[element] = { style: Layout.STYLES[element][s] }
        if (element === "calendar") layout.calendar.hidden = false
        if (element === "weather") layout.weather.hidden = false
        out.push({ name: element + " " + Layout.STYLES[element][s], layout: layout })
      }
    }
    for (var n = 1; n < 8; n++) {
      var together = {}
      for (var j = 0; j < Layout.ELEMENTS.length; j++) {
        var styles = Layout.STYLES[Layout.ELEMENTS[j]]
        together[Layout.ELEMENTS[j]] = { style: styles[n % styles.length] }
      }
      out.push({ name: "all #" + n, layout: together })
    }
    out.push({ name: "default", layout: {} })
    return out
  }

  property int caseAt: 0
  property int revealAt: -1
  // The field's rectangle with reveal "always", per style and screen.
  property var revealRects: ({})

  // password.reveal on every style (round 4), on a primary and a secondary
  // screen: "always" shows the field while empty on the primary (the pill's
  // glass with the hint inside it, the dots' track; nothing on the
  // secondary); "typing" shows only the hint idle (the hint and fingerprint
  // notice still there on the primary; the editor focused), then all of it
  // typed into through the editor itself, failed and checking. Its
  // rectangle never moves.
  readonly property var revealSteps: {
    var out = []
    var styles = Layout.STYLES.password
    for (var i = 0; i < styles.length; i++) {
      for (var p = 1; p >= 0; p--) (function(style, primary) {
        var key = style + (primary ? "" : " secondary")
        var hides = Layout.REVEAL_STYLES.indexOf(style) !== -1
        if (!hides) shellRoot.fail("password.reveal must apply to " + style)
        function reset(reveal) {
          view.width = 1920; view.height = 1080
          view.rightToLeft = false
          view.primary = primary
          view.passwordText = ""
          view.failureMessage = ""
          view.authenticatingPassword = false
          view.fingerprintUnavailable = false
          view.look = Layout.parseLook({ layout: { password: { style: style, reveal: reveal } } }).look
        }
        out.push({ name: key + " always", apply: function() { reset("always") }, check: function() {
          shellRoot.revealRects[key] = JSON.stringify(rect(findNamed(view, "inputField")))
          shellRoot.revealRects[key + " parts"] = JSON.stringify(shellRoot.chrome())
          shellRoot.checkAlways(style, primary)
        } })
        // The style's own default draws as before round 4 (pill and dots:
        // only the hint; the others: the field).
        out.push({ name: key + " default", apply: function() { reset(undefined) }, check: function() {
          var own = Layout.optionDefault("reveal", style)
          if (Layout.revealOf(view.placed.password) !== own) shellRoot.fail("the default reveal of " + style + " isn't " + own)
          if (own === "always") {
            if (JSON.stringify(shellRoot.chrome()) !== shellRoot.revealRects[key + " parts"])
              shellRoot.fail(style + "'s default isn't its \"always\" drawing")
          } else shellRoot.checkReveal(key, primary, false)
        } })
        out.push({ name: key + " idle", apply: function() { reset("typing") }, check: function() {
          shellRoot.checkReveal(key, primary, hides ? false : null)
        } })
        out.push({ name: key + " fingerprint notice", apply: function() { view.fingerprintUnavailable = true }, check: function() {
          shellRoot.checkReveal(key, primary, hides ? false : null)
          if (findNamed(view, "fingerprintNotice").visible !== primary) shellRoot.fail("the fingerprint notice must stay on the primary screen")
        } })
        out.push({ name: key + " typed", apply: function() {
          view.fingerprintUnavailable = false
          var input = findNamed(view, "passwordInput")
          if (!input.activeFocus) shellRoot.fail("the editor isn't focused while the field is hidden")
          input.insert(input.cursorPosition, "secret")
        }, check: function() {
          if (view.passwordText !== "secret") shellRoot.fail("typing into the hidden field didn't reach the view: " + JSON.stringify(view.passwordText))
          shellRoot.checkReveal(key, primary, true)
          if (findNamed(view, "passwordInput").opacity !== 1) shellRoot.fail("typed dots are invisible")
        } })
        out.push({ name: key + " failed", apply: function() {
          view.passwordText = ""
          view.failureMessage = "Authentication failed"
        }, check: function() { shellRoot.checkReveal(key, primary, primary ? true : null) } })
        out.push({ name: key + " checking", apply: function() {
          view.failureMessage = ""
          view.authenticatingPassword = true
        }, check: function() { shellRoot.checkReveal(key, primary, primary ? true : null) } })
      })(styles[i], p === 1)
    }
    return out
  }

  // What of the field's chrome shows: its surface and the named parts.
  function chrome() {
    var field = findNamed(view, "inputField")
    var out = { surface: field.border.width > 0 && field.color.a > 0 }
    var names = ["fieldUnderline", "terminalPrompt", "cardGreeting", "cardPill", "boxDivider", "submitArrow", "dotsTrack", "unlockHint"]
    for (var i = 0; i < names.length; i++) {
      var part = findNamed(field, names[i])
      var shown = !!part && part.visible
      for (var at = part; shown && at && at !== field; at = at.parent) shown = at.visible
      out[names[i]] = shown
    }
    return out
  }

  // reveal "always", idle: on the primary screen the field shows (a surface,
  // the underline or the dots' track) with the hint, inside the pill's
  // glass; on a secondary screen nothing does.
  function checkAlways(style, primary) {
    var field = findNamed(view, "inputField")
    var now = chrome()
    var drawn = now.surface || now.fieldUnderline || now.dotsTrack
    if (!primary) {
      for (var name in now) if (now[name]) return fail(name + " shows on a secondary screen while idle")
      checked++
      return
    }
    if (!drawn) return fail(style + " shows no field while empty with reveal always: " + JSON.stringify(now))
    if (!now.unlockHint) return fail(style + " lost its hint")
    if (style === "pill") {
      if (!now.surface) return fail("the pill's glass must show while empty")
      var hint = findNamed(field, "unlockHint")
      if (hint.x < 0 || hint.x + hint.width > field.width + 0.5 || hint.y < 0 || hint.y + hint.height > field.height + 0.5)
        return fail("the hint leaves the pill: " + JSON.stringify(rect(hint)))
      if (now.submitArrow) return fail("the pill's arrow comes with typing")
    }
    if (style === "dots" && !now.dotsTrack) return fail("the dots' track must show while empty")
    checked++
  }

  // `shown`: true (the chrome shows as with reveal "always"), false (only
  // the hint: no surface or part), null (exactly as with "always").
  function checkReveal(key, primary, shown) {
    var field = findNamed(view, "inputField")
    var input = findNamed(view, "passwordInput")
    if (JSON.stringify(rect(field)) !== revealRects[key]) return fail("the field moved: " + JSON.stringify(rect(field)) + ", was " + revealRects[key])
    if (!field.visible || !input.enabled && !view.authenticatingPassword) return fail("the password field must stay live")
    if (!view.authenticatingPassword && !input.activeFocus) return fail("the password input lost focus")
    var now = chrome()
    if (shown === false) {
      for (var name in now)
        if (name !== "unlockHint" && now[name]) return fail(name + " shows while the field is hidden")
      if (now.unlockHint !== primary) return fail("the unlock hint must stay on the primary screen")
      if (input.opacity !== 0) return fail("the idle editor shows")
      var scrim = findNamed(view, "scrim")
      if (scrim.color.a < 0.15 - 0.01) return fail("no scrim behind a hidden field: " + scrim.color.a)
    } else if (shown === null) {
      if (!view.authenticatingPassword && !view.failureMessage && !view.passwordText && !view.fingerprintUnavailable
          && JSON.stringify(now) !== revealRects[key + " parts"])
        return fail("reveal typing changed a style it doesn't apply to: " + JSON.stringify(now) + ", was " + revealRects[key + " parts"])
    } else if (!now.surface && !now.fieldUnderline && view.placed.password.style !== "dots") {
      // (The dots have no surface: typed, the dots themselves show.)
      return fail("the field stays hidden: " + JSON.stringify(now))
    }
    checked++
  }
  property int stateAt: 0
  property int cycleAt: -1
  property var reference: null
  property var fieldSizes: ({})
  property bool busy: false
  // Positioners (Row) lay out at polish time: each state is applied on one
  // tick and checked on the next, after a frame.
  property bool applied: false
  // The cycle shows each look left-to-right, then right-to-left.
  property var mirrorRef: null
  property int mirrorPhase: 0
  property int checked: 0
  property int captured: 0
  property string label: ""

  FloatingWindow {
    visible: true
    implicitWidth: 1920; implicitHeight: 1080
    color: "black"
    LockView {
      id: view
      width: 1920; height: 1080
      userName: "foamy"
      userDisplayName: "Foamy User"
      backgroundPath: Qt.resolvedUrl("wallpaper.svg").toString().replace("file://", "")
      activePlayer: player
      artworkPath: Qt.resolvedUrl("artwork.svg").toString().replace("file://", "")
      fingerprintConfigured: true
      avatarPath: Qt.resolvedUrl("artwork.svg").toString().replace("file://", "")
      weather: shellRoot.widestWeather
      onPasswordTextEdited: function(value) { passwordText = value }
      onClearFailureRequested: failureMessage = ""
    }
  }
  QtObject {
    id: player
    property string trackTitle: "Evening Light"
    property string trackArtist: "Sample Artist"
    property bool isPlaying: true
    property bool canGoPrevious: true
    property bool canGoNext: true
    property bool canTogglePlaying: true
    property bool canPlay: true
    property bool canPause: true
  }

  function findNamed(item, name) {
    if (item.objectName === name) return item
    for (var i = 0; i < item.children.length; i++) {
      var found = findNamed(item.children[i], name)
      if (found) return found
    }
    return null
  }
  function fail(message) {
    console.error("STYLES_FAIL [" + label + "] " + message)
    Qt.exit(1)
    step.running = false
  }
  function rect(item) {
    var at = item.mapToItem(view, 0, 0)
    return { x: at.x, y: at.y, width: item.width, height: item.height }
  }
  function geometry() {
    var out = {}
    for (var i = 0; i < tracked.length; i++) {
      var item = findNamed(view, tracked[i])
      var r = rect(item)
      out[tracked[i]] = [Math.round(r.x), Math.round(r.y), Math.round(r.width), Math.round(r.height), item.visible].join(",")
    }
    return out
  }

  // Visible elements and their parts: elements in view coordinates, parts in
  // their element's, each as the bounding box of its mapped corners (the
  // submit arrow mirrors with a transform).
  function box(item, target) {
    var a = item.mapToItem(target, 0, 0), b = item.mapToItem(target, item.width, item.height)
    return { x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), width: Math.abs(b.x - a.x), height: Math.abs(b.y - a.y) }
  }
  function partRects() {
    var out = {}
    for (var owner in parts) {
      var item = findNamed(view, owner)
      if (!item.visible) continue
      out[owner] = { rect: box(item, view), width: item.width, parts: {} }
      for (var i = 0; i < parts[owner].length; i++) {
        var part = findNamed(item, parts[owner][i])
        if (part && part.visible) out[owner].parts[parts[owner][i]] = box(part, item)
      }
    }
    return out
  }
  // Right-to-left mirrors every element in the view and every part in its
  // element (within a pixel of rounding).
  function checkMirror(ltr) {
    var rtl = partRects()
    function near(a, b) { return Math.abs(a - b) <= 1 }
    for (var owner in ltr) {
      if (!rtl[owner]) return fail(owner + " vanished in right-to-left")
      var l = ltr[owner].rect, r = rtl[owner].rect
      if (!near(r.x, view.width - l.x - l.width) || !near(r.y, l.y) || !near(r.width, l.width))
        return fail(owner + " doesn't mirror: " + [r.x, r.y, r.width] + " for " + [l.x, l.y, l.width])
      for (var name in ltr[owner].parts) {
        var lp = ltr[owner].parts[name], rp = rtl[owner].parts[name]
        if (!rp) return fail(name + " vanished in right-to-left")
        if (!near(rp.x, ltr[owner].width - lp.x - lp.width) || !near(rp.y, lp.y) || !near(rp.width, lp.width))
          return fail(name + " doesn't mirror in " + owner + ": " + [rp.x, rp.y, rp.width] + " for " + [lp.x, lp.y, lp.width])
      }
    }
  }

  function apply(look, state) {
    var size = sizes[state[0]]
    view.width = size[0]; view.height = size[1]
    view.timeFormat = state[1] ? "12h" : "24h"
    view.passwordText = state[2] ? "example" : ""
    view.primary = state[3]
    view.look = look
  }

  // Everything a sensible layout must keep, in any style.
  function check(state, fieldKey) {
    view.checkGeometry()
    if (view.fallbackPreset !== "" || view.layoutError !== "")
      return fail("fell back: " + view.layoutError + " -> " + view.fallbackPreset)
    var field = findNamed(view, "inputField")
    var input = findNamed(view, "passwordInput")
    if (!field.visible || !input.enabled) return fail("the password field must stay live")
    if (!input.activeFocus) return fail("the password input lost focus")
    var margin = Math.round(4 * view.uiScale)
    if (field.x < margin || field.y < margin || field.x + field.width > view.width - margin
        || field.y + field.height > view.height - margin)
      return fail("field outside the view: " + [field.x, field.y, field.width, field.height])
    // A fixed size per style and screen: typing or states never resize it.
    var size = [field.width, field.height].join("x")
    if (fieldSizes[fieldKey] === undefined) fieldSizes[fieldKey] = size
    else if (fieldSizes[fieldKey] !== size) return fail("the field changed size: " + size + ", was " + fieldSizes[fieldKey])
    var hint = findNamed(view, "unlockHint")
    var primary = state[3], typing = state[2]
    if (primary && !typing && !hint.visible) return fail("primary view without the unlock hint")
    if (!primary && !typing && hint.visible) return fail("field chrome shows on a secondary screen while nothing is typed")
    if (typing && input.opacity !== 1) return fail("typed dots are invisible")
    if (hint.visible) {
      var h = rect(hint)
      if (h.x < 0 || h.y < 0 || h.x + h.width > view.width || h.y + h.height > view.height)
        return fail("unlock hint outside the view: " + [h.x, h.y, h.width, h.height])
    }
    var account = findNamed(view, "identityBlock")
    var avatar = findNamed(view, "avatar")
    if (!primary && account.visible) return fail("the account shows on a secondary screen")
    if (primary && !view.placed.account.hidden && !account.visible) return fail("the account is missing on the primary screen")
    if (account.visible && avatar.visible && Math.abs(avatar.width - avatar.height) > 1)
      return fail("the avatar isn't square: " + avatar.width + "x" + avatar.height)
    // Every named item shows, once its source has read something.
    var items = view.placed.status.items
    if (items && findNamed(view, "statusFooter").visible) {
      var line = view.placed.status.style !== "system"
      for (var n = 0; n < items.length; n++) {
        var proc = ["uptime", "load", "memory"].indexOf(items[n]) !== -1
        if (proc && !(view.systemUptime >= 0 && view.memoryTotal > 0 && view.systemLoad !== "")) continue
        if (line && !findNamed(view, items[n] + "Status").visible) return fail("status item " + items[n] + " is missing")
      }
      if (!line && findNamed(view, "systemPanel").height <= 0) return fail("the system panel is empty")
    }
    if (view.placed.weather && !view.placed.weather.hidden && !findNamed(view, "weatherBlock").visible)
      return fail("the weather is missing")
    for (var owner in parts) {
      var item = findNamed(view, owner)
      if (!item.visible) continue
      var r = rect(item)
      if (r.x < -1 || r.y < -1 || r.x + r.width > view.width + 1 || r.y + r.height > view.height + 1)
        return fail(owner + " outside the view: " + [r.x, r.y, r.width, r.height])
      for (var i = 0; i < parts[owner].length; i++) {
        var part = findNamed(item, parts[owner][i])
        if (!part || !part.visible) continue
        var p = part.mapToItem(item, 0, 0)
        if (p.x < -1 || p.y < -1 || p.x + part.width > item.width + 1 || p.y + part.height > item.height + 1)
          return fail(parts[owner][i] + " outside " + owner + ": " + [p.x, p.y, part.width, part.height] + " in " + [item.width, item.height])
      }
    }
    checked++
  }

  // Every pending positioner layout, children first. The step's 30 ms timer
  // can come before the frame that would run them (a loaded machine), and
  // a half-laid-out view isn't what is drawn: the status line's parts at
  // the new scale in its Flow at the old one.
  function polishAll(item) {
    for (var i = 0; i < item.children.length; i++) polishAll(item.children[i])
    item.ensurePolished()
  }

  function grab(name) {
    if (!capture) return
    busy = true
    var path = Qt.resolvedUrl("capture-" + name + ".png").toString().replace("file://", "")
    if (!view.grabToImage(function(result) {
      if (!result.saveToFile(path)) shellRoot.fail("capture save failed")
      shellRoot.captured++
      shellRoot.busy = false
    })) fail("capture failed")
  }

  Timer {
    id: step
    interval: 30
    repeat: true
    running: true
    onTriggered: {
      if (shellRoot.busy) return
      shellRoot.polishAll(view)
      if (shellRoot.caseAt < shellRoot.cases.length) {
        var item = shellRoot.cases[shellRoot.caseAt]
        var state = shellRoot.states[shellRoot.stateAt]
        var parsed = Layout.parseLook({ layout: item.layout })
        shellRoot.label = item.element + " " + item.style + " " + item.column + " " + shellRoot.sizes[state[0]].join("x")
          + (state[1] ? " 12h" : "") + (state[2] ? " typing" : "") + (state[3] ? "" : " secondary")
        if (!parsed.valid) return shellRoot.fail("invalid layout: " + parsed.error)
        if (!shellRoot.applied) {
          shellRoot.apply(parsed.look, state)
          shellRoot.applied = true
          return
        }
        shellRoot.applied = false
        shellRoot.check(state, shellRoot.caseAt + "@" + state[0])
        // Two captures per case: wide idle 24h and narrow typing 12h.
        if (state[3] && ((state[0] === 0 && !state[1] && !state[2]) || (state[0] === 1 && state[1] && state[2])))
          shellRoot.grab([item.element, item.style, item.column, state[0] === 0 ? "wide" : "narrow"].join("-"))
        if (++shellRoot.stateAt === shellRoot.states.length) {
          console.log("styles ok: " + item.element + " " + item.style + " " + item.column)
          shellRoot.stateAt = 0
          shellRoot.caseAt++
        }
        return
      }
      if (shellRoot.cycleAt === -1) {
        shellRoot.label = "cycle start"
        if (!shellRoot.applied) {
          shellRoot.apply(Layout.defaults(), [0, false, false, true])
          shellRoot.applied = true
          return
        }
        shellRoot.applied = false
        shellRoot.reference = shellRoot.geometry()
        shellRoot.cycleAt = 0
        return
      }
      if (shellRoot.cycleAt < shellRoot.cycle.length) {
        var entry = shellRoot.cycle[shellRoot.cycleAt]
        shellRoot.label = "cycle " + shellRoot.cycleAt + " " + entry.name
        var look = Layout.parseLook({ layout: entry.layout })
        if (!look.valid) return shellRoot.fail("invalid layout: " + look.error)
        if (!shellRoot.applied) {
          shellRoot.apply(look.look, [0, false, false, true])
          shellRoot.applied = true
          return
        }
        // Phases (a capture finishes before the next one changes the view):
        // check left-to-right, switch, check the mirror, switch back.
        var capture = entry.name.indexOf("all #") === 0 ? "cycle-" + entry.name.replace("all #", "all-") : ""
        if (shellRoot.mirrorPhase === 0) {
          shellRoot.check([0, false, false, true], "cycle " + entry.name)
          if (capture) shellRoot.grab(capture)
          shellRoot.mirrorRef = shellRoot.partRects()
          shellRoot.mirrorPhase = entry.name === "default" ? 3 : 1
          return
        }
        if (shellRoot.mirrorPhase === 1) {
          view.rightToLeft = true
          shellRoot.mirrorPhase = 2
          return
        }
        if (shellRoot.mirrorPhase === 2) {
          shellRoot.label += " right-to-left"
          shellRoot.check([0, false, false, true], "cycle " + entry.name)
          shellRoot.checkMirror(shellRoot.mirrorRef)
          if (capture) shellRoot.grab(capture + "-rtl")
          shellRoot.mirrorPhase = 3
          return
        }
        view.rightToLeft = false
        shellRoot.mirrorPhase = 0
        shellRoot.applied = false
        shellRoot.cycleAt++
        return
      }
      if (shellRoot.revealAt === -1) {
        var now = shellRoot.geometry()
        for (var key in now)
          if (now[key] !== shellRoot.reference[key])
            return shellRoot.fail("after the cycle " + key + " is " + now[key] + ", was " + shellRoot.reference[key])
        console.log("styles ok: cycle through " + (shellRoot.cycle.length - 1) + " looks back to foamy")
        shellRoot.revealAt = 0
        return
      }
      if (shellRoot.revealAt < shellRoot.revealSteps.length) {
        var revealStep = shellRoot.revealSteps[shellRoot.revealAt]
        shellRoot.label = "reveal " + revealStep.name
        if (!shellRoot.applied) {
          revealStep.apply()
          shellRoot.applied = true
          return
        }
        shellRoot.applied = false
        revealStep.check()
        shellRoot.revealAt++
        return
      }
      console.log("styles ok: reveal typing on " + Layout.STYLES.password.length + " field styles, primary and secondary")
      console.log("STYLES_PASS: " + shellRoot.cases.length + " cases, " + shellRoot.checked + " checks, " + shellRoot.captured + " captures")
      step.running = false
      Qt.quit()
    }
  }
}
