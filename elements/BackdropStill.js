.pragma library
// The drawn backgrounds' still frame for the software renderer (CPU
// rendering, reduced motion there, the tests and thumbnails): the picture
// each shader in shaders/ draws at a given time, painted once on two
// canvases (see Backdrop.qml). The smooth "field" is painted a column at a
// time at a fraction of the size (fieldFraction) and scaled up; the "points" (stars,
// drops, flakes, glyphs, glows) are drawn at full size. The hash is the
// shaders' (hash.glsl) bit for bit, so every point lands where the shader
// puts it; the curves are the same formulas in double precision.

var TAU = 2 * Math.PI

// Each animation's painters and still frame, by name (see animation()).
var FIELDS = {}
var POINTS = {}
var STILL_PHASES = {}

// Register an animation: the time its still frame shows (seconds into the
// loop), its field painter and its points painter (or null).
function animation(name, stillPhase, field, points) {
  STILL_PHASES[name] = stillPhase
  FIELDS[name] = field
  if (points) POINTS[name] = points
}

// The time an animation's still frame shows (0 for a name it doesn't know).
function stillPhase(name) {
  return STILL_PHASES.hasOwnProperty(name) ? STILL_PHASES[name] : 0
}

// Chris Wellons' lowbias32, as hash.glsl.
function lowbias(x) {
  x = (x ^ (x >>> 16)) >>> 0
  x = Math.imul(x, 0x7feb352d) >>> 0
  x = (x ^ (x >>> 15)) >>> 0
  x = Math.imul(x, 0x846ca68b) >>> 0
  return (x ^ (x >>> 16)) >>> 0
}

// hash.glsl's hash(a, b, salt): [0, 1), 24 bits.
function hash(a, b, salt) {
  return (lowbias((a + lowbias((b + lowbias(salt >>> 0)) >>> 0)) >>> 0) >>> 8) / 16777216
}

function smooth01(f) { return f * f * (3 - 2 * f) }

function noise1(x, row) {
  var i = Math.floor(x)
  var u = smooth01(x - i)
  var a = hash(i, row, 3)
  return a + (hash(i + 1, row, 3) - a) * u
}

function noise2(x, y, salt) {
  var ix = Math.floor(x), iy = Math.floor(y)
  var ux = smooth01(x - ix), uy = smooth01(y - iy)
  var a = hash(ix, iy, salt), b = hash(ix + 1, iy, salt)
  var c = hash(ix, iy + 1, salt), d = hash(ix + 1, iy + 1, salt)
  var top = a + (b - a) * ux, bottom = c + (d - c) * ux
  return top + (bottom - top) * uy
}

function clamp(x, lo, hi) { return x < lo ? lo : x > hi ? hi : x }
function mix(a, b, t) { return a + (b - a) * t }
function smoothstep(e0, e1, x) {
  var t = clamp((x - e0) / (e1 - e0), 0, 1)
  return t * t * (3 - 2 * t)
}
function rgb(c) { return [c.r, c.g, c.b] }
function css(c, a) {
  return "rgba(" + Math.round(clamp(c[0], 0, 1) * 255) + "," + Math.round(clamp(c[1], 0, 1) * 255) + ","
    + Math.round(clamp(c[2], 0, 1) * 255) + "," + clamp(a, 0, 1) + ")"
}

// hash.glsl's lay(): light `c` with coverage `a` over `dst` (in place).
function lay(dst, c, a, glow) {
  var over = a * (1 - glow), add = a * glow
  dst[0] = dst[0] + (c[0] - dst[0]) * over + c[0] * add
  dst[1] = dst[1] + (c[1] - dst[1]) * over + c[1] * add
  dst[2] = dst[2] + (c[2] - dst[2]) * over + c[2] * add
}

// Everything a painter needs, in one object (Backdrop binds it, so a change
// of size, phase or colour paints again).
function scene(kind, width, height, phase, loop, unit, glow, colors) {
  return { kind: kind, w: width, h: height, t: phase, loop: loop, turn: TAU * phase / loop, unit: unit, glow: glow,
    base: rgb(colors.base), accent: rgb(colors.accent), green: rgb(colors.green), cyan: rgb(colors.cyan),
    ink: rgb(colors.ink), warm: rgb(colors.warm) }
}

// The field's size as a fraction of the view's.
function fieldFraction(kind) {
  return FIELDS[kind] ? FIELDS[kind].fraction : 0.05
}

