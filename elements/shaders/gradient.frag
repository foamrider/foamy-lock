#version 440
#extension GL_GOOGLE_include_directive : require
// Gradient flow: four soft pools of the theme's accent, cyan and green and
// a deeper background, drifting slowly through a gently warped space, kept
// low in contrast under the lock's text. Every path is periodic in the loop.
// BackdropStill.js paints the same field on the CPU.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
#include "common.glsl"
#include "hash.glsl"

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * u_size;
    float aspect = u_size.x / max(u_size.y, 1.0);
    float turn = TAU * u_time / u_loop;
    vec2 p = vec2(uv.x * aspect, uv.y);
    // A slow warp: noise sampled on a circle, so it returns after a loop.
    vec2 around = 0.8 * vec2(cos(turn), sin(turn));
    p += 0.22 * (vec2(noise2(p * 1.4 + around, 501), noise2(p * 1.4 - around + 7.0, 502)) - 0.5);

    vec3 base = u_base.rgb;
    vec3 deep = base * mix(1.0, 0.55, u_glow);
    vec3 colors[4];
    colors[0] = u_accent.rgb;
    colors[1] = u_cyan.rgb;
    colors[2] = u_green.rgb;
    colors[3] = deep;
    // Calm: the background with the pools laid over it, soft and low.
    vec3 col = base;
    float strength = mix(0.3, 0.4, u_glow);
    for (int i = 0; i < 4; i++) {
        float fi = float(i);
        vec2 home = vec2((0.2 + 0.2 * fi + 0.1 * float(i / 2)) * aspect, i % 2 == 0 ? 0.3 : 0.72);
        vec2 path = vec2(0.32 * aspect * sin(turn * (i == 1 ? 2.0 : 1.0) + fi * 1.7),
                         0.26 * cos(turn * (i == 2 ? 2.0 : 1.0) + fi * 2.3));
        vec2 d = p - home - path;
        float w = exp(-dot(d, d) / (i == 3 ? 0.3 : 0.14));
        col = mix(col, colors[i], w * (i == 3 ? 0.8 : strength));
    }
    // Rolled off toward the background's lightness, so text stays legible on
    // any theme (a grey accent would otherwise make a bright cloud).
    const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
    float lift = dot(col - base, LUMA);
    if (abs(lift) > 0.001) col = mix(base, col, 0.22 * (1.0 - exp(-abs(lift) / 0.22)) / abs(lift));
    // A soft vignette.
    col *= mix(1.0, 1.0 - 0.25 * dot(uv - 0.5, uv - 0.5) * 2.0, u_glow);
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
