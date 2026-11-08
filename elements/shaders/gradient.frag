#version 440
#extension GL_GOOGLE_include_directive : require
// Gradient flow: a soft mesh of the theme's accent, cyan and green and a
// deeper background, drifting slowly through a gently swaying space and
// kept low in contrast under the lock's text. The pools are blended by
// their share (a mesh gradient), so colour reaches every edge and corner;
// every function is smooth (no lattice noise, no hard roll-off), so there
// are no creases for the eye to read as rings, and the shared dither breaks
// up the 8-bit steps. Every path is periodic in the loop. BackdropStill.js
// paints the same field on the CPU.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
#include "common.glsl"
#include "hash.glsl"

const int POOLS = 5;

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * u_size;
    float aspect = u_size.x / max(u_size.y, 1.0);
    float turn = TAU * u_time / u_loop;
    // A slow sway: sines only, so the space bends without creases.
    vec2 q = uv + 0.03 * vec2(sin(2.3 * uv.y + turn + 0.4), sin(2.9 * uv.x - turn + 1.3))
        + 0.015 * vec2(sin(3.7 * uv.y - 2.0 * turn), sin(4.9 * uv.x + 2.0 * turn + 2.1));
    vec2 p = vec2(q.x * aspect, q.y);

    vec3 base = u_base.rgb;
    vec3 colors[POOLS];
    colors[0] = u_accent.rgb;
    colors[1] = u_cyan.rgb;
    colors[2] = u_green.rgb;
    colors[3] = mix(u_accent.rgb, u_cyan.rgb, 0.5);
    colors[4] = base * mix(1.0, 0.6, u_glow);
    // Four pools wander around the quarters of the screen and a deeper one
    // around its middle, each on a closed path that never leaves a side of
    // the screen without colour; each colours by its share.
    vec3 mesh = vec3(0.0);
    float total = 0.0;
    for (int i = 0; i < POOLS; i++) {
        float fi = float(i);
        vec2 home = i == 4 ? vec2(0.5, 0.5) : vec2(i % 2 == 0 ? 0.22 : 0.78, i < 2 ? 0.3 : 0.72);
        vec2 path = vec2(0.16 * sin(turn * (i == 1 ? 2.0 : 1.0) + fi * 1.7),
                         0.18 * cos(turn * (i == 2 ? 2.0 : 1.0) + fi * 2.3));
        vec2 d = p - vec2((home.x + path.x) * aspect, home.y + path.y);
        // A heavy tail, so every share changes slowly, even far from all
        // the pools (a Gaussian share turns sharp there).
        float e = dot(d, d) + (i == 4 ? 0.16 : 0.06);
        float w = (i == 4 ? 0.5 : 1.0) / (e * e);
        mesh += colors[i] * w;
        total += w;
    }
    mesh /= max(total, 1e-6);
    // Calm: the background with the mesh laid over it, the change in
    // lightness eased toward a ceiling (tanh, smooth through zero), so text
    // stays legible on any theme (a grey accent would otherwise make a
    // bright cloud).
    vec3 col = mix(base, mesh, mix(0.35, 0.6, u_glow));
    const vec3 LUMA = vec3(0.2126, 0.7152, 0.0722);
    const float CEILING = 0.16;
    float baseLight = dot(base, LUMA);
    float light = max(dot(col, LUMA), 1e-4);
    // Scaled, not shifted, so the colours keep their hue and never clip.
    col *= (baseLight + CEILING * tanh((light - baseLight) / CEILING)) / light;
    // A soft vignette, the same on every side.
    vec2 v = uv - 0.5;
    col *= mix(1.0, 1.0 - 0.3 * dot(v, v), u_glow);
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