// Paint the field one column at a time, as a vertical gradient through the
// heights the painter names for it (`column`), each shaded (`shade`). Little
// is allocated per height (the garbage collector would cost seconds), and
// a whole column is one fill (QML's ImageData is far slower here).
function paintField(ctx, fw, fh, scene) {
  ctx.reset()
  var painter = FIELDS[scene.kind]
  if (!painter || scene.w <= 0 || scene.h <= 0) return
  var s = plain(scene)
  var color = [0, 0, 0]
  var field = painter.prepare(s, fw, fh)
  for (var cx = 0; cx < fw; cx++) {
    var heights = field.column((cx + 0.5) / fw)
    var gradient = ctx.createLinearGradient(0, 0, 0, fh)
    for (var k = 0; k < heights.length; k++) {
      var at = clamp(heights[k], 0, 1)
      field.shade(at, color)
      gradient.addColorStop(at, Qt.rgba(clamp(color[0], 0, 1), clamp(color[1], 0, 1), clamp(color[2], 0, 1), 1))
    }
    ctx.fillStyle = gradient
    ctx.fillRect(cx, 0, 1, fh)
  }
}

function paintPoints(ctx, pw, ph, scene) {
  ctx.reset()
  var painter = POINTS[scene.kind]
  if (!painter || scene.w <= 0 || scene.h <= 0) return
  ctx.save()
  ctx.scale(pw / scene.w, ph / scene.h)
  ctx.globalCompositeOperation = scene.glow > 0 ? "lighter" : "source-over"
  painter(ctx, plain(scene))
  ctx.restore()
}

// A plain copy of a scene (one read through a QML property may be a
// wrapper, slow in the inner loops).
function plain(s) {
  var copy = {}
  for (var key in s) {
    var value = s[key]
    copy[key] = typeof value === "object" && value !== null ? [value[0], value[1], value[2]] : value
  }
  return copy
}

// A soft dot: a radial falloff of `c` at `alpha` in the centre.
function dot(ctx, x, y, radius, c, alpha) {
  if (alpha <= 0.002 || radius <= 0) return
  var gradient = ctx.createRadialGradient(x, y, 0, x, y, radius)
  gradient.addColorStop(0, css(c, alpha))
  gradient.addColorStop(0.35, css(c, alpha * 0.45))
  gradient.addColorStop(1, css(c, 0))
  ctx.fillStyle = gradient
  ctx.fillRect(x - radius, y - radius, 2 * radius, 2 * radius)
}

// Evenly spaced heights, 0 to 1, plus `extra`, sorted.
function heightsWith(count, extra) {
  var list = []
  for (var i = 0; i <= count; i++) list.push(i / count)
  for (var j = 0; j < extra.length; j++) list.push(extra[j])
  return list.sort(function(a, b) { return a - b })
}

function mix3(a, b, t) { return [mix(a[0], b[0], t), mix(a[1], b[1], t), mix(a[2], b[2], t)] }
function fract(x) { return x - Math.floor(x) }

// The sky most animations share: the background, deeper at the top on a
// dark theme (`top` at the top, `bottom` at the bottom, of the background).
function sky(s, y, top, bottom, out) {
  var k = mix(mix(top, bottom, y), 1, 1 - s.glow)
  out[0] = s.base[0] * k; out[1] = s.base[1] * k; out[2] = s.base[2] * k
}

// A streak from (x0, y0) to (x1, y1) whose alpha follows `profile`, a list
// of [position along it, alpha] pairs.
function streak(ctx, x0, y0, x1, y1, width, c, profile, gain) {
  var gradient = ctx.createLinearGradient(x0, y0, x1, y1)
  for (var i = 0; i < profile.length; i++) gradient.addColorStop(profile[i][0], css(c, profile[i][1] * gain))
  ctx.strokeStyle = gradient
  ctx.lineWidth = width
  ctx.beginPath()
  ctx.moveTo(x0, y0)
  ctx.lineTo(x1, y1)
  ctx.stroke()
}

function posmod(a, b) { return ((a % b) + b) % b }

// A field of only the shared sky (and `extra`, painted over it).
function skyField(top, bottom, extra) {
  return {
    fraction: 0.05,
    prepare: function(s) {
      var heights = heightsWith(16, [])
      return {
        column: function() { return heights },
        shade: function(y, out) {
          sky(s, y, top, bottom, out)
          if (extra) extra(s, y, out)
        }
      }
    }
  }
}

// A glow: `c` at `alpha` in the centre, falling off as exp(-d / (radius / 4)).
var GLOW = [[0, 1], [0.12, 0.62], [0.25, 0.37], [0.5, 0.14], [0.75, 0.05], [1, 0]]
function glow(ctx, x, y, radius, c, alpha) {
  if (alpha <= 0.002 || radius <= 0) return
  var gradient = ctx.createRadialGradient(x, y, 0, x, y, radius)
  for (var i = 0; i < GLOW.length; i++) gradient.addColorStop(GLOW[i][0], css(c, alpha * GLOW[i][1]))
  ctx.fillStyle = gradient
  ctx.fillRect(x - radius, y - radius, 2 * radius, 2 * radius)
}

// ---- aurora (aurora.frag) ---------------------------------------------------

