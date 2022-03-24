# TODO
- Make an open file dialog like in VSCode
    + Show and hide the dialog
    - Type something into the quad
    - Then refactor input
- Fix editing near the end of the buffer (can't get cursor close enough)
- Multiple cursors

- [optimisation] Highlighting syntax:
    - Implement a few languages, not just Zig
    - Measure how expensive it is to rehighlight everything
- [bug] Colors are off when non-ascii bytes are present (tokenizer doesn't support utf-8)
- [on-hold]Fix color blending (outline?)
- [on-hold]Only process events we care about

# WHAT NEEDS TO WORK BEFORE I CAN START USING IT
- Open files
- Save files
- Create new files
- Switch between open files
- Undo/redo
- Select text, copy/cut/paste/duplicate
- Search within buffer

# DONE
+ Start on the biggest monitor
+ Highlight types and functions
+ Cursor indentation management
+ Fix colors
+ Properly highlight comments
+ Highlight zig syntax
    + Be able to specify color in the text shader
    + Have a palette in the vertex shader (start with 2 colors)
    + On every edit, highlight the whole code in its entirety
+ Make it not crash with small windows
+ Make it scale when scale changes
+ Draw a rectangle where the dialog would go
    + Create a solid color pipeline
    + Send some vertices to the new pipeline
+ Try to use a single descriptor set for the uniform buffer
+ Support UTF-8
    + Use unicode codepoints instead of u8 everywhere
    + Fetch unicode codepoints based on available ranges in fonts (with a fallback)
        + Pack cyrillic symbols into the atlas
        + Fetch cyrillic quads when needed
+ See if we can easily generate only vertices that actually are seen on the screen
+ Have horizontal margins for viewport
    + Draw viewport from a differet x position
    + Fix viewport when dragging window to another screen
+ Support tab and backspace better
+ Have vertical margins for moving the viewport
+ Blend fonts using the alpha channel
+ Fix line number adjustment on screen resize
+ Fix cursor positioning on both monitors
+ Adjust font's line height
+ Draw cursor independently of screen size
+ Pass screen size in uniforms
+ Render independently of window size
    + Separate font texture image from texture pipeline
    + Somehow get monitor dpi (must not depend on window size)
+ Change font size according to monitor scale
+ Refactor global variables into structs (not sure I like it though)
+ Implement new line with no breaking, above and below
+ Fix page up and down
+ Move viewport if cursor is outside
+ Support home and end
+ Move cursor up and down
+ Draw cursor
    + Repurpose the colored quad pipeline to only do cursors
    + Use push constants to set cursor position
    + Draw cursor at 0,0 in the top left corner
    + Sync the offsets so the 0,0 of the cursor is where the text starts
    + Move the cursor and display it
+ Draw a block
    + Try it with a separate pipeline
    + Specify some coordinates somewhere and draw a quad
+ Fix the crash when typing with cursor not on screen
+ Fix one-line file crash (and zero-line file crash too)
+ Fix swapchain recreation
+ Record command buffers every frame (should be easier in the long run)
    + Read how it's done in vkguide.dev
+ Support backspace
+ Support enter
+ Don't draw the whole file every time
    + Calculate how many lines fit onto one screen
    + When loading file, create a line array
    + Keep a top-level line number
    + Fix text drawing after scrolling
    + Fix text insertion
+ Edit text in the most simple way
    + Create a buffer for editing
    + Type characters at the cursor
    + Draw the updates on the screen
    + Don't worry about drawing the cursor just yet
+ Use at least 2 different allocators for static and temporary storage
+ Scroll the file vertically
+ Load a text file and display it
+ Check the advance of different letters
+ Render a word
    + Display the baked texture exactly where we want on the screen at native size
    + Figure out how to position the vertices and where to get the texture coordinates
+ Render a letter
    + Rasterise some font into an atlas
+ Draw a textured quad
    + Load an image
    + Load pixels into a vulkan image
    + Create the necessary descriptors
+ Render a solid color quad instead of the triangle
- Configure debug logger
- Enable validation layers
- Draw a triangle
- Read the code of zgl
- Understand where zig imports C headers from on Windows
- Open a window
- Create an OpenGL context
