const std = @import("std");

const Allocator = std.mem.Allocator;

pub const Buf = extern struct {
    data: [*c]u8,
    cursor: c_int,
    size: c_int,
};

pub const BakedChar = extern struct {
    x0: c_ushort,
    y0: c_ushort,
    x1: c_ushort,
    y1: c_ushort,
    xoff: f32,
    yoff: f32,
    xadvance: f32,
};
extern fn stbtt_BakeFontBitmap(data: [*c]const u8, offset: c_int, pixel_height: f32, pixels: [*c]u8, pw: c_int, ph: c_int, first_char: c_int, num_chars: c_int, chardata: [*c]BakedChar) c_int;
pub const bakeFontBitmap = stbtt_BakeFontBitmap;

pub const AlignedQuad = extern struct {
    x0: f32,
    y0: f32,
    s0: f32,
    t0: f32,
    x1: f32,
    y1: f32,
    s1: f32,
    t1: f32,
};
extern fn stbtt_GetBakedQuad(chardata: [*c]const BakedChar, pw: c_int, ph: c_int, char_index: c_int, xpos: [*c]f32, ypos: [*c]f32, q: [*c]AlignedQuad, opengl_fillrule: c_int) void;
pub const getBakedQuad = stbtt_GetBakedQuad;
extern fn stbtt_GetScaledFontVMetrics(fontdata: [*c]const u8, index: c_int, size: f32, ascent: [*c]f32, descent: [*c]f32, lineGap: [*c]f32) void;
pub const getScaledFontVMetrics = stbtt_GetScaledFontVMetrics;

pub const PackedChar = extern struct {
    x0: c_ushort,
    y0: c_ushort,
    x1: c_ushort,
    y1: c_ushort,
    xoff: f32,
    yoff: f32,
    xadvance: f32,
    xoff2: f32,
    yoff2: f32,
};
pub const PackContext = extern struct {
    user_allocator_context: ?*anyopaque,
    pack_info: ?*anyopaque,
    width: c_int,
    height: c_int,
    stride_in_bytes: c_int,
    padding: c_int,
    skip_missing: c_int,
    h_oversample: c_uint,
    v_oversample: c_uint,
    pixels: [*c]u8,
    nodes: ?*anyopaque,
};

pub const FontInfo = extern struct {
    userdata: ?*anyopaque,
    data: [*c]u8,
    fontstart: c_int,
    numGlyphs: c_int,
    loca: c_int,
    head: c_int,
    glyf: c_int,
    hhea: c_int,
    hmtx: c_int,
    kern: c_int,
    gpos: c_int,
    svg: c_int,
    index_map: c_int,
    indexToLocFormat: c_int,
    cff: Buf,
    charstrings: Buf,
    gsubrs: Buf,
    subrs: Buf,
    fontdicts: Buf,
    fdselect: Buf,
};
pub const Rect = opaque {};
extern fn stbtt_PackBegin(spc: [*c]PackContext, pixels: [*c]u8, width: c_int, height: c_int, stride_in_bytes: c_int, padding: c_int, alloc_context: ?*anyopaque) c_int;

pub fn packBegin(pixels: []u8, width: usize, height: usize, stride_in_bytes: usize, padding: usize, alloc_context: ?*anyopaque) !PackContext {
    var pack_context: PackContext = undefined;
    const result = stbtt_PackBegin(
        &pack_context,
        pixels.ptr,
        @intCast(c_int, width),
        @intCast(c_int, height),
        @intCast(c_int, stride_in_bytes),
        @intCast(c_int, padding),
        alloc_context,
    );
    if (result == 0) {
        return error.PackBeginError;
    }
    return pack_context;
}

extern fn stbtt_PackEnd(spc: [*c]PackContext) void;
pub const packEnd = stbtt_PackEnd;
extern fn stbtt_PackFontRange(spc: [*c]PackContext, fontdata: [*c]const u8, font_index: c_int, font_size: f32, first_unicode_char_in_range: c_int, num_chars_in_range: c_int, chardata_for_range: [*c]PackedChar) c_int;

pub fn packFontRange(spc: [*c]PackContext, font_data: []const u8, font_size: f32, first_char: usize, num_chars: usize, allocator: Allocator) ![]PackedChar {
    var packed_chars = try allocator.alloc(PackedChar, num_chars);
    const result = stbtt_PackFontRange(
        spc,
        font_data.ptr,
        0,
        font_size,
        @intCast(c_int, first_char),
        @intCast(c_int, num_chars),
        packed_chars.ptr,
    );
    if (result == 0) {
        return error.PackFontRangeError;
    }
    return packed_chars;
}

