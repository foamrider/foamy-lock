#version 440
#extension GL_GOOGLE_include_directive : require
// Stars: three depths of twinkling stars (a few warm or cool, the brightest
// with faint spikes) and a faint Milky Way across the sky, denser in small
// stars, with a shooting star now and then (three per loop). The typed
// characters' figure is drawn over it by Backdrop.qml. BackdropStill.js
// draws the same sky on the CPU.
layout(location = 0) in vec2 qt_TexCoord0;
layout(location = 0) out vec4 fragColor;
#include "common.glsl"
#include "hash.glsl"

// The Milky Way's strength at uv (0..1): a soft diagonal band, clumped.
float galaxy(vec2 uv, float aspect) {
    vec2 p = vec2(uv.x * aspect, uv.y);
    float d = (p.y - 0.92 + 0.7 * p.x / aspect) / 0.17;
    float band = exp(-d * d);
    float clumps = 0.55 * noise2(p * 3.0, 61) + 0.3 * noise2(p * 7.0, 62) + 0.15 * noise2(p * 15.0, 63);
    return band * smoothstep(0.25, 0.85, clumps);
}

// Layer `l`'s star light at px, its tint in `tint`.
float starLayer(int l, vec2 px, float turn, float milky, out vec3 tint) {
    float fl = float(l);
    float cell = (24.0 + 26.0 * fl * fl) * u_unit;
    vec2 g = floor(px / cell);
    int gx = int(g.x), gy = int(g.y), salt = 70 + 10 * l;
    float chance = l == 0 ? 0.3 + 0.55 * milky : 0.55;
    tint = u_ink.rgb;
    if (hash(gx, gy, salt) > chance) return 0.0;
    vec2 s = (g + 0.15 + 0.7 * vec2(hash(gx, gy, salt + 1), hash(gx, gy, salt + 2))) * cell;
    float bright = pow(hash(gx, gy, salt + 3), 2.2 - 0.6 * fl);
    float size = (0.55 + 0.35 * fl + 0.9 * bright * fl) * u_unit;
    float speed = floor(12.0 + 50.0 * hash(gx, gy, salt + 4));
    float twinkle = 0.55 + 0.45 * sin(turn * speed + TAU * hash(gx, gy, salt + 5));
    vec2 d = px - s;
    float r2 = dot(d, d);
    float light = exp(-r2 / (2.0 * size * size)) + 0.12 * bright * exp(-sqrt(r2) / (3.0 * size));
    // The brightest near stars: faint spikes.
    if (l == 2 && bright > 0.55) {
        vec2 a = abs(d) / u_unit;
        light += 0.5 * bright * (exp(-a.x * 0.9) * exp(-a.y * 0.12) + exp(-a.y * 0.9) * exp(-a.x * 0.12));
    }
    float hue = hash(gx, gy, salt + 6);
    tint = hue < 0.12 ? mix(u_ink.rgb, u_warm.rgb, 0.55) : hue > 0.9 ? mix(u_ink.rgb, u_cyan.rgb, 0.5) : u_ink.rgb;
    return light * (0.25 + 0.75 * bright) * mix(1.0, twinkle, 0.4 + 0.4 * bright);
}

void main() {
    vec2 uv = qt_TexCoord0;
    vec2 px = uv * u_size;
    float aspect = u_size.x / max(u_size.y, 1.0);
    float turn = TAU * u_time / u_loop;
    vec3 base = u_base.rgb;
    vec3 col = base * mix(mix(0.62, 0.95, uv.y), 1.0, 1.0 - u_glow);

    float milky = galaxy(uv, aspect);
    col = lay(col, mix(u_accent.rgb, u_cyan.rgb, 0.35 + 0.3 * noise2(uv * 4.0, 64)), 0.1 * milky);

    for (int l = 0; l < 3; l++) {
        vec3 tint;
        float light = starLayer(l, px, turn, milky, tint);
        col = lay(col, tint, min(light, 1.0) * (0.45 + 0.25 * float(l)));
    }

    // A shooting star now and then: three per loop, 1.1 s each.
    for (int k = 0; k < 3; k++) {
        float start = u_loop * (float(k) + 0.15 + 0.6 * hash(k, 0, 90)) / 3.0;
        float p = (u_time - start) / 1.1;
        if (p < 0.0 || p > 1.0) continue;
        vec2 from = vec2(0.15 + 0.7 * hash(k, 0, 91), 0.06 + 0.3 * hash(k, 0, 92)) * u_size;
        vec2 dir = normalize(vec2(hash(k, 0, 93) < 0.5 ? -1.0 : 1.0, 0.45));
        float reach = 0.28 * u_size.x;
        vec2 head = from + dir * reach * p;
        float tail = 0.35 * reach;
        vec2 d = px - head;
        float t = clamp(-dot(d, dir), 0.0, tail);
        float off = length(d + dir * t);
        float fade = sin(p * 3.14159265);
        float light = exp(-off * off / (u_unit * u_unit * 1.2)) * (1.0 - t / tail) * fade;
        col = lay(col, u_ink.rgb, 0.8 * light);
    }
    fragColor = vec4(dither(col, px), 1.0) * qt_Opacity;
}
