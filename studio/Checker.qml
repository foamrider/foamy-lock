pragma ComponentBehavior: Bound
import QtQuick
import "Draft.js" as Draft

// The geometry check for every size the look must work on: one hidden lock
// view per connected screen and reference size, running the lock's own
// geometryProblem() 300 ms after the look settles (like the lock's
// debounce). `problems` lists what is wrong where:
//   [{ key, label, reference, width, height, code, names }]
// `names` are the modules to outline (Draft.problemElements).
Item {
  id: checker

  property var look: null
  // [{ key, label, reference, width, height }]
  property var sizes: []
  property bool active: true
  property var problems: []
  // How long the last check took, for the cost note (ms).
  property real lastCheckMs: 0
  readonly property int viewCount: views.count

  visible: false

  onLookChanged: debounce.restart()
  onSizesChanged: debounce.restart()
  onActiveChanged: debounce.restart()

  function check() {
    var started = Date.now()
    var found = []
    for (var i = 0; i < views.count; i++) {
      var view = views.itemAt(i) as SampleView
      if (!view || !(view.width > 0)) continue
      var code = view.geometryProblem()
      if (!code) continue
      var size = checker.sizes[i]
      found.push({ key: size.key, label: size.label, reference: !!size.reference, width: size.width, height: size.height,
        code: code, names: Draft.problemElements(code, view.placed, view.elementRects, view.width, view.height) })
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
      width: modelData.width
      height: modelData.height
      look: checker.look || Draft.lookOf(null)
      previewState: "idle"
      displayAwake: false
      loadBackground: false
      // Late geometry (a font or image settling) re-runs the check.
      onGeometryProblemCodeChanged: debounce.restart()
    }
  }
}