// Curtain i at x: [edge, rays, bloom] into `out`.
function auroraCurtain(s, i, x, aspect, out) {
  var turn = s.turn
  var sway = 0.9 * Math.sin(turn + i * 2.1) + 0.4 * Math.sin(2 * turn + i * 1.3)
  var xn = x / aspect
  var edge = i === 0 ? 0.42 + 0.09 * Math.sin(xn * 4.4 + 0.6 + 0.4 * sway)
    : 0.55 - 0.06 * Math.sin(xn * 3.1 + 2 - 0.4 * sway)
  edge += 0.11 * (noise1(x * 1.3 + i * 5.3 + sway, 10 + i) - 0.5)
    + 0.035 * (noise1(x * 4.2 - i * 2.9 - 0.7 * sway, 13 + i) - 0.5)
    + 0.02 * (noise1(x * 11 + 1.3 * sway, 16 + i) - 0.5)
    + 0.007 * (noise1(x * 27 - 2.1 * sway, 19 + i) - 0.5)
  var shimmer = 1.6 * Math.sin(3 * turn + i) + 0.8 * Math.sin(5 * turn + 2 * i)
  var rays = 0.25 + 0.75 * noise1(x * 48 + i * 17 + shimmer, 20 + i)
    * (0.6 + 0.4 * noise1(x * 130 - i * 11 - 1.7 * shimmer, 23 + i))
  var bloom = 0.3 + 0.7 * smoothstep(0.2, 0.8, noise1(x * 0.9 - i * 3.7 + 0.8 * Math.sin(2 * turn + i), 30 + i))
  out[0] = edge
  out[1] = rays
  out[2] = bloom * (i === 0 ? 1 : 0.7 * smoothstep(0.15, 0.55, xn))
}

function auroraLight(c, i, y) {
  var d = c[0] - y
  var height = (0.035 + 0.085 * c[1]) * (i === 0 ? 1 : 0.6)
  var rays = d >= 0 ? Math.exp(-d / height) * (0.3 + 0.7 * c[1]) : 0
  var edge = smoothstep(-0.008, 0.005, d) * (1 + 2 * Math.exp(-Math.abs(d) * 120))
  var haze = 0.1 * Math.exp(-Math.abs(d - 0.06) * 12)
  var fringe = d < 0 ? 0.35 * Math.exp(d * 45) : 0
  return (rays * edge + haze + fringe) * (0.05 + 0.95 * c[2])
}

function auroraRidge(x) {
  return 0.885 + 0.045 * (noise1(x * 2.2, 50) - 0.5) + 0.02 * (noise1(x * 7, 51) - 0.5)
}

// The light of both curtains at (x, y) in `out`, its sum returned; `curtains`
// holds each one's [edge, rays, bloom, gain].
function auroraAt(s, curtains, y, out) {
  var light = 0
  out[0] = out[1] = out[2] = 0
  for (var i = 0; i < 2; i++) {
    var c = curtains[i]
    var a = auroraLight(c, i, y) * c[3]
    var top = i === 0 ? s.accent : s.cyan
    var k = smoothstep(0, 0.12, c[0] - y)
    out[0] += mix(s.green[0], top[0], k) * a
    out[1] += mix(s.green[1], top[1], k) * a
    out[2] += mix(s.green[2], top[2], k) * a
    light += a
  }
  return light
}

function auroraCurtains(s, x, aspect, curtains) {
  var next = [0, 0, 0]
  for (var i = 0; i < 2; i++) {
    auroraCurtain(s, i, x, aspect, curtains[i])
    auroraCurtain(s, i, x + 0.01, aspect, next)
    var slope = (next[0] - curtains[i][0]) / 0.01
    curtains[i][3] = (i === 0 ? 0.95 : 0.6) * (0.75 + 0.5 * Math.min(Math.abs(slope), 1.5))
  }
}

var aurora = {
  fraction: 0.5,
  prepare: function(s, fw, fh) {
    var aspect = s.w / Math.max(s.h, 1)
    var curtains = [[0, 0, 0, 0], [0, 0, 0, 0]]
    var tint = [0, 0, 0]
    var ridge = 1
    return {
      column: function(ux) {
        var x = ux * aspect
        auroraCurtains(s, x, aspect, curtains)
        ridge = auroraRidge(x)
        var e0 = curtains[0][0], e1 = curtains[1][0]
        return heightsWith(24, [e0 - 0.03, e0 - 0.012, e0 - 0.006, e0, e0 + 0.004, e0 + 0.01, e0 + 0.02, e0 + 0.04,
          e1 - 0.03, e1 - 0.012, e1 - 0.006, e1, e1 + 0.004, e1 + 0.01, e1 + 0.02, e1 + 0.04,
          ridge - 0.002, ridge + 0.002])
      },
      shade: function(y, out) {
        var sky = mix(mix(0.6, 1, smoothstep(0, 1, y)), 1, 1 - s.glow)
        out[0] = s.base[0] * sky; out[1] = s.base[1] * sky; out[2] = s.base[2] * sky
        var light = auroraAt(s, curtains, y, tint)
        var n = Math.max(light, 1e-4)
        tint[0] /= n; tint[1] /= n; tint[2] /= n
        lay(out, tint, 1 - Math.exp(-light * 1.2), s.glow)
        var land = smoothstep(ridge - 0.002, ridge + 0.002, y) * mix(0.35, 1, s.glow)
        out[0] = mix(out[0], s.base[0] * 0.5, land)
        out[1] = mix(out[1], s.base[1] * 0.5, land)
        out[2] = mix(out[2], s.base[2] * 0.5, land)
      }
    }
  }
}

