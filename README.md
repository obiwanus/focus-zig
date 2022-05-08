# Focus

A simple text editor (work in progress)

## How to build and run on Windows

- Update your graphics driver
- Install the latest Vulkan SDK https://www.lunarg.com/vulkan-sdk/
- Download Zig 0.9.1 (https://ziglang.org/download/), extract the archive somewhere and add it to your Windows Path
- Clone the repository
- Change into the project directory and run `zig build run -Drelease-safe=true`

## Basic shortcuts

- Ctrl + P - show open file dialog
- When in open file dialog: Ctrl + Enter - open file in another pane
- Ctrl + Alt + left(right) switch panes
- Ctrl + arrow keys - move cursor faster
- Ctrl + Enter - insert new line below
- Ctrl + Shift + Enter - insert new line above
- Ctrl + D - select word
- Ctrl + Shift + D - duplicate selected lines
