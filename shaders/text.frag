#version 450 core

layout(set = 1, binding = 0) uniform sampler2D texSampler;

layout(location = 0) in vec2 v_tex_coord;
layout(location = 1) in vec3 v_color;

layout(location = 0) out vec4 f_color;

void main() {
    f_color = vec4(v_color * texture(texSampler, v_tex_coord).a, 1.0);
}
