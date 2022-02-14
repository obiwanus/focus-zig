#version 450 core

layout(location = 0) out vec4 v_color;

layout(push_constant) uniform constants
{
    vec2 offset; // in pixels
} PushConstants;

const vec2 SCREEN_SIZE = vec2(2498.0, 1417.0);
const vec2 PANEL_OFFSET = vec2(30.0, 10.0);

// TODO: set this dynamically based on font size - e.g. when moving to another monitor.
const vec2 CURSOR_DIMS = vec2(10.0, 23.0); // in pixels
const float XADVANCE = 8.796875;  // TODO: obvious hardcode

// Only 4 vertices because we're interpreting it as a triangle fan
const vec2 VERTICES[] = vec2[](
    vec2(0.0, 0.0),
    vec2(CURSOR_DIMS.x, 0.0),
    CURSOR_DIMS,
    vec2(0.0, CURSOR_DIMS.y));

void main() {
    vec2 vertex = VERTICES[gl_VertexIndex];
    vertex += PANEL_OFFSET + PushConstants.offset * vec2(XADVANCE, CURSOR_DIMS.y);  // move to the right position
    vertex = 2.0 * vertex / SCREEN_SIZE - vec2(1.0);  // unit cube coordinates

    gl_Position = vec4(vertex, 0.0, 1.0);
    v_color = vec4(1.0, 1.0, 0.0, 0.5);
}
