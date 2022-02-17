#version 450 core

layout(location = 0) out vec4 v_color;

layout(push_constant) uniform constants
{
    vec2 offset; // in positions
} PushConstants;

layout(binding = 0) uniform Global {
    vec2 screen_size;
    vec2 panel_topleft;
    vec2 cursor_size;
} g;

vec4 screen_to_canonical(vec2 vertex) {
    vec2 canonical = 2.0 * (vertex / g.screen_size) - 1.0;
    return vec4(canonical, 0.0, 1.0);
}

void main() {
    // TODO: don't do triangle fan as it fails on macos
    // Only 4 vertices because we're interpreting it as a triangle fan
    const vec2 VERTICES[] = vec2[](
        vec2(-1.0, 0.0),
        vec2(g.cursor_size.x + 1.0, 0.0),
        vec2(g.cursor_size.x + 1.0, g.cursor_size.y),
        vec2(-1.0, g.cursor_size.y));

    vec2 vertex = VERTICES[gl_VertexIndex] + g.panel_topleft + PushConstants.offset * g.cursor_size;
    gl_Position = screen_to_canonical(vertex);
    v_color = vec4(1.0, 1.0, 0.0, 0.5);
}
