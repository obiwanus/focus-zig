# TODO
- Multiple cursors
- [optimisation] Highlighting syntax:
    - Implement a few languages, not just Zig
    - Measure how expensive it is to rehighlight everything
- [bug] Colors are off when non-ascii bytes are present (tokenizer doesn't support utf-8)
- [ui] When pressing home, jump back only to the indented code
- [ui] When drawing a buffer with a conflict we need to ask what to do
- [tech-debt] When scanning the root folder, ignore the ignored folders right away (modify dir walker)
- [tech-debt] When building a directory tree, see if we can use a memory arena
              (maybe don't use array lists and instead just allocate slices of exact size from the arena)

# WHAT NEEDS TO WORK BEFORE I CAN START USING IT
+ Open files
+ Save files
+ Switch between open files
+ Select text, copy/cut/paste/duplicate
- Create new files
- Search within buffer
- Undo/redo
- No known bugs

# DONE
+ [bug] Cursor is off on the last line
+ Duplicate lines on ctrl+D
+ Select text, copy/cut/paste/duplicate
    + Create a clipboard buffer for cursor
    + On ctrl+C, copy
    + On ctrl+X, cut
    + On ctrl+V, paste
+ [ui] Don't set wanted position to infinity when pressing end
+ Draw a selection
+ Select using cursor
    + If shift+arrow is pressed, start a selection or modify existing
    + If anything else is pressed, remove current selection
    + Fix overflows to the other pane
    + If a buffer is reloaded, remove selection and adjust cursor
+ Fix selection appearance at the end of the file
+ Check for overflows
+ Use binary search to get char pos from buffer pos
+ Display conflict information in the footer
+ Update modified time when saving buffer to disk
+ From time to time refresh open buffers from disk
    + If not modified, just replace the buffer contents
    + If modified, right now just mark as conflict and don't touch the buffer
    + If deleted, mark as deleted and don't touch the buffer
+ Sort filtered files by most relevant
+ Fix auto-indentation
+ [bug] Fix cursor positioning on horizontal scroll
+ [bug] Can't open stb_truetype/build.zig
+ [bug] Make it possible to go to the last line after the last '\n'
+ Close active pane
    + Don't ever have only right active
    + Keep one open editor even when closed
    + Fix the bug with replacing visible editor
+ Have a shortcut for duplicating an editor on the side
+ When editing a buffer, adjust the cursor in the inactive editor accordingly
+ Open 2 editors with the same buffer (if opening side by side)
    + Create text buffers separately from editors
    + When selecting a file for which we already have an open buffer on the side, create another editor for the buffer
    + When opening a file, if an editor for that file is already open in the target pane, just switch to that pane
+ Open files relatively to the currently active buffer
+ Save modified buffer
+ Display info in the footer
    + Fix the shadow and the positioning of the splitter
    + Open buffer file path
    + Line and column
    + Whether a buffer is modified
+ Switch between panes
+ Support 0, 1, 2 editors
+ Fix editing near the end of the buffer (crashes on insert, can't get to last line)
+ Open files in the left editor
+ Add a scrollbar
+ Make the window scroll
+ Fix filtering by uppercase letters
+ Limit the number of chars you can see in the input box
    + Show only the rightmost dirs in the dir list
    + Show only the rightmost chars in the input box
+ Use tab or enter to enter directories
    + Display directories in bubbles
        + Replace current_dir with a dir stack
        + Fix the file tree
        + Display the directory stack
+ Use backspace to go up a directory (remove rightmost bubble)
+ Allow to filter files and directories using fuzzy search
    + Enter text into the input box
    + Use this text for filtering
    + Match the dialog height with the number of entries
    + Draw a cursor
    + Don't move the selected index past the filtered entries
    + Draw a placeholder when no entries are present
    + Support case-insensitive search for English chars
+ Open current directory and show files there
    + Only show files in the current directory
        + Fix the bug with the tree
    + Ignore .git and all in .gitignore
+ Fix the leak when getting files in working dir
+ Print the entry we're trying to open
+ Switch selected entry using the arrow keys
+ Make an open file dialog
    + Show a rect where the dialog would be. Support min/max width and scale.
    + Get a list of files in the current directory
    + Display the list and the search box
+ Make viewport follow cursor with a smooth scrolling
    + Draw text at non-sticky offsets
    + Update scroll_wanted when cursor is outside the viewport
+ Reorganise code to avoid waiting on timeout
+ Make viewport scroll to scroll_wanted over time
    + Don't wait for events when there's animation to do
    + Implement a debug panel and display frame number there
+ Switch editors by ctrl+alt+arrow
+ Only process events we care about
+ Add cursors to editors and implement editing
    + Add an event system
+ Position two editors side by side with some margins
+ Have an editor struct, which will have all the associated data:
    + text buffer
    + main(active) cursor position (we'll determine the viewport as offsets from the cursor based on current rect)
    + top-left corner of the viewport (in pixels)
    + wanted top-left corner of the viewport (calculated based on cursor position)
+ Create a single pipeline and render cursor and text there
    + Use the new pipeline for cursor
    + Remove scissors and margins temporarily
    + Replace the existing text pipeline
    + Fix cursor positioning
+ Fix color blending (outline?)
    + Disable blending, try to "blend" manually in the shader
+ Render text and solid blocks in a single pipeline
    + Modify pipeline layout to support texture sampler
    + Update texture descriptor to use the font atlas
    + Write a draw letter function
+ Render a rectangle of some color
    + Write simple shaders
    + Make a pipeline
    + Setup pipeline vertex input (copy from solid pipeline)
    + Fill in vertex and index buffers
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
