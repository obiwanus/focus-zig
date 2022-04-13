#version 460 core

layout(location = 0) in vec4 a_color;
layout(location = 1) in vec2 a_pos;
layout(location = 2) in vec2 a_tex_coord;
layout(location = 3) in uint a_vertex_type;

layout(location = 0) out vec4 v_color;
layout(location = 1) out vec2 v_tex_coord;
layout(location = 2) out uint v_vertex_type;

layout(set = 0, binding = 0) uniform Global {
    vec2 screen_size;
} g;

vec4 screen_to_canonical(vec2 vertex) {
    vec2 canonical = 2.0 * (vertex / g.screen_size) - 1.0;
    return vec4(canonical, 0.0, 1.0);
}

void main() {
    gl_Position = screen_to_canonical(a_pos);
    v_color = a_color;
    v_tex_coord = a_tex_coord;
    v_vertex_type = a_vertex_type;
}