// Its faint stars, dimmer where the curtains are, none over the ridge.
function auroraPoints(ctx, s) {
  var aspect = s.w / Math.max(s.h, 1)
  var cell = 46 * s.unit
  var curtains = [[0, 0, 0, 0], [0, 0, 0, 0]], tint = [0, 0, 0]
  for (var gy = 0; gy * cell < s.h; gy++) {
    for (var gx = 0; gx * cell < s.w; gx++) {
      if (hash(gx, gy, 43) < 0.72) continue
      var x = (gx + 0.1 + 0.8 * hash(gx, gy, 41)) * cell
      var y = (gy + 0.1 + 0.8 * hash(gx, gy, 42)) * cell
      var ux = x / s.w * aspect, uy = y / s.h
      if (uy >= auroraRidge(ux) - 0.002) continue
      auroraCurtains(s, ux, aspect, curtains)
      var light = auroraAt(s, curtains, uy, tint)
      var twinkle = 0.6 + 0.4 * Math.sin(s.turn * Math.floor(8 + 20 * hash(gx, gy, 44)) + TAU * hash(gx, gy, 45))
      dot(ctx, x, y, 2.4 * s.unit, s.ink, twinkle * (1 - uy) * 0.55 / (1 + 4 * light))
    }
  }
}

animation("aurora", 21, aurora, auroraPoints)

// ---- rain (rain.frag) -------------------------------------------------------

var RAIN_WIND = 0.12
// rain.frag's smoothstep(0, 0.08, k) * pow(1 - k, 1.4), head (0) to tail (1).
var RAIN_PROFILE = [[0, 0], [0.04, 0.48], [0.08, 0.89], [0.2, 0.73], [0.4, 0.49], [0.6, 0.28], [0.8, 0.1], [1, 0]]

var rain = {
  fraction: 0.05,
  prepare: function(s) {
    var mist = mix3(s.accent, s.base, 0.4)
    var heights = heightsWith(16, [])
    return {
      column: function() { return heights },
      shade: function(y, out) {
        sky(s, y, 0.72, 1, out)
        lay(out, mist, 0.06 * smoothstep(0.55, 1, y), s.glow)
      }
    }
  }
}

function rainPoints(ctx, s) {
  for (var l = 0; l < 3; l++) {
    var spacing = (9 + 4.5 * l * l + 4 * l) * s.unit
    var len = (46 + 50 * l) * s.unit
    var width = (0.9 + 0.5 * l) * s.unit
    var tint = mix3(mix3(s.accent, s.base, 0.35 - 0.15 * l), s.ink, 0.15 + 0.15 * l)
    var gain = 0.22 + 0.2 * l
    var first = Math.floor(-RAIN_WIND * s.h / spacing) - 1
    var last = Math.ceil(s.w / spacing) + 1
    for (var c = first; c <= last; c++) {
      var x0 = (c + 0.5 + 0.5 * (hash(c, l, 1) - 0.5)) * spacing
      var period = s.h * (0.55 + 0.9 * hash(c, l, 3)) + len
      var laps = Math.floor(70 + 40 * l + 50 * hash(c, l, 2))
      var strength = 0.55 + 0.45 * hash(c, l, 5)
      // Heads where the shader's k is 0: y / period = f + m.
      var f = fract(hash(c, l, 4) + laps * s.t / s.loop)
      for (var m = 0; (f + m) * period - len < s.h; m++) {
        var head = (f + m) * period
        streak(ctx, x0 + RAIN_WIND * head, head, x0 + RAIN_WIND * (head - len), head - len,
          1.6 * width, tint, RAIN_PROFILE, gain * strength * 0.8)
      }
    }
  }
}

animation("rain", 4.4, rain, rainPoints)

// ---- stars (stars.frag) -----------------------------------------------------

function galaxy(ux, uy, aspect) {
  var px = ux * aspect
  var d = (uy - 0.92 + 0.7 * ux) / 0.17
  var band = Math.exp(-d * d)
  if (band < 0.001) return 0
  var clumps = 0.55 * noise2(px * 3, uy * 3, 61) + 0.3 * noise2(px * 7, uy * 7, 62) + 0.15 * noise2(px * 15, uy * 15, 63)
  return band * smoothstep(0.25, 0.85, clumps)
}

