#version 450 core

layout(binding = 0) uniform sampler2D texSampler;

layout(location = 0) in vec2 v_tex_coord;

layout(location = 0) out vec4 f_color;

void main() {
    // f_color = vec4(v_tex_coord, 0.0, 1.0);
    f_color = texture(texSampler, v_tex_coord);
}
