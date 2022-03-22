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
    vec2 cursor_advance;
} g;

const vec2 PADDING = vec2(0.0, 4.0);

vec4 screen_to_canonical(vec2 vertex) {
    vec2 canonical = 2.0 * (vertex / g.screen_size) - 1.0;
    return vec4(canonical, 0.0, 1.0);
}

void main() {
    // The vertices of the cursor quad are positioned based on the font's letter size
    // with some padding
    const vec2 V1 = vec2(-PADDING.x, -PADDING.y);
    const vec2 V2 = vec2(g.cursor_size.x + PADDING.x, -PADDING.y);
    const vec2 V3 = vec2(g.cursor_size.x + PADDING.x, g.cursor_size.y + PADDING.y);
    const vec2 V4 = vec2(-PADDING.x, g.cursor_size.y + PADDING.y);

    const vec2 VERTICES[] = vec2[](V1, V2, V3, V1, V3, V4);

    vec2 vertex = VERTICES[gl_VertexIndex] + g.panel_topleft + PushConstants.offset * g.cursor_advance;
    gl_Position = screen_to_canonical(vertex);
    v_color = vec4(1.0, 1.0, 0.0, 0.5);
}