var stars = {
  fraction: 0.125,
  prepare: function(s) {
    var aspect = s.w / Math.max(s.h, 1)
    var tint = [0, 0, 0]
    var heights = heightsWith(48, [])
    var x = 0
    return {
      column: function(ux) { x = ux; return heights },
      shade: function(y, out) {
        sky(s, y, 0.62, 0.95, out)
        var milky = galaxy(x, y, aspect)
        if (milky <= 0) return
        var k = 0.35 + 0.3 * noise2(x * 4, y * 4, 64)
        tint[0] = mix(s.accent[0], s.cyan[0], k); tint[1] = mix(s.accent[1], s.cyan[1], k); tint[2] = mix(s.accent[2], s.cyan[2], k)
        lay(out, tint, 0.1 * milky, s.glow)
      }
    }
  }
}

function starsPoints(ctx, s) {
  var aspect = s.w / Math.max(s.h, 1)
  for (var l = 0; l < 3; l++) {
    var cell = (24 + 26 * l * l) * s.unit
    var salt = 70 + 10 * l
    var gain = 0.45 + 0.25 * l
    for (var gy = 0; gy * cell < s.h; gy++) {
      for (var gx = 0; gx * cell < s.w; gx++) {
        var x = (gx + 0.15 + 0.7 * hash(gx, gy, salt + 1)) * cell
        var y = (gy + 0.15 + 0.7 * hash(gx, gy, salt + 2)) * cell
        // The shader decides with the cell's own Milky Way (at the pixel; the
        // star's centre is close enough).
        var chance = l === 0 ? 0.3 + 0.55 * galaxy(x / s.w, y / s.h, aspect) : 0.55
        if (hash(gx, gy, salt) > chance) continue
        var bright = Math.pow(hash(gx, gy, salt + 3), 2.2 - 0.6 * l)
        var size = (0.55 + 0.35 * l + 0.9 * bright * l) * s.unit
        var speed = Math.floor(12 + 50 * hash(gx, gy, salt + 4))
        var twinkle = 0.55 + 0.45 * Math.sin(s.turn * speed + TAU * hash(gx, gy, salt + 5))
        var hue = hash(gx, gy, salt + 6)
        var tint = hue < 0.12 ? mix3(s.ink, s.warm, 0.55) : hue > 0.9 ? mix3(s.ink, s.cyan, 0.5) : s.ink
        var light = (0.25 + 0.75 * bright) * mix(1, twinkle, 0.4 + 0.4 * bright) * gain
        dot(ctx, x, y, Math.max(1.3, 3 * size), tint, Math.min(1, light))
        if (bright > 0.2) dot(ctx, x, y, 9 * size, tint, 0.05 * bright * light)
        if (l === 2 && bright > 0.55) {
          var arm = 10 * s.unit
          var spike = [[0, 0], [0.5, 0.5 * bright * light], [1, 0]]
          streak(ctx, x - arm, y, x + arm, y, 1.1 * s.unit, tint, spike, 1)
          streak(ctx, x, y - arm, x, y + arm, 1.1 * s.unit, tint, spike, 1)
        }
      }
    }
  }
  // A shooting star, if one is crossing at this moment.
  for (var k = 0; k < 3; k++) {
    var start = s.loop * (k + 0.15 + 0.6 * hash(k, 0, 90)) / 3
    var p = (s.t - start) / 1.1
    if (p < 0 || p > 1) continue
    var fromX = (0.15 + 0.7 * hash(k, 0, 91)) * s.w, fromY = (0.06 + 0.3 * hash(k, 0, 92)) * s.h
    var dx = hash(k, 0, 93) < 0.5 ? -1 : 1, dy = 0.45, n = Math.sqrt(dx * dx + dy * dy)
    dx /= n; dy /= n
    var reach = 0.28 * s.w, tail = 0.35 * reach
    var hx = fromX + dx * reach * p, hy = fromY + dy * reach * p
    streak(ctx, hx, hy, hx - dx * tail, hy - dy * tail, 2 * s.unit, s.ink, [[0, 0.8], [1, 0]], Math.sin(p * Math.PI))
  }
}

animation("stars", 7, stars, starsPoints)

// ---- matrix (matrix.frag) ---------------------------------------------------

function matrixDot(glyph, gx, gy) {
  var mirrored = hash(glyph, 0, 7) < 0.65 ? Math.min(gx, 4 - gx) : gx
  return hash(glyph, mirrored + 5 * gy, 8) < 0.46
}

