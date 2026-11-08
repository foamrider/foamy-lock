#version 440
#extension GL_GOOGLE_include_directive : require
// Snow: flakes at four depths, small, faint and slow far away, large and
// soft near, each swaying as it falls; a faint glow low down. A layer falls
// a whole number of its own heights per loop.
// BackdropStill.js draws the same flakes on the CPU.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
#include "common.glsl"
#include "hash.glsl"

// Layer l's flake light at px.
float flakes(int l, vec2 px, float turn) {
    float fl = float(l);
    float cell = (26.0 + 14.0 * fl + 12.0 * fl * fl) * u_unit;
    float radius = (1.6 + 1.2 * fl + 1.1 * fl * fl) * u_unit;
    float soft = 0.45 + 0.17 * fl;
    int salt = 300 + 20 * l;
    // Rows repeat every `rows` cells, so the fall of whole repeats per loop has no seam.
    float rows = ceil(u_size.y / cell) + 1.0;
    float fall = floor(3.0 + 2.0 * fl) * rows * cell * u_time / u_loop;
    vec2 q = vec2(px.x, px.y - fall);
    vec2 g = floor(q / cell);
    int c = int(g.x), r = int(mod(g.y, rows));
    if (hash(c, r, salt) > 0.7) return 0.0;
    float sway = 0.18 * cell * sin(turn * floor(2.0 + 4.0 * hash(c, r, salt + 1)) + TAU * hash(c, r, salt + 2));
    vec2 s = (g + vec2(0.3 + 0.4 * hash(c, r, salt + 3), 0.2 + 0.6 * hash(c, r, salt + 4))) * cell + vec2(sway, 0.0);
    float size = radius * (0.6 + 0.6 * hash(c, r, salt + 5));
    float d = length(q - s);
    return smoothstep(size, size * (1.0 - soft) - 0.5 * u_unit, d) * (0.45 + 0.55 * hash(c, r, salt + 6));
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * u_size;
    float turn = TAU * u_time / u_loop;
    vec3 base = u_base.rgb;
    vec3 col = base * mix(mix(0.7, 1.0, uv.y), 1.0, 1.0 - u_glow);
    col = lay(col, mix(u_cyan.rgb, u_ink.rgb, 0.5), 0.05 * smoothstep(0.5, 1.0, uv.y));
    for (int l = 0; l < 4; l++) {
        float fl = float(l);
        vec3 tint = mix(mix(u_cyan.rgb, u_ink.rgb, 0.6), u_ink.rgb, fl / 3.0);
        col = lay(col, tint, flakes(l, px, turn) * (0.5 + 0.1 * fl));
    }
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
