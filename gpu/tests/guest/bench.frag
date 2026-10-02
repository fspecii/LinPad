#version 450
layout(push_constant) uniform PC { float t; uint tris; } pc;
layout(location = 0) in vec3 color;
layout(location = 0) out vec4 outColor;
void main() {
    vec2 p = gl_FragCoord.xy / 300.0;
    float v = 0.0;
    for (int i = 0; i < 16; i++)
        v += sin(p.x * float(i + 1) + pc.t) * cos(p.y * float(i + 2) - pc.t);
    outColor = vec4(color * (0.75 + 0.25 * sin(v)), 1.0);
}
