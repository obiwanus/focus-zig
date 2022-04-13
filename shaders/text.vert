#version 450 core

layout(location = 0) in vec2 a_pos;
layout(location = 1) in vec2 a_tex_coord;
layout(location = 2) in uint a_color;

layout(location = 0) out vec2 v_tex_coord;
layout(location = 1) out vec3 v_color;

layout(set = 0, binding = 0) uniform Global {
    vec2 screen_size;
} g;

const vec3[] COLOR_PALETTE = vec3[](
    vec3(0.81, 0.77, 0.66), // default
    vec3(0.52, 0.56, 0.54), // comment
    vec3(0.51, 0.67, 0.64), // type
    vec3(0.67, 0.74, 0.49), // function
    vec3(0.65, 0.69, 0.76), // punctuation
    vec3(0.85, 0.68, 0.33), // string
    vec3(0.84, 0.60, 0.71), // value
    vec3(0.85, 0.61, 0.46), // highlight
    vec3(1.00, 0.00, 0.00), // error
    vec3(0.902, 0.493, 0.457)); // keyword

vec4 screen_to_canonical(vec2 vertex) {
    vec2 canonical = 2.0 * (vertex / g.screen_size) - 1.0;
    return vec4(canonical, 0.0, 1.0);
}

void main() {
    gl_Position = screen_to_canonical(a_pos);
    v_tex_coord = a_tex_coord;
    v_color = COLOR_PALETTE[a_color];
}
