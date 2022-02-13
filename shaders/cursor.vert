#version 450 core

layout(location = 0) out vec4 v_color;

const float SCREEN_WIDTH = 2498.0;
const float SCREEN_HEIGHT = 1417.0;

// TODO: set this dynamically based on font size - e.g. when moving to another monitor.
const float CURSOR_WIDTH = 10.0; // in pixels
const float CURSOR_HEIGHT = 25.0;

// Only 4 vertices because we're interpreting it as a triangle fan
const vec2 VERTICES[] = vec2[](
    vec2(0.0, 0.0),
    vec2(CURSOR_WIDTH / SCREEN_WIDTH, 0.0),
    vec2(CURSOR_WIDTH / SCREEN_WIDTH, CURSOR_HEIGHT / SCREEN_HEIGHT),
    vec2(0.0, CURSOR_HEIGHT / SCREEN_HEIGHT));

void main() {
    vec2 vertex = VERTICES[gl_VertexIndex];
    gl_Position = vec4(vertex, 0.0, 1.0);
    v_color = vec4(1.0, 1.0, 0.0, 0.0);
}
