const std = @import("std");
const vk = @import("vulkan");
const glfw = @import("glfw");

const Allocator = std.mem.Allocator;

const REQUIRED_DEVICE_EXTENSIONS = [_][]const u8{
    vk.extension_info.khr_swapchain.name,
};
const REQUIRED_INSTANCE_EXTENSIONS = [_][*:0]const u8{
    vk.extension_info.ext_debug_utils.name,
};

pub const VulkanContext = struct {
    vkb: BaseDispatch,
    vki: InstanceDispatch,
    vkd: DeviceDispatch,

    instance: vk.Instance,
    surface: vk.SurfaceKHR,
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    mem_props: vk.PhysicalDeviceMemoryProperties,
    debug_messenger: vk.DebugUtilsMessengerEXT,

    dev: vk.Device,
    graphics_queue: Queue,
    present_queue: Queue,

    pub fn init(allocator: Allocator, app_name: [*:0]const u8, window: glfw.Window) !VulkanContext {
        var self: VulkanContext = undefined;

        const glfwInstanceProcLoader = @ptrCast(FnVulkanLoader, glfw.getInstanceProcAddress);
        self.vkb = try BaseDispatch.load(glfwInstanceProcLoader);

        const glfw_exts = try glfw.getRequiredInstanceExtensions();
        const enabled_exts = x: {
            const total_len = glfw_exts.len + REQUIRED_INSTANCE_EXTENSIONS.len;
            const exts = try allocator.alloc([*:0]const u8, total_len);
            errdefer allocator.free(exts);
            std.mem.copy([*:0]const u8, exts, glfw_exts);
            std.mem.copy([*:0]const u8, exts[glfw_exts.len..], &REQUIRED_INSTANCE_EXTENSIONS);
            break :x exts;
        };

        const app_info = vk.ApplicationInfo{
            .p_application_name = app_name,
            .application_version = vk.makeApiVersion(0, 0, 0, 0),
            .p_engine_name = app_name,
            .engine_version = vk.makeApiVersion(0, 0, 0, 0),
            .api_version = vk.API_VERSION_1_2,
        };
        const enabled_layers = [_][*:0]const u8{
            "VK_LAYER_KHRONOS_validation",
        };
        self.instance = try self.vkb.createInstance(&.{
            .flags = .{},
            .p_application_info = &app_info,
            .enabled_layer_count = enabled_layers.len,
            .pp_enabled_layer_names = &enabled_layers,
            .enabled_extension_count = @intCast(u32, enabled_exts.len),
            .pp_enabled_extension_names = enabled_exts.ptr,
        }, null);

        self.vki = try InstanceDispatch.load(self.instance, glfwInstanceProcLoader);
        errdefer self.vki.destroyInstance(self.instance, null);

        self.debug_messenger = try self.vki.createDebugUtilsMessengerEXT(self.instance, &.{
            .flags = .{},
            .message_severity = .{ .info_bit_ext = false, .warning_bit_ext = true, .error_bit_ext = true },
            .message_type = .{ .general_bit_ext = true, .validation_bit_ext = true, .performance_bit_ext = true },
            .pfn_user_callback = vulkanDebugCallback,
            .p_user_data = null,
        }, null);

        self.surface = try createSurface(self.instance, window);
        errdefer self.vki.destroySurfaceKHR(self.instance, self.surface, null);

        const candidate = try pickPhysicalDevice(self.vki, self.instance, allocator, self.surface);
        self.pdev = candidate.pdev;
        self.props = candidate.props;
        self.dev = try createLogicalDevice(self.vki, candidate, &REQUIRED_DEVICE_EXTENSIONS);
        self.vkd = try DeviceDispatch.load(self.dev, self.vki.dispatch.vkGetDeviceProcAddr);
        errdefer self.vkd.destroyDevice(self.dev, null);

        self.graphics_queue = Queue.init(self.vkd, self.dev, candidate.queue_families.graphics);
        self.present_queue = Queue.init(self.vkd, self.dev, candidate.queue_families.present);

        self.mem_props = self.vki.getPhysicalDeviceMemoryProperties(self.pdev);

        return self;
    }

    pub fn deinit(self: VulkanContext) void {
        self.vki.destroyDebugUtilsMessengerEXT(self.instance, self.debug_messenger, null);
        self.vkd.destroyDevice(self.dev, null);
        self.vki.destroySurfaceKHR(self.instance, self.surface, null);
        self.vki.destroyInstance(self.instance, null);
    }

    pub fn deviceName(self: VulkanContext) []const u8 {
        return cStrToSlice(&self.props.device_name);
    }

    pub fn findMemoryTypeIndex(self: VulkanContext, memory_type_bits: u32, flags: vk.MemoryPropertyFlags) !u32 {
        for (self.mem_props.memory_types[0..self.mem_props.memory_type_count]) |mem_type, i| {
            if (memory_type_bits & (@as(u32, 1) << @truncate(u5, i)) != 0 and mem_type.property_flags.contains(flags)) {
                return @truncate(u32, i);
            }
        }

        return error.NoSuitableMemoryType;
    }

    pub fn allocate(self: VulkanContext, requirements: vk.MemoryRequirements, flags: vk.MemoryPropertyFlags) !vk.DeviceMemory {
        return try self.vkd.allocateMemory(self.dev, &.{
            .allocation_size = requirements.size,
            .memory_type_index = try self.findMemoryTypeIndex(requirements.memory_type_bits, flags),
        }, null);
    }
};

