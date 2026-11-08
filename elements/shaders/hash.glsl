// The drawn backgrounds' helpers (see common.glsl).
const float TAU = 6.28318530718;

// Chris Wellons' lowbias32: a 32-bit integer mix.
uint lowbias(uint x) {
    x ^= x >> 16u;
    x *= 0x7feb352du;
    x ^= x >> 15u;
    x *= 0x846ca68bu;
    x ^= x >> 16u;
    return x;
}

// A stable pseudo-random number in [0, 1) for (a, b, salt), exact in float.
float hash(int a, int b, int salt) {
    uint h = lowbias(uint(a) + lowbias(uint(b) + lowbias(uint(salt))));
    return float(h >> 8u) / 16777216.0;
}

// Smooth 1D value noise over the integer lattice of `x` (row `row`), 0..1.
float noise1(float x, int row) {
    float i = floor(x);
    float f = x - i;
    float u = f * f * (3.0 - 2.0 * f);
    return mix(hash(int(i), row, 3), hash(int(i) + 1, row, 3), u);
}

// Smooth 2D value noise, 0..1.
float noise2(vec2 p, int salt) {
    vec2 i = floor(p);
    vec2 f = p - i;
    vec2 u = f * f * (3.0 - 2.0 * f);
    int x = int(i.x), y = int(i.y);
    float a = hash(x, y, salt), b = hash(x + 1, y, salt);
    float c = hash(x, y + 1, salt), d = hash(x + 1, y + 1, salt);
    return mix(mix(a, b, u.x), mix(c, d, u.x), u.y);
}

// Light `c` with coverage `a` over `dst`: it adds on a dark theme (a glow)
// and paints over on a light one.
vec3 lay(vec3 dst, vec3 c, float a) {
    return mix(dst, c, a * (1.0 - u_glow)) + c * (a * u_glow);
}

// A little noise against banding in smooth gradients.
vec3 dither(vec3 c, vec2 px) {
    return c + (hash(int(px.x), int(px.y), 99) - 0.5) / 255.0;
}
