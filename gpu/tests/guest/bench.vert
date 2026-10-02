#version 450
layout(push_constant) uniform PC { float t; uint tris; } pc;
layout(location = 0) out vec3 color;
void main() {
    uint tri = gl_VertexIndex / 3u;
    uint corner = gl_VertexIndex % 3u;
    float a = float(tri) * 2.399963 + pc.t * (0.2 + float(tri % 7u) * 0.05);
    float r = 0.95 * sqrt(float(tri) / float(pc.tris));
    vec2 center = vec2(cos(a), sin(a)) * r;
    float s = 0.05;
    float ca = pc.t * 2.0 + float(tri);
    vec2 offs[3] = vec2[](vec2(0.0, -1.0), vec2(0.866, 0.5), vec2(-0.866, 0.5));
    vec2 o = offs[corner];
    vec2 ro = vec2(o.x * cos(ca) - o.y * sin(ca), o.x * sin(ca) + o.y * cos(ca));
    gl_Position = vec4(center + ro * s, 0.0, 1.0);
    color = vec3(0.5 + 0.5 * cos(a), 0.5 + 0.5 * sin(a * 1.3), float(corner) * 0.5);
}
