# TODO
- Support backspace
- Record command buffers every frame (should be easier in the long run)
    - Read how it's done in vkguide.dev
- Draw cursor

# DONE
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
