#version 450 core

layout(set = 1, binding = 0) uniform sampler2D texSampler;

layout(location = 0) in vec2 v_tex_coord;
layout(location = 1) in vec3 v_color;

layout(location = 0) out vec4 f_color;

void main() {
    // vec3 v_color = vec3(0.0, 1.0, 0.0);
    f_color = vec4(v_color, 1.0) * texture(texSampler, v_tex_coord);
}
