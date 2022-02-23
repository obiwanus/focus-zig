#version 450 core

layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec4 a_color;

layout(location = 0) out vec4 v_color;

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
    gl_Position = screen_to_canonical(a_pos);
    v_color = a_color;
}