pub const PackRange = extern struct {
    font_size: f32,
    first_unicode_codepoint_in_range: c_int,
    array_of_unicode_codepoints: [*c]c_int,
    num_chars: c_int,
    chardata_for_range: [*c]PackedChar,
    h_oversample: u8,
    v_oversample: u8,
};
extern fn stbtt_PackFontRanges(spc: [*c]PackContext, fontdata: [*c]const u8, font_index: c_int, ranges: [*c]PackRange, num_ranges: c_int) c_int;
pub const packFontRanges = stbtt_PackFontRanges;
extern fn stbtt_PackSetOversampling(spc: [*c]PackContext, h_oversample: c_uint, v_oversample: c_uint) void;
pub const packSetOversampling = stbtt_PackSetOversampling;
extern fn stbtt_PackSetSkipMissingCodepoints(spc: [*c]PackContext, skip: c_int) void;
pub const packSetSkipMissingCodepoints = stbtt_PackSetSkipMissingCodepoints;
extern fn stbtt_GetPackedQuad(chardata: [*c]const PackedChar, pw: c_int, ph: c_int, char_index: c_int, xpos: [*c]f32, ypos: [*c]f32, q: [*c]AlignedQuad, align_to_integer: c_int) void;

pub fn getPackedQuad(chardata: [*c]const PackedChar, pw: c_int, ph: c_int, char_index: c_int, x: f32, y: f32, align_to_integer: bool) AlignedQuad {
    var quad: AlignedQuad = undefined;
    var xpos: f32 = x; // to avoid complaints about constness
    var ypos: f32 = y;
    stbtt_GetPackedQuad(chardata, pw, ph, char_index, &xpos, &ypos, &quad, if (align_to_integer) 1 else 0);
    return quad;
}

extern fn stbtt_PackFontRangesGatherRects(spc: [*c]PackContext, info: [*c]const FontInfo, ranges: [*c]PackRange, num_ranges: c_int, rects: ?*Rect) c_int;
pub const packFontRangesGatherRects = stbtt_PackFontRangesGatherRects;
extern fn stbtt_PackFontRangesPackRects(spc: [*c]PackContext, rects: ?*Rect, num_rects: c_int) void;
pub const packFontRangesPackRects = stbtt_PackFontRangesPackRects;
extern fn stbtt_PackFontRangesRenderIntoRects(spc: [*c]PackContext, info: [*c]const FontInfo, ranges: [*c]PackRange, num_ranges: c_int, rects: ?*Rect) c_int;
pub const packFontRangesRenderIntoRects = stbtt_PackFontRangesRenderIntoRects;
extern fn stbtt_GetNumberOfFonts(data: [*c]const u8) c_int;
pub const getNumberOfFonts = stbtt_GetNumberOfFonts;
extern fn stbtt_GetFontOffsetForIndex(data: [*c]const u8, index: c_int) c_int;
pub const getFontOffsetForIndex = stbtt_GetFontOffsetForIndex;

extern fn stbtt_InitFont(info: [*c]FontInfo, data: [*c]const u8, offset: c_int) c_int;

pub fn initFont(data: []const u8) !FontInfo {
    // NOTE: always using offset 0 because we don't use TTF collections
    var font_info: FontInfo = undefined;
    const result = stbtt_InitFont(&font_info, data.ptr, 0);
    if (result == 0) {
        return error.InitFontError;
    }
    return font_info;
}

extern fn stbtt_GetFontVMetrics(info: [*c]const FontInfo, ascent: [*c]c_int, descent: [*c]c_int, lineGap: [*c]c_int) void;

pub const FontVMetrics = struct {
    ascent: f32,
    descent: f32,
    line_gap: f32,
};

pub fn getFontVMetrics(info: FontInfo) FontVMetrics {
    var ascent: c_int = undefined;
    var descent: c_int = undefined;
    var line_gap: c_int = undefined;

    stbtt_GetFontVMetrics(&info, &ascent, &descent, &line_gap);

    return FontVMetrics{
        .ascent = @intToFloat(f32, ascent),
        .descent = @intToFloat(f32, descent),
        .line_gap = @intToFloat(f32, line_gap),
    };
}

