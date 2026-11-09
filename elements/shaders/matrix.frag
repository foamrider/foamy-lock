#version 440
#extension GL_GOOGLE_include_directive : require
// Matrix: columns of glyphs falling in the accent, a near layer and a
// smaller, dimmer far one. A glyph is a 5 × 7 grid of dots, from a hash
// (mostly mirror-symmetric, like a character); each trail's head is the
// brightest, nearly the foreground, and the trail fades behind it. The
// heads step a cell at a time, a whole number of passes per loop, and
// glyphs change a whole number of times per loop.
// BackdropStill.js draws the same glyphs on the CPU.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
#include "common.glsl"
#include "hash.glsl"

// One glyph's dot (column gx 0..4, row gy 0..6) is lit.
bool glyphDot(int glyph, int gx, int gy) {
    int mirrored = hash(glyph, 0, 7) < 0.65 ? min(gx, 4 - gx) : gx;
    return hash(glyph, mirrored + 5 * gy, 8) < 0.46;
}

// Layer `l` at px: the light (0..1) and how near the head (1 at it).
vec2 layer(int l, vec2 px) {
    float scale = l == 0 ? 0.62 : 1.0;
    vec2 cell = vec2(15.0, 21.0) * u_unit * scale;
    int salt = 200 + 20 * l;
    // Far columns sit between the near ones.
    vec2 q = px + vec2(l == 0 ? 0.5 * cell.x : 0.0, 0.0);
    vec2 g = floor(q / cell);
    int c = int(g.x), r = int(g.y);
    float rows = ceil(u_size.y / cell.y);
    float period = floor(rows * (1.15 + 0.9 * hash(c, 0, salt)));
    float laps = floor((l == 0 ? 10.0 : 14.0) + 14.0 * hash(c, 0, salt + 1));
    float head = floor(fract(hash(c, 0, salt + 2) + laps * u_time / u_loop) * period);
    float trail = 7.0 + floor(22.0 * hash(c, 0, salt + 3));
    float behind = mod(head - float(r), period);
    if (behind >= trail) return vec2(0.0);
    // The glyph changes a whole number of times per loop.
    float changes = floor(60.0 + 300.0 * hash(c, r, salt + 4));
    int glyph = int(floor(fract(hash(c, r, salt + 5) + u_time / u_loop) * changes)) + 1000 * c + 37 * r;
    vec2 f = (q - g * cell) / cell;
    vec2 grid = (f - vec2(0.14, 0.1)) / vec2(0.72, 0.8) * vec2(5.0, 7.0);
    if (grid.x < 0.0 || grid.y < 0.0 || grid.x >= 5.0 || grid.y >= 7.0) return vec2(0.0);
    vec2 inDot = fract(grid) - 0.5;
    float lit = glyphDot(glyph, int(grid.x), int(grid.y)) ? 1.0 : 0.0;
    float shape = smoothstep(0.5, 0.3, max(abs(inDot.x), abs(inDot.y)));
    float fade = pow(1.0 - behind / trail, 1.6);
    return vec2(lit * shape * fade, behind < 1.0 ? 1.0 : 0.0);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * u_size;
    vec3 base = u_base.rgb;
    vec3 col = base * mix(0.7, 1.0, 1.0 - u_glow);
    vec3 head = mix(u_accent.rgb, u_ink.rgb, 0.75);
    vec2 far = layer(0, px);
    col = lay(col, mix(mix(u_accent.rgb, base, 0.3), head, far.y), far.x * 0.32);
    vec2 near = layer(1, px);
    col = lay(col, mix(u_accent.rgb, head, near.y), near.x * 0.78);
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
