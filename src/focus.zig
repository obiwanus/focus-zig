/// This is where we import shared stuff for easier access in modules

// Zig
pub const std = @import("std");
pub const builtin = @import("builtin");

// Our stuff
pub const utils = @import("utils.zig");
pub const style = @import("style.zig");
pub const fonts = @import("fonts.zig");
pub const ui = @import("ui.zig");

pub const Buffer = @import("Buffer.zig");
pub const Editors = @import("Editors.zig");

pub const vulkan = struct {
    pub const utils = @import("vulkan/utils.zig");
    pub const pipeline = @import("vulkan/pipeline.zig");
    pub const swapchain = @import("vulkan/swapchain.zig");
    pub const context = @import("vulkan/context.zig");
};

pub const dialogs = struct {
    pub const OpenFile = @import("dialogs/OpenFile.zig");
};
