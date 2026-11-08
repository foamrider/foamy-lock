#version 440
#extension GL_GOOGLE_include_directive : require
// Fireflies: soft glows in the theme's yellow and green wandering slowly
// over a dark meadow, each pulsing on its own rhythm; a nearer layer of
// larger, blurrier ones. Every path and pulse is periodic in the loop.
// BackdropStill.js draws the same glows on the CPU.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
#include "common.glsl"
#include "hash.glsl"

// Where firefly (c, r) of layer l is, and its pulse (0..1) in z.
vec3 firefly(int l, int c, int r, float cell, float turn) {
    int salt = 400 + 20 * l;
    float a = floor(1.0 + 2.0 * hash(c, r, salt + 1)), b = floor(1.0 + 2.0 * hash(c, r, salt + 2));
    vec2 wander = 0.32 * cell * vec2(sin(turn * a + TAU * hash(c, r, salt + 3)),
                                     sin(turn * b + TAU * hash(c, r, salt + 4)));
    vec2 home = (vec2(float(c), float(r)) + 0.5) * cell;
    float beat = sin(turn * floor(7.0 + 9.0 * hash(c, r, salt + 5)) + TAU * hash(c, r, salt + 6));
    float pulse = pow(0.5 + 0.5 * beat, 2.5);
    float on = hash(c, r, salt) < 0.6 ? 1.0 : 0.0;
    return vec3(home + wander, pulse * on);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * u_size;
    float aspect = u_size.x / max(u_size.y, 1.0);
    float turn = TAU * u_time / u_loop;
    vec3 base = u_base.rgb;
    vec3 col = base * mix(mix(0.66, 0.92, uv.y), 1.0, 1.0 - u_glow);

    // The meadow: two soft dark slopes low down.
    float x = uv.x * aspect;
    float back = 0.8 + 0.05 * (noise1(x * 1.6, 450) - 0.5);
    float front = 0.9 + 0.05 * (noise1(x * 2.4 + 9.0, 451) - 0.5);
    col = mix(col, base * 0.72, smoothstep(back - 0.004, back + 0.004, uv.y) * mix(0.3, 1.0, u_glow));
    col = mix(col, base * 0.5, smoothstep(front - 0.004, front + 0.004, uv.y) * mix(0.3, 1.0, u_glow));

    for (int l = 0; l < 2; l++) {
        float cell = (l == 0 ? 150.0 : 260.0) * u_unit;
        float core = (l == 0 ? 1.6 : 2.6) * u_unit;
        float halo = (l == 0 ? 16.0 : 34.0) * u_unit;
        // A firefly stays within 0.18..0.82 of its cell, so only the four cells
        // around the nearest corner can light this pixel noticeably.
        vec2 g = floor(px / cell - 0.5);
        for (int j = 0; j <= 1; j++) {
            for (int i = 0; i <= 1; i++) {
                int c = int(g.x) + i, r = int(g.y) + j;
                vec3 f = firefly(l, c, r, cell, turn);
                if (f.z <= 0.001) continue;
                float d = length(px - f.xy);
                vec3 tint = mix(u_warm.rgb, u_green.rgb, 0.25 + 0.5 * hash(c, r, 470 + l));
                float glow = (0.75 * exp(-d / halo) + exp(-d * d / (2.0 * core * core))) * f.z;
                col = lay(col, mix(tint, u_ink.rgb, 0.5 * exp(-d / core)), min(glow, 1.0) * (l == 0 ? 0.85 : 0.7));
            }
        }
    }
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