const Queue = struct {
    handle: vk.Queue,
    family: u32,

    fn init(vkd: DeviceDispatch, dev: vk.Device, family: u32) Queue {
        return .{
            .handle = vkd.getDeviceQueue(dev, family, 0),
            .family = family,
        };
    }
};

const BaseDispatch = vk.BaseWrapper(.{
    .createInstance = true,
});

const InstanceDispatch = vk.InstanceWrapper(.{
    .destroyInstance = true,
    .createDevice = true,
    .destroySurfaceKHR = true,
    .enumeratePhysicalDevices = true,
    .getPhysicalDeviceProperties = true,
    .enumerateDeviceExtensionProperties = true,
    .getPhysicalDeviceSurfaceFormatsKHR = true,
    .getPhysicalDeviceSurfacePresentModesKHR = true,
    .getPhysicalDeviceSurfaceCapabilitiesKHR = true,
    .getPhysicalDeviceQueueFamilyProperties = true,
    .getPhysicalDeviceSurfaceSupportKHR = true,
    .getPhysicalDeviceMemoryProperties = true,
    .getDeviceProcAddr = true,
    .createDebugUtilsMessengerEXT = true,
    .destroyDebugUtilsMessengerEXT = true,
});

const DeviceDispatch = vk.DeviceWrapper(.{
    .destroyDevice = true,
    .getDeviceQueue = true,
    .createSemaphore = true,
    .createFence = true,
    .createImageView = true,
    .destroyImageView = true,
    .destroySemaphore = true,
    .destroyFence = true,
    .getSwapchainImagesKHR = true,
    .createSwapchainKHR = true,
    .destroySwapchainKHR = true,
    .acquireNextImageKHR = true,
    .deviceWaitIdle = true,
    .waitForFences = true,
    .resetFences = true,
    .queueSubmit = true,
    .queuePresentKHR = true,
    .createCommandPool = true,
    .destroyCommandPool = true,
    .allocateCommandBuffers = true,
    .freeCommandBuffers = true,
    .queueWaitIdle = true,
    .createShaderModule = true,
    .destroyShaderModule = true,
    .createPipelineLayout = true,
    .destroyPipelineLayout = true,
    .createRenderPass = true,
    .destroyRenderPass = true,
    .createGraphicsPipelines = true,
    .destroyPipeline = true,
    .createFramebuffer = true,
    .destroyFramebuffer = true,
    .beginCommandBuffer = true,
    .endCommandBuffer = true,
    .allocateMemory = true,
    .freeMemory = true,
    .createBuffer = true,
    .destroyBuffer = true,
    .getBufferMemoryRequirements = true,
    .mapMemory = true,
    .unmapMemory = true,
    .bindBufferMemory = true,
    .cmdBeginRenderPass = true,
    .cmdEndRenderPass = true,
    .cmdBindPipeline = true,
    .cmdDraw = true,
    .cmdSetViewport = true,
    .cmdSetScissor = true,
    .cmdBindVertexBuffers = true,
    .cmdCopyBuffer = true,
});

const DeviceCandidate = struct {
    pdev: vk.PhysicalDevice,
    props: vk.PhysicalDeviceProperties,
    queue_families: QueueFamilies,
};

const QueueFamilies = struct {
    graphics: u32,
    present: u32,
};

const FnVulkanLoader = fn (instance: vk.Instance, procname: [*:0]const u8) callconv(.C) vk.PfnVoidFunction;

fn createSurface(instance: vk.Instance, window: glfw.Window) !vk.SurfaceKHR {
    var surface: vk.SurfaceKHR = undefined;
    const glfw_result = try glfw.createWindowSurface(instance, window, null, &surface);
    if (glfw_result != @enumToInt(vk.Result.success)) {
        return error.SurfaceInitFailed;
    }
    return surface;
}

