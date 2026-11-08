#version 440
#extension GL_GOOGLE_include_directive : require
// The drawn backgrounds' vertex stage: Qt's standard ShaderEffect transform,
// built for the same GLSL targets as the fragment shaders (Qt's own vertex
// shader shares no GLSL ES version with them).
layout(location = 0) in vec4 qt_Vertex;
layout(location = 1) in vec2 qt_MultiTexCoord0;
layout(location = 0) out vec2 qt_TexCoord0;
#include "common.glsl"

void main() {
    qt_TexCoord0 = qt_MultiTexCoord0;
    gl_Position = qt_Matrix * qt_Vertex;
}
