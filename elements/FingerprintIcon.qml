import QtQuick

Canvas {
  property color lineColor: "white"

  antialiasing: true
  onLineColorChanged: requestPaint()
  onWidthChanged: requestPaint()
  onHeightChanged: requestPaint()

  onPaint: {
    var context = getContext("2d")
    var centerX = width / 2
    var centerY = height / 2
    var unit = Math.min(width, height)
    context.clearRect(0, 0, width, height)
    context.strokeStyle = lineColor
    context.fillStyle = lineColor
    context.lineWidth = Math.max(1.4, unit * 0.075)
    context.lineCap = "round"
    context.lineJoin = "round"

    context.beginPath()
    context.arc(centerX, centerY + unit * 0.02, unit * 0.34, Math.PI * 1.06, Math.PI * 1.94)
    context.stroke()
    context.beginPath()
    context.arc(centerX, centerY + unit * 0.08, unit * 0.24, Math.PI * 1.04, Math.PI * 1.96)
    context.stroke()
    context.beginPath()
    context.arc(centerX, centerY + unit * 0.13, unit * 0.13, Math.PI * 1.02, Math.PI * 1.98)
    context.stroke()
    context.beginPath()
    context.moveTo(centerX - unit * 0.31, centerY + unit * 0.12)
    context.quadraticCurveTo(centerX - unit * 0.25, centerY + unit * 0.38, centerX - unit * 0.09, centerY + unit * 0.45)
    context.moveTo(centerX + unit * 0.31, centerY + unit * 0.12)
    context.quadraticCurveTo(centerX + unit * 0.25, centerY + unit * 0.38, centerX + unit * 0.09, centerY + unit * 0.45)
    context.stroke()
  }
}
