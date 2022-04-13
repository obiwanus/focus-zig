#version 460 core

layout(set = 1, binding = 0) uniform sampler2D texSampler;

layout(location = 0) in vec4 v_color;
layout(location = 1) in vec2 v_tex_coord;
layout(location = 2) flat in uint v_vertex_type;

layout(location = 0) out vec4 f_color;

const uint TYPE_SOLID = 0;
const uint TYPE_TEXTURED = 1;

void main() {
    if (v_vertex_type == TYPE_SOLID) {
        f_color = v_color;
    } else if (v_vertex_type == TYPE_TEXTURED) {
        f_color = vec4(vec3(v_color), texture(texSampler, v_tex_coord).a);
    } else {
        // Invalid vertex type
        f_color = vec4(1.0, 0.0, 1.0, 1.0);
    }
}
