#version 440
#extension GL_GOOGLE_include_directive : require
// Rain: slanted streaks at three depths (thin, faint and dense far away;
// longer and brighter near) in the accent, over a sky that deepens upward
// and a faint mist at the bottom. Each column's drops fall a whole number
// of times per loop. BackdropStill.js draws the same streaks on the CPU.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
#include "common.glsl"
#include "hash.glsl"

const float WIND = 0.12; // sideways per pixel of fall

// Layer `l`'s streak light at pixel `px`.
float streaks(int l, vec2 px) {
    float fl = float(l);
    float spacing = (9.0 + 9.0 * fl * fl * 0.5 + 4.0 * fl) * u_unit;
    float len = (46.0 + 50.0 * fl) * u_unit;
    float width = (0.9 + 0.5 * fl) * u_unit;
    // Slanted columns: x measured along the fall.
    float sx = px.x - WIND * px.y;
    float column = floor(sx / spacing);
    int c = int(column);
    float x0 = (column + 0.5 + 0.5 * (hash(c, l, 1) - 0.5)) * spacing;
    float across = abs(sx - x0) * 0.9939; // the slant's cosine
    float period = u_size.y * (0.55 + 0.9 * hash(c, l, 3)) + len;
    float laps = floor(70.0 + 40.0 * fl + 50.0 * hash(c, l, 2));
    // 0 at the drop's head, growing up its tail.
    float k = fract(hash(c, l, 4) + laps * u_time / u_loop - px.y / period) * period / len;
    float along = k < 1.0 ? smoothstep(0.0, 0.08, k) * pow(1.0 - k, 1.4) : 0.0;
    float edge = exp(-across * across / (width * width));
    return along * edge * (0.55 + 0.45 * hash(c, l, 5));
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * u_size;
    vec3 base = u_base.rgb;
    vec3 col = base * mix(mix(0.72, 1.0, uv.y), 1.0, 1.0 - u_glow);
    // Mist low down.
    col = lay(col, mix(u_accent.rgb, base, 0.4), 0.06 * smoothstep(0.55, 1.0, uv.y));
    for (int l = 0; l < 3; l++) {
        float fl = float(l);
        vec3 tint = mix(mix(u_accent.rgb, base, 0.35 - 0.15 * fl), u_ink.rgb, 0.15 + 0.15 * fl);
        col = lay(col, tint, streaks(l, px) * (0.22 + 0.2 * fl));
    }
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