extern fn stbtt_ScaleForPixelHeight(info: [*c]const FontInfo, pixels: f32) f32;

pub fn scaleForPixelHeight(info: FontInfo, pixels: f32) f32 {
    return stbtt_ScaleForPixelHeight(&info, pixels);
}

extern fn stbtt_FindGlyphIndex(info: [*c]const FontInfo, unicode_codepoint: c_int) c_int;
pub const findGlyphIndex = stbtt_FindGlyphIndex;
extern fn stbtt_ScaleForMappingEmToPixels(info: [*c]const FontInfo, pixels: f32) f32;
pub const scaleForMappingEmToPixels = stbtt_ScaleForMappingEmToPixels;
extern fn stbtt_GetFontVMetricsOS2(info: [*c]const FontInfo, typoAscent: [*c]c_int, typoDescent: [*c]c_int, typoLineGap: [*c]c_int) c_int;
pub const getFontVMetricsOS2 = stbtt_GetFontVMetricsOS2;
extern fn stbtt_GetFontBoundingBox(info: [*c]const FontInfo, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) void;
pub const getFontBoundingBox = stbtt_GetFontBoundingBox;
extern fn stbtt_GetCodepointHMetrics(info: [*c]const FontInfo, codepoint: c_int, advanceWidth: [*c]c_int, leftSideBearing: [*c]c_int) void;
pub const getCodepointHMetrics = stbtt_GetCodepointHMetrics;
extern fn stbtt_GetCodepointKernAdvance(info: [*c]const FontInfo, ch1: c_int, ch2: c_int) c_int;
pub const getCodepointKernAdvance = stbtt_GetCodepointKernAdvance;
extern fn stbtt_GetCodepointBox(info: [*c]const FontInfo, codepoint: c_int, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) c_int;
pub const getCodepointBox = stbtt_GetCodepointBox;
extern fn stbtt_GetGlyphHMetrics(info: [*c]const FontInfo, glyph_index: c_int, advanceWidth: [*c]c_int, leftSideBearing: [*c]c_int) void;
pub const getGlyphHMetrics = stbtt_GetGlyphHMetrics;
extern fn stbtt_GetGlyphKernAdvance(info: [*c]const FontInfo, glyph1: c_int, glyph2: c_int) c_int;
pub const getGlyphKernAdvance = stbtt_GetGlyphKernAdvance;
extern fn stbtt_GetGlyphBox(info: [*c]const FontInfo, glyph_index: c_int, x0: [*c]c_int, y0: [*c]c_int, x1: [*c]c_int, y1: [*c]c_int) c_int;
pub const getGlyphBox = stbtt_GetGlyphBox;

pub const KerningEntry = extern struct {
    glyph1: c_int,
    glyph2: c_int,
    advance: c_int,
};
extern fn stbtt_GetKerningTableLength(info: [*c]const FontInfo) c_int;
pub const getKerningTableLength = stbtt_GetKerningTableLength;
extern fn stbtt_GetKerningTable(info: [*c]const FontInfo, table: [*c]KerningEntry, table_length: c_int) c_int;
pub const getKerningTable = stbtt_GetKerningTable;

const Op = enum(c_int) {
    vmove = 1,
    vline = 2,
    vcurve = 3,
    vcubic = 4,
};