function matrixPoints(ctx, s) {
  var head = mix3(s.accent, s.ink, 0.75)
  for (var l = 0; l < 2; l++) {
    var scale = l === 0 ? 0.62 : 1
    var cw = 15 * s.unit * scale, ch = 21 * s.unit * scale
    var salt = 200 + 20 * l
    var offset = l === 0 ? 0.5 * cw : 0
    var rows = Math.ceil(s.h / ch)
    var gain = l === 0 ? 0.32 : 0.78
    var trailColor = l === 0 ? mix3(s.accent, s.base, 0.3) : s.accent
    var dw = 0.72 * cw / 5, dh = 0.8 * ch / 7
    for (var c = Math.floor(offset / cw); c * cw - offset < s.w; c++) {
      var period = Math.floor(rows * (1.15 + 0.9 * hash(c, 0, salt)))
      var laps = Math.floor((l === 0 ? 10 : 14) + 14 * hash(c, 0, salt + 1))
      var top = Math.floor(fract(hash(c, 0, salt + 2) + laps * s.t / s.loop) * period)
      var trail = 7 + Math.floor(22 * hash(c, 0, salt + 3))
      for (var r = 0; r < rows; r++) {
        var behind = posmod(top - r, period)
        if (behind >= trail) continue
        var changes = Math.floor(60 + 300 * hash(c, r, salt + 4))
        var glyph = Math.floor(fract(hash(c, r, salt + 5) + s.t / s.loop) * changes) + 1000 * c + 37 * r
        ctx.fillStyle = css(behind < 1 ? head : trailColor, Math.pow(1 - behind / trail, 1.6) * gain)
        var x0 = c * cw - offset + 0.14 * cw, y0 = r * ch + 0.1 * ch
        for (var gy = 0; gy < 7; gy++)
          for (var gx = 0; gx < 5; gx++)
            if (matrixDot(glyph, gx, gy)) ctx.fillRect(x0 + (gx + 0.1) * dw, y0 + (gy + 0.1) * dh, 0.8 * dw, 0.8 * dh)
      }
    }
  }
}

animation("matrix", 9.5, skyField(0.7, 0.7), matrixPoints)

// ---- snow (snow.frag) -------------------------------------------------------

function snowPoints(ctx, s) {
  for (var l = 0; l < 4; l++) {
    var cell = (26 + 14 * l + 12 * l * l) * s.unit
    var radius = (1.6 + 1.2 * l + 1.1 * l * l) * s.unit
    var soft = 0.45 + 0.17 * l
    var salt = 300 + 20 * l
    var rows = Math.ceil(s.h / cell) + 1
    var fall = Math.floor(3 + 2 * l) * rows * cell * s.t / s.loop
    var tint = mix3(mix3(s.cyan, s.ink, 0.6), s.ink, l / 3)
    var gain = 0.5 + 0.1 * l
    for (var gy = Math.floor(-fall / cell); gy * cell < s.h - fall; gy++) {
      var r = posmod(gy, rows)
      for (var gx = 0; gx * cell < s.w; gx++) {
        if (hash(gx, r, salt) > 0.7) continue
        var sway = 0.18 * cell * Math.sin(s.turn * Math.floor(2 + 4 * hash(gx, r, salt + 1)) + TAU * hash(gx, r, salt + 2))
        var x = (gx + 0.3 + 0.4 * hash(gx, r, salt + 3)) * cell + sway
        var y = (gy + 0.2 + 0.6 * hash(gx, r, salt + 4)) * cell + fall
        var size = radius * (0.6 + 0.6 * hash(gx, r, salt + 5))
        var inner = clamp((size * (1 - soft) - 0.5 * s.unit) / size, 0, 0.95)
        var alpha = (0.45 + 0.55 * hash(gx, r, salt + 6)) * gain
        var gradient = ctx.createRadialGradient(x, y, 0, x, y, size)
        gradient.addColorStop(0, css(tint, alpha))
        gradient.addColorStop(inner, css(tint, alpha))
        gradient.addColorStop(mix(inner, 1, 0.5), css(tint, alpha * 0.5))
        gradient.addColorStop(1, css(tint, 0))
        ctx.fillStyle = gradient
        ctx.fillRect(x - size, y - size, 2 * size, 2 * size)
      }
    }
  }
}

animation("snow", 12, skyField(0.7, 1, function(s, y, out) {
  lay(out, mix3(s.cyan, s.ink, 0.5), 0.05 * smoothstep(0.5, 1, y), s.glow)
}), snowPoints)

// ---- fireflies (fireflies.frag) ---------------------------------------------

function meadow(x, row, at) { return at + 0.05 * (noise1(x, row) - 0.5) }

