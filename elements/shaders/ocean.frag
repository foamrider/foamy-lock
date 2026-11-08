#version 440
#extension GL_GOOGLE_include_directive : require
// Ocean waves: a night sea under a moon. Swells in bands from the horizon
// to the shore, each band's crest a sum of two waves rolling sideways, with
// a pale edge of foam; nearer bands are taller, darker and slower to the
// eye. The moon's path glitters on the crests below it. Every wave travels a
// whole number of wavelengths per loop.
// BackdropStill.js paints the same sea on the CPU.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
#include "common.glsl"
#include "hash.glsl"

const int BANDS = 8;
const float HORIZON = 0.6;
const vec2 MOON = vec2(0.74, 0.2);

// Band i's crest height (0 at the top) at x.
float crest(int i, float x, float turn) {
    float fi = float(i);
    float depth = pow((fi + 1.0) / float(BANDS), 1.5);
    float y = HORIZON + (1.0 - HORIZON) * depth - 0.02;
    float amp = 0.004 + 0.022 * depth;
    float k = 9.0 / (0.35 + depth);
    float w1 = sin(x * k + turn * floor(2.0 + 3.0 * hash(i, 0, 600)) + TAU * hash(i, 0, 601));
    float w2 = sin(x * k * 2.3 - turn * floor(3.0 + 3.0 * hash(i, 0, 602)) + TAU * hash(i, 0, 603));
    return y - amp * (0.65 * w1 + 0.35 * w2);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * u_size;
    float aspect = u_size.x / max(u_size.y, 1.0);
    float x = uv.x * aspect;
    float turn = TAU * u_time / u_loop;
    vec3 base = u_base.rgb;
    vec3 ink = u_ink.rgb;
    vec3 glowTint = mix(u_accent.rgb, u_cyan.rgb, 0.4);

    // The sky: deep at the top, a little light near the horizon.
    vec3 col = base * mix(mix(0.6, 1.0, uv.y / HORIZON), 1.0, 1.0 - u_glow);
    col = lay(col, glowTint, 0.08 * smoothstep(HORIZON - 0.3, HORIZON, uv.y));
    // The moon and its halo.
    vec2 m = vec2(MOON.x * aspect, MOON.y);
    float r = length(vec2(x, uv.y) - m);
    col = lay(col, mix(ink, glowTint, 0.4), 0.1 * exp(-r * 10.0));
    col = lay(col, ink, 0.7 * smoothstep(0.031, 0.027, r));

    if (uv.y > HORIZON - 0.03) {
        // The nearest band whose crest is above this pixel.
        int band = -1;
        float top = 0.0;
        for (int i = 0; i < BANDS; i++) {
            float c = crest(i, x, turn);
            if (uv.y >= c) { band = i; top = c; }
        }
        if (band >= 0) {
            float depth = (float(band) + 1.0) / float(BANDS);
            vec3 water = mix(mix(base, glowTint, 0.3), base * 0.55, depth);
            water = mix(base, water, mix(0.5, 1.0, u_glow));
            float below = (uv.y - top) / (0.02 + 0.05 * depth);
            vec3 c = mix(water, water * 0.8, smoothstep(0.0, 1.0, below));
            col = c;
            // Foam on the crest.
            float foam = exp(-(uv.y - top) * u_size.y / ((1.0 + 2.0 * depth) * u_unit));
            col = lay(col, ink, 0.16 * foam * (0.5 + 0.5 * depth));
            // The moon's path: glints near crests under the moon.
            float spread = 0.03 + 0.18 * (uv.y - HORIZON);
            float path = exp(-pow((x - m.x) / spread, 2.0));
            float glint = exp(-(uv.y - top) * u_size.y / (2.5 * u_unit)) + 0.25 * foam;
            col = lay(col, mix(ink, glowTint, 0.3), 0.5 * path * min(glint, 1.0));
        }
    }
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
