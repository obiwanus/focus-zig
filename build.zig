const std = @import("std");

const glfw = @import("libs/glfw/build.zig");
// const vkgen = @import("libs/vulkan/generator/index.zig");
const vulkanzig = @import("libs/vulkan/build.zig");

pub fn build(b: *std.build.Builder) void {
    const exe = b.addExecutable("focus", "src/main.zig");

    const target = b.standardTargetOptions(.{});
    exe.setTarget(target);

    const release = b.option(bool, "release", "Install a release version to C:\\Programs\\focus") orelse false;

    if (release) {
        if (target.getOsTag() == .windows) {
            exe.subsystem = .Windows;
        }
        exe.setOutputDir("C:\\\\Programs\\focus");
        exe.setBuildMode(.ReleaseSafe);
    } else {
        exe.setBuildMode(b.standardReleaseOptions());
    }

    // stb_image
    exe.addCSourceFile("libs/stb_image/stb_image.c", &.{});
    exe.addPackagePath("stbi", "libs/stb_image/stbi.zig");

    // stb_truetype
    exe.addCSourceFile("libs/stb_truetype/stb_truetype.c", &.{});
    exe.addPackagePath("stbtt", "libs/stb_truetype/stbtt.zig");
    exe.install();

    // glfw
    exe.addPackagePath("glfw", "libs/glfw/src/main.zig");
    glfw.link(b, exe, .{});

    // // NOTE: Removed vk.zig generation because it takes a long time
    // const gen = vkgen.VkGenerateStep.init(b, "libs/vulkan/vk.xml", "vk.zig");
    // exe.addPackage(gen.package);

    // NOTE: instead we just vendor the generated file
    exe.addPackagePath("vulkan", "libs/vulkan/vk.zig");

    // Resources
    const resources = vulkanzig.ResourceGenStep.init(b, "resources.zig");
    resources.addShader("ui_vert", "shaders/ui.vert");
    resources.addShader("ui_frag", "shaders/ui.frag");
    exe.addPackage(resources.package);

    const run_cmd = exe.run();
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| {
        run_cmd.addArgs(args);
    }

    const run_step = b.step("run", "Run the app");
    run_step.dependOn(&run_cmd.step);
}