pub const Vertex = extern struct {
    x: c_short,
    y: c_short,
    cx: c_short,
    cy: c_short,
    cx1: c_short,
    cy1: c_short,
    type: u8,
    padding: u8,
};
extern fn stbtt_IsGlyphEmpty(info: [*c]const FontInfo, glyph_index: c_int) c_int;
pub const isGlyphEmpty = stbtt_IsGlyphEmpty;
extern fn stbtt_GetCodepointShape(info: [*c]const FontInfo, unicode_codepoint: c_int, vertices: [*c][*c]Vertex) c_int;
pub const getCodepointShape = stbtt_GetCodepointShape;
extern fn stbtt_GetGlyphShape(info: [*c]const FontInfo, glyph_index: c_int, vertices: [*c][*c]Vertex) c_int;
pub const getGlyphShape = stbtt_GetGlyphShape;
extern fn stbtt_FreeShape(info: [*c]const FontInfo, vertices: [*c]Vertex) void;
pub const freeShape = stbtt_FreeShape;
extern fn stbtt_GetCodepointSVG(info: [*c]const FontInfo, unicode_codepoint: c_int, svg: [*c][*c]const u8) c_int;
pub const getCodepointSVG = stbtt_GetCodepointSVG;
extern fn stbtt_GetGlyphSVG(info: [*c]const FontInfo, gl: c_int, svg: [*c][*c]const u8) c_int;
pub const getGlyphSVG = stbtt_GetGlyphSVG;
extern fn stbtt_FreeBitmap(bitmap: [*c]u8, userdata: ?*anyopaque) void;
pub const freeBitmap = stbtt_FreeBitmap;
extern fn stbtt_GetCodepointBitmap(info: [*c]const FontInfo, scale_x: f32, scale_y: f32, codepoint: c_int, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub const getCodepointBitmap = stbtt_GetCodepointBitmap;
extern fn stbtt_GetCodepointBitmapSubpixel(info: [*c]const FontInfo, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, codepoint: c_int, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub const getCodepointBitmapSubpixel = stbtt_GetCodepointBitmapSubpixel;
extern fn stbtt_MakeCodepointBitmap(info: [*c]const FontInfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, codepoint: c_int) void;
pub const makeCodepointBitmap = stbtt_MakeCodepointBitmap;
extern fn stbtt_MakeCodepointBitmapSubpixel(info: [*c]const FontInfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, codepoint: c_int) void;
pub const makeCodepointBitmapSubpixel = stbtt_MakeCodepointBitmapSubpixel;
extern fn stbtt_MakeCodepointBitmapSubpixelPrefilter(info: [*c]const FontInfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, oversample_x: c_int, oversample_y: c_int, sub_x: [*c]f32, sub_y: [*c]f32, codepoint: c_int) void;
pub const makeCodepointBitmapSubpixelPrefilter = stbtt_MakeCodepointBitmapSubpixelPrefilter;
extern fn stbtt_GetCodepointBitmapBox(font: [*c]const FontInfo, codepoint: c_int, scale_x: f32, scale_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void;
pub const getCodepointBitmapBox = stbtt_GetCodepointBitmapBox;
extern fn stbtt_GetCodepointBitmapBoxSubpixel(font: [*c]const FontInfo, codepoint: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void;
pub const getCodepointBitmapBoxSubpixel = stbtt_GetCodepointBitmapBoxSubpixel;
extern fn stbtt_GetGlyphBitmap(info: [*c]const FontInfo, scale_x: f32, scale_y: f32, glyph: c_int, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub const getGlyphBitmap = stbtt_GetGlyphBitmap;
extern fn stbtt_GetGlyphBitmapSubpixel(info: [*c]const FontInfo, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, glyph: c_int, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub const getGlyphBitmapSubpixel = stbtt_GetGlyphBitmapSubpixel;
extern fn stbtt_MakeGlyphBitmap(info: [*c]const FontInfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, glyph: c_int) void;
pub const makeGlyphBitmap = stbtt_MakeGlyphBitmap;
extern fn stbtt_MakeGlyphBitmapSubpixel(info: [*c]const FontInfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, glyph: c_int) void;
pub const makeGlyphBitmapSubpixel = stbtt_MakeGlyphBitmapSubpixel;
extern fn stbtt_MakeGlyphBitmapSubpixelPrefilter(info: [*c]const FontInfo, output: [*c]u8, out_w: c_int, out_h: c_int, out_stride: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, oversample_x: c_int, oversample_y: c_int, sub_x: [*c]f32, sub_y: [*c]f32, glyph: c_int) void;
pub const makeGlyphBitmapSubpixelPrefilter = stbtt_MakeGlyphBitmapSubpixelPrefilter;
extern fn stbtt_GetGlyphBitmapBox(font: [*c]const FontInfo, glyph: c_int, scale_x: f32, scale_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void;
pub const getGlyphBitmapBox = stbtt_GetGlyphBitmapBox;
extern fn stbtt_GetGlyphBitmapBoxSubpixel(font: [*c]const FontInfo, glyph: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, ix0: [*c]c_int, iy0: [*c]c_int, ix1: [*c]c_int, iy1: [*c]c_int) void;
pub const getGlyphBitmapBoxSubpixel = stbtt_GetGlyphBitmapBoxSubpixel;

pub const Bitmap = extern struct {
    w: c_int,
    h: c_int,
    stride: c_int,
    pixels: [*c]u8,
};
extern fn stbtt_Rasterize(result: [*c]Bitmap, flatness_in_pixels: f32, vertices: [*c]Vertex, num_verts: c_int, scale_x: f32, scale_y: f32, shift_x: f32, shift_y: f32, x_off: c_int, y_off: c_int, invert: c_int, userdata: ?*anyopaque) void;
pub const rasterize = stbtt_Rasterize;
extern fn stbtt_FreeSDF(bitmap: [*c]u8, userdata: ?*anyopaque) void;
pub const freeSDF = stbtt_FreeSDF;
extern fn stbtt_GetGlyphSDF(info: [*c]const FontInfo, scale: f32, glyph: c_int, padding: c_int, onedge_value: u8, pixel_dist_scale: f32, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub const getGlyphSDF = stbtt_GetGlyphSDF;
extern fn stbtt_GetCodepointSDF(info: [*c]const FontInfo, scale: f32, codepoint: c_int, padding: c_int, onedge_value: u8, pixel_dist_scale: f32, width: [*c]c_int, height: [*c]c_int, xoff: [*c]c_int, yoff: [*c]c_int) [*c]u8;
pub const getCodepointSDF = stbtt_GetCodepointSDF;
extern fn stbtt_FindMatchingFont(fontdata: [*c]const u8, name: [*c]const u8, flags: c_int) c_int;
pub const findMatchingFont = stbtt_FindMatchingFont;
extern fn stbtt_CompareUTF8toUTF16_bigendian(s1: [*c]const u8, len1: c_int, s2: [*c]const u8, len2: c_int) c_int;
pub const compareUTF8toUTF16_bigendian = stbtt_CompareUTF8toUTF16_bigendian;
extern fn stbtt_GetFontNameString(font: [*c]const FontInfo, length: [*c]c_int, platformID: c_int, encodingID: c_int, languageID: c_int, nameID: c_int) [*c]const u8;
pub const getFontNameString = stbtt_GetFontNameString;

const PlatformId = enum(c_int) {
    UNICODE = 0,
    MAC = 1,
    ISO = 2,
    MICROSOFT = 3,
};

const UnicodeEid = enum(c_int) {
    UNICODE_1_0 = 0,
    UNICODE_1_1 = 1,
    ISO_10646 = 2,
    UNICODE_2_0_BMP = 3,
    UNICODE_2_0_FULL = 4,
};

const MsEid = enum(c_int) {
    SYMBOL = 0,
    UNICODE_BMP = 1,
    SHIFTJIS = 2,
    UNICODE_FULL = 10,
};

const MacEid = enum(c_int) {
    ROMAN = 0,
    ARABIC = 4,
    JAPANESE = 1,
    HEBREW = 5,
    CHINESE_TRAD = 2,
    GREEK = 6,
    KOREAN = 3,
    RUSSIAN = 7,
};

const MsLang = enum(c_int) {
    ENGLISH = 1033,
    ITALIAN = 1040,
    CHINESE = 2052,
    JAPANESE = 1041,
    DUTCH = 1043,
    KOREAN = 1042,
    FRENCH = 1036,
    RUSSIAN = 1049,
    GERMAN = 1031,
    SPANISH = 1033,
    HEBREW = 1037,
    SWEDISH = 1053,
};

const MacLang = enum(c_int) {
    ENGLISH = 0,
    JAPANESE = 11,
    ARABIC = 12,
    KOREAN = 23,
    DUTCH = 4,
    RUSSIAN = 32,
    FRENCH = 1,
    SPANISH = 6,
    GERMAN = 2,
    SWEDISH = 5,
    HEBREW = 10,
    CHINESE_SIMPLIFIED = 33,
    ITALIAN = 3,
    CHINESE_TRAD = 19,
};

pub const STBTT_DEF = @compileError("unable to translate C expr: unexpected token .Keyword_extern"); // src/lib/stb_truetype.h:501:9

pub inline fn STBTT_POINT_SIZE(x: anytype) @TypeOf(-x) {
    return -x;
}
pub const Vertex_type = c_short;
pub const MACSTYLE_DONTCARE = @as(c_int, 0);
pub const MACSTYLE_BOLD = @as(c_int, 1);
pub const MACSTYLE_ITALIC = @as(c_int, 2);
pub const MACSTYLE_UNDERSCORE = @as(c_int, 4);
pub const MACSTYLE_NONE = @as(c_int, 8);