var fireflies = {
  fraction: 0.25,
  prepare: function(s) {
    var aspect = s.w / Math.max(s.h, 1)
    var back = 0, front = 0
    return {
      column: function(ux) {
        var x = ux * aspect
        back = meadow(x * 1.6, 450, 0.8)
        front = meadow(x * 2.4 + 9, 451, 0.9)
        return heightsWith(16, [back - 0.004, back + 0.004, front - 0.004, front + 0.004])
      },
      shade: function(y, out) {
        sky(s, y, 0.66, 0.92, out)
        var k = mix(0.3, 1, s.glow)
        var b = smoothstep(back - 0.004, back + 0.004, y) * k
        out[0] = mix(out[0], s.base[0] * 0.72, b); out[1] = mix(out[1], s.base[1] * 0.72, b); out[2] = mix(out[2], s.base[2] * 0.72, b)
        var f = smoothstep(front - 0.004, front + 0.004, y) * k
        out[0] = mix(out[0], s.base[0] * 0.5, f); out[1] = mix(out[1], s.base[1] * 0.5, f); out[2] = mix(out[2], s.base[2] * 0.5, f)
      }
    }
  }
}

function firefliesPoints(ctx, s) {
  for (var l = 0; l < 2; l++) {
    var cell = (l === 0 ? 150 : 260) * s.unit
    var core = (l === 0 ? 1.6 : 2.6) * s.unit
    var halo = (l === 0 ? 16 : 34) * s.unit
    var gain = l === 0 ? 0.85 : 0.7
    var salt = 400 + 20 * l
    for (var r = -1; r * cell < s.h + cell; r++) {
      for (var c = -1; c * cell < s.w + cell; c++) {
        if (hash(c, r, salt) >= 0.6) continue
        var a = Math.floor(1 + 2 * hash(c, r, salt + 1)), b = Math.floor(1 + 2 * hash(c, r, salt + 2))
        var x = (c + 0.5) * cell + 0.32 * cell * Math.sin(s.turn * a + TAU * hash(c, r, salt + 3))
        var y = (r + 0.5) * cell + 0.32 * cell * Math.sin(s.turn * b + TAU * hash(c, r, salt + 4))
        var beat = Math.sin(s.turn * Math.floor(7 + 9 * hash(c, r, salt + 5)) + TAU * hash(c, r, salt + 6))
        var pulse = Math.pow(0.5 + 0.5 * beat, 2.5)
        if (pulse <= 0.001) continue
        var tint = mix3(s.warm, s.green, 0.25 + 0.5 * hash(c, r, 470 + l))
        glow(ctx, x, y, 4 * halo, tint, Math.min(1, 0.75 * pulse) * gain)
        dot(ctx, x, y, 3 * core, mix3(tint, s.ink, 0.5), Math.min(1, pulse) * gain)
      }
    }
  }
}

animation("fireflies", 16, fireflies, firefliesPoints)

// ---- gradient (gradient.frag) -----------------------------------------------

var gradient = {
  fraction: 0.15,
  prepare: function(s) {
    var aspect = s.w / Math.max(s.h, 1)
    var turn = s.turn
    var heights = heightsWith(28, [])
    var colors = [s.accent, s.cyan, s.green, mix3(s.base, [0, 0, 0], mix(0, 0.45, s.glow))]
    var strength = mix(0.3, 0.4, s.glow)
    var ax = 0.8 * Math.cos(turn), ay = 0.8 * Math.sin(turn)
    var homes = [], k = [0, 0, 0, 0]
    for (var i = 0; i < 4; i++) {
      homes.push([(0.2 + 0.2 * i + 0.1 * Math.floor(i / 2)) * aspect + 0.32 * aspect * Math.sin(turn * (i === 1 ? 2 : 1) + i * 1.7),
        (i % 2 === 0 ? 0.3 : 0.72) + 0.26 * Math.cos(turn * (i === 2 ? 2 : 1) + i * 2.3)])
    }
    var ux = 0
    return {
      column: function(x) { ux = x; return heights },
      shade: function(uy, out) {
        var px = ux * aspect, py = uy
        var wx = 0.22 * (noise2(px * 1.4 + ax, py * 1.4 + ay, 501) - 0.5)
        var wy = 0.22 * (noise2(px * 1.4 - ax + 7, py * 1.4 - ay + 7, 502) - 0.5)
        px += wx; py += wy
        out[0] = s.base[0]; out[1] = s.base[1]; out[2] = s.base[2]
        for (var i = 0; i < 4; i++) {
          var dx = px - homes[i][0], dy = py - homes[i][1]
          var w = Math.exp(-(dx * dx + dy * dy) / (i === 3 ? 0.3 : 0.14)) * (i === 3 ? 0.8 : strength)
          var c = colors[i]
          out[0] = mix(out[0], c[0], w); out[1] = mix(out[1], c[1], w); out[2] = mix(out[2], c[2], w)
        }
        var lift = 0.2126 * (out[0] - s.base[0]) + 0.7152 * (out[1] - s.base[1]) + 0.0722 * (out[2] - s.base[2])
        if (Math.abs(lift) > 0.001) {
          var keep = 0.22 * (1 - Math.exp(-Math.abs(lift) / 0.22)) / Math.abs(lift)
          out[0] = mix(s.base[0], out[0], keep); out[1] = mix(s.base[1], out[1], keep); out[2] = mix(s.base[2], out[2], keep)
        }
        var vx = ux - 0.5, vy = uy - 0.5
        var v = mix(1, 1 - 0.5 * (vx * vx + vy * vy), s.glow)
        out[0] *= v; out[1] *= v; out[2] *= v
      }
    }
  }
}

