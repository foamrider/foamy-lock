#version 440
#extension GL_GOOGLE_include_directive : require
// Northern lights: two curtains over a darkened sky with faint stars and a
// low ridge. A curtain is a folded lower edge in the theme's green with rays
// rising from it into its accent (cyan for the far one); it sways, its rays
// shimmer and its bright stretches come and go, all periodic in the loop.
// BackdropStill.js draws the same picture on the CPU.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
#include "common.glsl"
#include "hash.glsl"

// Curtain `i`'s lower edge, rays and brightness at x (all but the height).
vec3 curtain(int i, float x, float aspect, float turn) {
    float fi = float(i);
    float sway = 0.9 * sin(turn + fi * 2.1) + 0.4 * sin(2.0 * turn + fi * 1.3);
    float xn = x / aspect;
    // A long gentle S across the sky (the far one below it), folded.
    float edge = i == 0 ? 0.42 + 0.09 * sin(xn * 4.4 + 0.6 + 0.4 * sway)
                        : 0.55 - 0.06 * sin(xn * 3.1 + 2.0 - 0.4 * sway);
    edge += 0.11 * (noise1(x * 1.3 + fi * 5.3 + sway, 10 + i) - 0.5)
        + 0.035 * (noise1(x * 4.2 - fi * 2.9 - 0.7 * sway, 13 + i) - 0.5)
        + 0.02 * (noise1(x * 11.0 + 1.3 * sway, 16 + i) - 0.5)
        + 0.007 * (noise1(x * 27.0 - 2.1 * sway, 19 + i) - 0.5);
    float shimmer = 1.6 * sin(3.0 * turn + fi) + 0.8 * sin(5.0 * turn + 2.0 * fi);
    float rays = 0.25 + 0.75 * noise1(x * 48.0 + fi * 17.0 + shimmer, 20 + i)
        * (0.6 + 0.4 * noise1(x * 130.0 - fi * 11.0 - 1.7 * shimmer, 23 + i));
    float bloom = 0.3 + 0.7 * smoothstep(0.2, 0.8, noise1(x * 0.9 - fi * 3.7 + 0.8 * sin(2.0 * turn + fi), 30 + i));
    return vec3(edge, rays, bloom * (i == 0 ? 1.0 : 0.7 * smoothstep(0.15, 0.55, xn)));
}

// Its light at height y (0 at the top): bright at the edge, rays above it.
float curtainLight(vec3 c, int i, float y) {
    float d = c.x - y;
    // Rays of different heights, brightest just above the edge.
    float height = (0.035 + 0.085 * c.y) * (i == 0 ? 1.0 : 0.6);
    float rays = d >= 0.0 ? exp(-d / height) * (0.3 + 0.7 * c.y) : 0.0;
    float edge = smoothstep(-0.008, 0.005, d) * (1.0 + 2.0 * exp(-abs(d) * 120.0));
    // A faint glow around the curtain, without rays.
    float haze = 0.1 * exp(-abs(d - 0.06) * 12.0);
    // And a soft fringe below the edge, so it never reads as a horizon.
    float fringe = d < 0.0 ? 0.35 * exp(d * 45.0) : 0.0;
    return (rays * edge + haze + fringe) * (0.05 + 0.95 * c.z);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * u_size;
    float aspect = u_size.x / max(u_size.y, 1.0);
    float x = uv.x * aspect;
    float turn = TAU * u_time / u_loop;
    vec3 base = u_base.rgb;

    // The sky: deeper at the top on a dark theme.
    vec3 col = base * mix(mix(0.6, 1.0, smoothstep(0.0, 1.0, uv.y)), 1.0, 1.0 - u_glow);

    float light = 0.0;
    vec3 tint = vec3(0.0);
    for (int i = 0; i < 2; i++) {
        vec3 c = curtain(i, x, aspect, turn);
        // Where a fold turns, the curtain is seen edge-on and glows brighter.
        float slope = (curtain(i, x + 0.01, aspect, turn).x - c.x) / 0.01;
        float a = curtainLight(c, i, uv.y) * (i == 0 ? 0.95 : 0.6) * (0.75 + 0.5 * min(abs(slope), 1.5));
        vec3 top = i == 0 ? u_accent.rgb : u_cyan.rgb;
        tint += mix(u_green.rgb, top, smoothstep(0.0, 0.12, c.x - uv.y)) * a;
        light += a;
    }

    // Faint stars, fewer where the curtains are.
    float cell = 46.0 * u_unit;
    vec2 g = floor(px / cell);
    int gx = int(g.x), gy = int(g.y);
    vec2 s = (g + 0.1 + 0.8 * vec2(hash(gx, gy, 41), hash(gx, gy, 42))) * cell;
    float twinkle = 0.6 + 0.4 * sin(turn * floor(8.0 + 20.0 * hash(gx, gy, 44)) + TAU * hash(gx, gy, 45));
    float star = step(0.72, hash(gx, gy, 43)) * twinkle * (1.0 - uv.y)
        * exp(-dot(px - s, px - s) / (1.2 * u_unit * u_unit));
    col = lay(col, u_ink.rgb, star * 0.55 / (1.0 + 4.0 * light));
    col = lay(col, tint / max(light, 1e-4), 1.0 - exp(-light * 1.2));

    // A low ridge in the foreground.
    float ridge = 0.885 + 0.045 * (noise1(x * 2.2, 50) - 0.5) + 0.02 * (noise1(x * 7.0, 51) - 0.5);
    float land = smoothstep(ridge - 0.002, ridge + 0.002, uv.y);
    col = mix(col, base * 0.5, land * mix(0.35, 1.0, u_glow));

    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
