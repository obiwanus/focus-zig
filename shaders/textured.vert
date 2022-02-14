#version 450 core

layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_tex_coord;

layout(location = 0) out vec2 v_tex_coord;

const vec2 SCREEN_SIZE = vec2(2498.0, 1417.0);
const vec2 PANEL_OFFSET = vec2(30.0, 10.0);

void main() {
    vec2 normal_pos = 2.0 * (a_pos + PANEL_OFFSET) / SCREEN_SIZE - 1.0;
    gl_Position = vec4(normal_pos, 0.0, 1.0);
    v_tex_coord = a_tex_coord;
}