fn pickPhysicalDevice(
    vki: InstanceDispatch,
    instance: vk.Instance,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !DeviceCandidate {
    var device_count: u32 = undefined;
    _ = try vki.enumeratePhysicalDevices(instance, &device_count, null);

    const pdevs = try allocator.alloc(vk.PhysicalDevice, device_count);
    defer allocator.free(pdevs);

    _ = try vki.enumeratePhysicalDevices(instance, &device_count, pdevs.ptr);

    for (pdevs) |pdev| {
        if (try checkSuitable(vki, pdev, allocator, surface)) |candidate| {
            return candidate;
        }
    }

    return error.NoSuitableDevice;
}

fn checkSuitable(
    vki: InstanceDispatch,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    surface: vk.SurfaceKHR,
) !?DeviceCandidate {
    const props = vki.getPhysicalDeviceProperties(pdev);

    if (!try checkExtensionSupport(vki, pdev, allocator, REQUIRED_DEVICE_EXTENSIONS[0..])) {
        return null;
    }

    if (!try checkSurfaceSupport(vki, pdev, surface)) {
        return null;
    }

    if (try allocateQueues(vki, pdev, allocator, surface)) |allocation| {
        return DeviceCandidate{
            .pdev = pdev,
            .props = props,
            .queue_families = allocation,
        };
    }

    return null;
}

fn checkExtensionSupport(
    vki: InstanceDispatch,
    pdev: vk.PhysicalDevice,
    allocator: Allocator,
    extensions: []const []const u8,
) !bool {
    var count: u32 = undefined;
    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, null);

    const all_properties = try allocator.alloc(vk.ExtensionProperties, count);
    defer allocator.free(all_properties);

    _ = try vki.enumerateDeviceExtensionProperties(pdev, null, &count, all_properties.ptr);

    for (extensions) |ext| {
        for (all_properties) |props| {
            if (std.mem.eql(u8, ext, cStrToSlice(&props.extension_name))) {
                break;
            }
        } else {
            return false;
        }
    }

    return true;
}

fn checkSurfaceSupport(vki: InstanceDispatch, pdev: vk.PhysicalDevice, surface: vk.SurfaceKHR) !bool {
    var format_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfaceFormatsKHR(pdev, surface, &format_count, null);

    var present_mode_count: u32 = undefined;
    _ = try vki.getPhysicalDeviceSurfacePresentModesKHR(pdev, surface, &present_mode_count, null);

    return format_count > 0 and present_mode_count > 0;
}

fn cStrToSlice(string: []const u8) []const u8 {
    const len = std.mem.indexOfScalar(u8, string, 0).?;
    return string[0..len];
}

fn allocateQueues(vki: InstanceDispatch, pdev: vk.PhysicalDevice, allocator: Allocator, surface: vk.SurfaceKHR) !?QueueFamilies {
    var family_count: u32 = undefined;
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, null);

    const families = try allocator.alloc(vk.QueueFamilyProperties, family_count);
    defer allocator.free(families);
    vki.getPhysicalDeviceQueueFamilyProperties(pdev, &family_count, families.ptr);

    var graphics_family: ?u32 = null;
    var present_family: ?u32 = null;

    for (families) |properties, i| {
        const family = @intCast(u32, i);

        if (graphics_family == null and properties.queue_flags.graphics_bit) {
            graphics_family = family;
        }

        if (present_family == null and (try vki.getPhysicalDeviceSurfaceSupportKHR(pdev, family, surface)) == vk.TRUE) {
            present_family = family;
        }
    }

    if (graphics_family != null and present_family != null) {
        return QueueFamilies{
            .graphics = graphics_family.?,
            .present = present_family.?,
        };
    }

    return null;
}

fn createLogicalDevice(vki: InstanceDispatch, candidate: DeviceCandidate, extensions: []const []const u8) !vk.Device {
    const priority = [_]f32{1};
    const qci = [_]vk.DeviceQueueCreateInfo{
        .{
            .flags = .{},
            .queue_family_index = candidate.queue_families.graphics,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
        .{
            .flags = .{},
            .queue_family_index = candidate.queue_families.present,
            .queue_count = 1,
            .p_queue_priorities = &priority,
        },
    };

    const queue_count: u32 = if (candidate.queue_families.graphics == candidate.queue_families.present)
        1
    else
        2;

    return vki.createDevice(candidate.pdev, &.{
        .flags = .{},
        .queue_create_info_count = queue_count,
        .p_queue_create_infos = &qci,
        .enabled_layer_count = 0,
        .pp_enabled_layer_names = undefined,
        .enabled_extension_count = @truncate(u32, extensions.len),
        .pp_enabled_extension_names = @ptrCast([*]const [*:0]const u8, &extensions),
        .p_enabled_features = null,
    }, null);
}

fn vulkanDebugCallback(
    message_severity: vk.DebugUtilsMessageSeverityFlagsEXT.IntType,
    message_types: vk.DebugUtilsMessageTypeFlagsEXT.IntType,
    p_callback_data: ?*const vk.DebugUtilsMessengerCallbackDataEXT,
    p_user_data: ?*anyopaque,
) callconv(vk.vulkan_call_conv) vk.Bool32 {
    const severity_flags = vk.DebugUtilsMessageSeverityFlagsEXT.fromInt(message_severity);
    const severity_msg = if (severity_flags.error_bit_ext)
        "ERROR"
    else if (severity_flags.warning_bit_ext)
        "WARNING"
    else if (severity_flags.info_bit_ext)
        "INFO"
    else
        "";

    const type_flags = vk.DebugUtilsMessageTypeFlagsEXT.fromInt(message_types);
    const type_msg = if (type_flags.general_bit_ext)
        "general"
    else if (type_flags.validation_bit_ext)
        "validation"
    else if (type_flags.performance_bit_ext)
        "performance"
    else
        "unknown msg type";

    const message = if (p_callback_data) |data|
        data.p_message
    else
        "unknown message";

    std.debug.print("{s}({s}): {s}\n", .{ severity_msg, type_msg, message });

    _ = p_user_data;

    return vk.FALSE;
}
