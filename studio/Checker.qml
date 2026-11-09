pragma ComponentBehavior: Bound
import QtQuick
import "Draft.js" as Draft
import "Layout.js" as Layout

// The geometry check for every size the look must work on: one hidden lock
// view per connected screen and reference size, running the lock's own
// geometryProblem() 300 ms after the look settles (like the lock's
// debounce). Each view has the widest samples (SampleView.widest).
// `problems` lists what is wrong where:
//   [{ key, label, reference, width, height, code, names }]
// `names` are the modules to outline (Draft.problemElements). The shapes'
// advice (Layout.shapeAdvice: a module across a shape's edge or outside a
// frame, frosted shapes overlapping, a shape around nothing) comes after,
// with `advice: true` and the shape's index: a warning, never a block.
Item {
  id: checker

  property var look: null
  // [{ key, label, reference, width, height }]
  property var sizes: []
  property bool active: true
  // The lock's settings (time format, user info, media), as on the lock.
  property var settings: ({ timeFormat: "24h", showUserInfo: true, showMedia: true })
  property var problems: []
  // How long the last check took, for the cost note (ms).
  property real lastCheckMs: 0
  readonly property int viewCount: views.count

  visible: false

  onLookChanged: debounce.restart()
  onSizesChanged: debounce.restart()
  onActiveChanged: debounce.restart()
  onSettingsChanged: debounce.restart()

  // A check is due (the look or the sizes changed less than 300 ms ago):
  // the problems may be out of date.
  readonly property bool pending: debounce.running

  // Each view checks the size it was made for (its own modelData), so a
  // screen plugged in or out while a check is due never pairs a view with
  // another screen's size.
  function check() {
    var started = Date.now()
    var found = []
    for (var i = 0; i < views.count; i++) {
      var view = views.itemAt(i)
      if (!view || !(view.width > 0) || !view.size) continue
      var code = view.geometryProblem()
      var size = view.size
      if (code) found.push({ key: size.key, label: size.label, reference: !!size.reference, width: size.width, height: size.height,
        code: code, names: Draft.problemElements(code, view.placed, view.elementRects, view.width, view.height) })
      var advice = Layout.shapeAdvice(view.effectiveLook, view.elementRects, view.shapeGeometry)
      for (var a = 0; a < advice.length; a++)
        found.push({ key: size.key, label: size.label, reference: !!size.reference, width: size.width, height: size.height,
          code: advice[a].code, names: advice[a].names, advice: true, shape: advice[a].index })
    }
    lastCheckMs = Date.now() - started
    if (!Draft.same(found, problems)) problems = found
  }

  Timer {
    id: debounce
    interval: 300
    onTriggered: checker.check()
  }

  Repeater {
    id: views
    model: checker.active ? checker.sizes : []

    SampleView {
      required property var modelData
      readonly property var size: modelData
      width: modelData.width
      height: modelData.height
      look: checker.look || Draft.lookOf(null)
      previewState: "idle"
      displayAwake: false
      loadBackground: false
      // The widest samples: full weather with a long condition and place,
      // and every status item with a long reading (the /proc ones too:
      // asleep, this view reads nothing).
      widest: true
      systemUptime: 8639999
      systemLoad: "88.88 88.88 88.88"
      memoryTotal: 134217728
      memoryAvailable: 1048576
      timeFormat: checker.settings.timeFormat
      showUserInfo: checker.settings.showUserInfo
      showMedia: checker.settings.showMedia
      // Late geometry (a font or image settling) re-runs the check.
      onGeometryProblemCodeChanged: debounce.restart()
    }
  }
}
