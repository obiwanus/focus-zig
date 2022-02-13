#version 450 core

layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_tex_coord;

layout(location = 0) out vec2 v_tex_coord;

const float SCREEN_WIDTH = 2498.0;
const float SCREEN_HEIGHT = 1417.0;

void main() {
    vec2 screen = vec2(SCREEN_WIDTH, SCREEN_HEIGHT);
    vec2 normal_pos = (a_pos / screen) * 2.0 - 1.0;
    gl_Position = vec4(normal_pos, 0.0, 1.0);
    v_tex_coord = a_tex_coord;
}
