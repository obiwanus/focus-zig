# TODO
- Have horizontal margins for viewport
    - Draw viewport from a different x position
- Support UTF-8
- Fix editing near the end of the buffer (can't get cursor close enough)

# DONE
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