animation("gradient", 30, gradient, null)

// ---- ocean (ocean.frag) -----------------------------------------------------

var OCEAN_BANDS = 8, OCEAN_HORIZON = 0.6, OCEAN_MOON = [0.74, 0.2]

function oceanCrest(i, x, turn) {
  var depth = Math.pow((i + 1) / OCEAN_BANDS, 1.5)
  var y = OCEAN_HORIZON + (1 - OCEAN_HORIZON) * depth - 0.02
  var amp = 0.004 + 0.022 * depth
  var k = 9 / (0.35 + depth)
  var w1 = Math.sin(x * k + turn * Math.floor(2 + 3 * hash(i, 0, 600)) + TAU * hash(i, 0, 601))
  var w2 = Math.sin(x * k * 2.3 - turn * Math.floor(3 + 3 * hash(i, 0, 602)) + TAU * hash(i, 0, 603))
  return y - amp * (0.65 * w1 + 0.35 * w2)
}

var ocean = {
  fraction: 0.35,
  prepare: function(s) {
    var aspect = s.w / Math.max(s.h, 1)
    var tint = mix3(s.accent, s.cyan, 0.4)
    var moonGlow = mix3(s.ink, tint, 0.4), path = mix3(s.ink, tint, 0.3)
    var mx = OCEAN_MOON[0] * aspect, my = OCEAN_MOON[1]
    var crests = [], x = 0
    var water = [0, 0, 0]
    return {
      column: function(ux) {
        x = ux * aspect
        var extra = []
        for (var i = 0; i < OCEAN_BANDS; i++) {
          var c = oceanCrest(i, x, s.turn)
          crests[i] = c
          var px = 1 / s.h
          extra.push(c - px, c, c + 2 * px, c + 5 * px, c + 12 * px, c + 0.03)
        }
        var dx = x - mx
        // The moon's rim (smoothstep(0.031, 0.027, r)) where this column crosses it.
        for (var rim = 0.027; rim < 0.032; rim += 0.004) {
          if (Math.abs(dx) < rim) {
            var half = Math.sqrt(rim * rim - dx * dx)
            extra.push(my - half, my + half)
          }
        }
        return heightsWith(24, extra)
      },
      shade: function(y, out) {
        sky(s, Math.min(1, y / OCEAN_HORIZON), 0.6, 1, out)
        lay(out, tint, 0.08 * smoothstep(OCEAN_HORIZON - 0.3, OCEAN_HORIZON, y), s.glow)
        var dx = x - mx, dy = y - my
        var r = Math.sqrt(dx * dx + dy * dy)
        lay(out, moonGlow, 0.1 * Math.exp(-r * 10), s.glow)
        lay(out, s.ink, 0.7 * smoothstep(0.031, 0.027, r), s.glow)
        if (y <= OCEAN_HORIZON - 0.03) return
        var band = -1, top = 0
        for (var i = 0; i < OCEAN_BANDS; i++) if (y >= crests[i]) { band = i; top = crests[i] }
        if (band < 0) return
        var depth = (band + 1) / OCEAN_BANDS
        var light = mix(0.5, 1, s.glow)
        for (var k = 0; k < 3; k++) {
          var w = mix(mix(s.base[k], tint[k], 0.3), s.base[k] * 0.55, depth)
          water[k] = mix(s.base[k], w, light)
        }
        var below = smoothstep(0, 1, (y - top) / (0.02 + 0.05 * depth))
        out[0] = mix(water[0], water[0] * 0.8, below)
        out[1] = mix(water[1], water[1] * 0.8, below)
        out[2] = mix(water[2], water[2] * 0.8, below)
        var foam = Math.exp(-(y - top) * s.h / ((1 + 2 * depth) * s.unit))
        lay(out, s.ink, 0.16 * foam * (0.5 + 0.5 * depth), s.glow)
        var spread = 0.03 + 0.18 * (y - OCEAN_HORIZON)
        var p = (x - mx) / spread
        var glint = Math.min(1, Math.exp(-(y - top) * s.h / (2.5 * s.unit)) + 0.25 * foam)
        lay(out, path, 0.5 * Math.exp(-p * p) * glint, s.glow)
      }
    }
  }
}

animation("ocean", 18, ocean, null)