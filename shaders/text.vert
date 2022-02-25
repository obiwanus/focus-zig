#version 450 core

layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_tex_coord;
// layout(location = 2) in vec3 a_color;

layout(location = 0) out vec2 v_tex_coord;
// layout(location = 1) out vec3 v_color;

layout(set = 0, binding = 0) uniform Global {
    vec2 screen_size;
    vec2 panel_topleft;
    vec2 cursor_size;
} g;

vec4 screen_to_canonical(vec2 vertex) {
    vec2 canonical = 2.0 * (vertex / g.screen_size) - 1.0;
    return vec4(canonical, 0.0, 1.0);
}

void main() {
    vec2 vertex = a_pos + g.panel_topleft;
    gl_Position = screen_to_canonical(vertex);
    v_tex_coord = a_tex_coord;
    // v_color = a_color;
}
