// Shared by the drawn backgrounds' shaders (elements/Backdrop.qml): the
// uniform block, the same in every stage and every animation (Backdrop sets
// the same properties on each; tests/backdrop.test.cjs checks the block),
// and an integer hash that elements/BackdropStill.js repeats bit for bit, so
// the CPU still frame puts every star, drop and flake where the shader does.
layout(std140, binding = 0) uniform buf {
    mat4 qt_Matrix;
    float qt_Opacity;
    vec2 u_size;    // the item's size in pixels
    float u_time;   // seconds into the loop
    float u_loop;   // the loop in seconds: every motion repeats after it
    float u_unit;   // the view's scale (about 1 at 1080 pixels high)
    float u_glow;   // 1: light adds up (a dark theme); 0: it paints over
    vec4 u_base;    // the theme's background
    vec4 u_accent;  // the theme's accent
    vec4 u_green;   // the theme's green
    vec4 u_cyan;    // the theme's cyan
    vec4 u_ink;     // the lock's foreground
    vec4 u_warm;    // the theme's yellow
};
