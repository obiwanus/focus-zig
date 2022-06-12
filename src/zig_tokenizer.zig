const std = @import("std");
const mem = std.mem;

const focus = @import("focus.zig");
const u = focus.utils;

const Char = u.Char;

pub const Token = struct {
    tag: Tag,
    loc: Loc,

    pub const Loc = struct {
        start: usize,
        end: usize,
    };

    pub const keywords = std.ComptimeStringMap(Tag, .{
        .{ "addrspace", .keyword_addrspace },
        .{ "align", .keyword_align },
        .{ "allowzero", .keyword_allowzero },
        .{ "and", .keyword_and },
        .{ "anyframe", .keyword_anyframe },
        .{ "anytype", .keyword_anytype },
        .{ "asm", .keyword_asm },
        .{ "async", .keyword_async },
        .{ "await", .keyword_await },
        .{ "break", .keyword_break },
        .{ "callconv", .keyword_callconv },
        .{ "catch", .keyword_catch },
        .{ "comptime", .keyword_comptime },
        .{ "const", .keyword_const },
        .{ "continue", .keyword_continue },
        .{ "defer", .keyword_defer },
        .{ "else", .keyword_else },
        .{ "enum", .keyword_enum },
        .{ "errdefer", .keyword_errdefer },
        .{ "error", .keyword_error },
        .{ "export", .keyword_export },
        .{ "extern", .keyword_extern },
        .{ "fn", .keyword_fn },
        .{ "for", .keyword_for },
        .{ "if", .keyword_if },
        .{ "inline", .keyword_inline },
        .{ "noalias", .keyword_noalias },
        .{ "noinline", .keyword_noinline },
        .{ "nosuspend", .keyword_nosuspend },
        .{ "opaque", .keyword_opaque },
        .{ "or", .keyword_or },
        .{ "orelse", .keyword_orelse },
        .{ "packed", .keyword_packed },
        .{ "pub", .keyword_pub },
        .{ "resume", .keyword_resume },
        .{ "return", .keyword_return },
        .{ "linksection", .keyword_linksection },
        .{ "struct", .keyword_struct },
        .{ "suspend", .keyword_suspend },
        .{ "switch", .keyword_switch },
        .{ "test", .keyword_test },
        .{ "threadlocal", .keyword_threadlocal },
        .{ "try", .keyword_try },
        .{ "union", .keyword_union },
        .{ "unreachable", .keyword_unreachable },
        .{ "usingnamespace", .keyword_usingnamespace },
        .{ "var", .keyword_var },
        .{ "volatile", .keyword_volatile },
        .{ "while", .keyword_while },
    });

    pub fn getKeyword(chars: []const Char) ?Tag {
        const len = u.min(chars.len, 20);
        var bytes: [20]u8 = undefined;
        for (chars[0..len]) |char, i| bytes[i] = @intCast(u8, char);
        return keywords.get(bytes[0..len]);
    }

    pub const Tag = enum {
        invalid,
        invalid_periodasterisks,
        identifier,
        string_literal,
        multiline_string_literal_line,
        char_literal,
        eof,
        builtin,
        bang,
        pipe,
        pipe_pipe,
        pipe_equal,
        equal,
        equal_equal,
        equal_angle_bracket_right,
        bang_equal,
        l_paren,
        r_paren,
        semicolon,
        percent,
        percent_equal,
        l_brace,
        r_brace,
        l_bracket,
        r_bracket,
        period,
        period_asterisk,
        ellipsis2,
        ellipsis3,
        caret,
        caret_equal,
        plus,
        plus_plus,
        plus_equal,
        plus_percent,
        plus_percent_equal,
        plus_pipe,
        plus_pipe_equal,
        minus,
        minus_equal,
        minus_percent,
        minus_percent_equal,
        minus_pipe,
        minus_pipe_equal,
        asterisk,
        asterisk_equal,
        asterisk_asterisk,
        asterisk_percent,
        asterisk_percent_equal,
        asterisk_pipe,
        asterisk_pipe_equal,
        arrow,
        colon,
        slash,
        slash_equal,
        comma,
        ampersand,
        ampersand_equal,
        question_mark,
        angle_bracket_left,
        angle_bracket_left_equal,
        angle_bracket_angle_bracket_left,
        angle_bracket_angle_bracket_left_equal,
        angle_bracket_angle_bracket_left_pipe,
        angle_bracket_angle_bracket_left_pipe_equal,
        angle_bracket_right,
        angle_bracket_right_equal,
        angle_bracket_angle_bracket_right,
        angle_bracket_angle_bracket_right_equal,
        tilde,
        integer_literal,
        float_literal,
        doc_comment,
        container_doc_comment,
        keyword_addrspace,
        keyword_align,
        keyword_allowzero,
        keyword_and,
        keyword_anyframe,
        keyword_anytype,
        keyword_asm,
        keyword_async,
        keyword_await,
        keyword_break,
        keyword_callconv,
        keyword_catch,
        keyword_comptime,
        keyword_const,
        keyword_continue,
        keyword_defer,
        keyword_else,
        keyword_enum,
        keyword_errdefer,
        keyword_error,
        keyword_export,
        keyword_extern,
        keyword_fn,
        keyword_for,
        keyword_if,
        keyword_inline,
        keyword_noalias,
        keyword_noinline,
        keyword_nosuspend,
        keyword_opaque,
        keyword_or,
        keyword_orelse,
        keyword_packed,
        keyword_pub,
        keyword_resume,
        keyword_return,
        keyword_linksection,
        keyword_struct,
        keyword_suspend,
        keyword_switch,
        keyword_test,
        keyword_threadlocal,
        keyword_try,
        keyword_union,
        keyword_unreachable,
        keyword_usingnamespace,
        keyword_var,
        keyword_volatile,
        keyword_while,

        pub fn lexeme(tag: Tag) ?[]const u8 {
            return switch (tag) {
                .invalid,
                .identifier,
                .string_literal,
                .multiline_string_literal_line,
                .char_literal,
                .eof,
                .builtin,
                .integer_literal,
                .float_literal,
                .doc_comment,
                .container_doc_comment,
                => null,

                .invalid_periodasterisks => ".**",
                .bang => "!",
                .pipe => "|",
                .pipe_pipe => "||",
                .pipe_equal => "|=",
                .equal => "=",
                .equal_equal => "==",
                .equal_angle_bracket_right => "=>",
                .bang_equal => "!=",
                .l_paren => "(",
                .r_paren => ")",
                .semicolon => ";",
                .percent => "%",
                .percent_equal => "%=",
                .l_brace => "{",
                .r_brace => "}",
                .l_bracket => "[",
                .r_bracket => "]",
                .period => ".",
                .period_asterisk => ".*",
                .ellipsis2 => "..",
                .ellipsis3 => "...",
                .caret => "^",
                .caret_equal => "^=",
                .plus => "+",
                .plus_plus => "++",
                .plus_equal => "+=",
                .plus_percent => "+%",
                .plus_percent_equal => "+%=",
                .plus_pipe => "+|",
                .plus_pipe_equal => "+|=",
                .minus => "-",
                .minus_equal => "-=",
                .minus_percent => "-%",
                .minus_percent_equal => "-%=",
                .minus_pipe => "-|",
                .minus_pipe_equal => "-|=",
                .asterisk => "*",
                .asterisk_equal => "*=",
                .asterisk_asterisk => "**",
                .asterisk_percent => "*%",
                .asterisk_percent_equal => "*%=",
                .asterisk_pipe => "*|",
                .asterisk_pipe_equal => "*|=",
                .arrow => "->",
                .colon => ":",
                .slash => "/",
                .slash_equal => "/=",
                .comma => ",",
                .ampersand => "&",
                .ampersand_equal => "&=",
                .question_mark => "?",
                .angle_bracket_left => "<",
                .angle_bracket_left_equal => "<=",
                .angle_bracket_angle_bracket_left => "<<",
                .angle_bracket_angle_bracket_left_equal => "<<=",
                .angle_bracket_angle_bracket_left_pipe => "<<|",
                .angle_bracket_angle_bracket_left_pipe_equal => "<<|=",
                .angle_bracket_right => ">",
                .angle_bracket_right_equal => ">=",
                .angle_bracket_angle_bracket_right => ">>",
                .angle_bracket_angle_bracket_right_equal => ">>=",
                .tilde => "~",
                .keyword_addrspace => "addrspace",
                .keyword_align => "align",
                .keyword_allowzero => "allowzero",
                .keyword_and => "and",
                .keyword_anyframe => "anyframe",
                .keyword_anytype => "anytype",
                .keyword_asm => "asm",
                .keyword_async => "async",
                .keyword_await => "await",
                .keyword_break => "break",
                .keyword_callconv => "callconv",
                .keyword_catch => "catch",
                .keyword_comptime => "comptime",
                .keyword_const => "const",
                .keyword_continue => "continue",
                .keyword_defer => "defer",
                .keyword_else => "else",
                .keyword_enum => "enum",
                .keyword_errdefer => "errdefer",
                .keyword_error => "error",
                .keyword_export => "export",
                .keyword_extern => "extern",
                .keyword_fn => "fn",
                .keyword_for => "for",
                .keyword_if => "if",
                .keyword_inline => "inline",
                .keyword_noalias => "noalias",
                .keyword_noinline => "noinline",
                .keyword_nosuspend => "nosuspend",
                .keyword_opaque => "opaque",
                .keyword_or => "or",
                .keyword_orelse => "orelse",
                .keyword_packed => "packed",
                .keyword_pub => "pub",
                .keyword_resume => "resume",
                .keyword_return => "return",
                .keyword_linksection => "linksection",
                .keyword_struct => "struct",
                .keyword_suspend => "suspend",
                .keyword_switch => "switch",
                .keyword_test => "test",
                .keyword_threadlocal => "threadlocal",
                .keyword_try => "try",
                .keyword_union => "union",
                .keyword_unreachable => "unreachable",
                .keyword_usingnamespace => "usingnamespace",
                .keyword_var => "var",
                .keyword_volatile => "volatile",
                .keyword_while => "while",
            };
        }

        pub fn symbol(tag: Tag) []const u8 {
            return tag.lexeme() orelse @tagName(tag);
        }
    };
};

pub const Tokenizer = struct {
    buffer: []const Char,
    index: usize,
    pending_invalid_token: ?Token,

    pub fn init(buffer: []const Char) Tokenizer {
        return Tokenizer{
            .buffer = buffer,
            .index = 0,
            .pending_invalid_token = null,
        };
    }

    const State = enum {
        start,
        identifier,
        builtin,
        string_literal,
        string_literal_backslash,
        multiline_string_literal_line,
        char_literal,
        char_literal_backslash,
        char_literal_hex_escape,
        char_literal_unicode_escape_saw_u,
        char_literal_unicode_escape,
        char_literal_unicode_invalid,
        char_literal_unicode,
        char_literal_end,
        backslash,
        equal,
        bang,
        pipe,
        minus,
        minus_percent,
        minus_pipe,
        asterisk,
        asterisk_percent,
        asterisk_pipe,
        slash,
        line_comment_start,
        line_comment,
        doc_comment_start,
        doc_comment,
        zero,
        int_literal_dec,
        int_literal_dec_no_underscore,
        int_literal_bin,
        int_literal_bin_no_underscore,
        int_literal_oct,
        int_literal_oct_no_underscore,
        int_literal_hex,
        int_literal_hex_no_underscore,
        num_dot_dec,
        num_dot_hex,
        float_fraction_dec,
        float_fraction_dec_no_underscore,
        float_fraction_hex,
        float_fraction_hex_no_underscore,
        float_exponent_unsigned,
        float_exponent_num,
        float_exponent_num_no_underscore,
        ampersand,
        caret,
        percent,
        plus,
        plus_percent,
        plus_pipe,
        angle_bracket_left,
        angle_bracket_angle_bracket_left,
        angle_bracket_angle_bracket_left_pipe,
        angle_bracket_right,
        angle_bracket_angle_bracket_right,
        period,
        period_2,
        period_asterisk,
        saw_at_sign,
    };

    pub fn next(self: *Tokenizer) Token {
        if (self.pending_invalid_token) |token| {
            self.pending_invalid_token = null;
            return token;
        }
        var state: State = .start;
        var result = Token{
            .tag = .eof,
            .loc = .{
                .start = self.index,
                .end = undefined,
            },
        };
        var seen_escape_digits: usize = undefined;
        var remaining_code_units: usize = undefined;
        while (true) : (self.index += 1) {
            if (self.index >= self.buffer.len) break;
            const c = self.buffer[self.index];
            switch (state) {
                .start => switch (c) {
                    0 => @panic("Unexpected zero in char buffer"),
                    ' ', '\n', '\t', '\r' => {
                        result.loc.start = self.index + 1;
                    },
                    '"' => {
                        state = .string_literal;
                        result.tag = .string_literal;
                    },
                    '\'' => {
                        state = .char_literal;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .identifier;
                        result.tag = .identifier;
                    },
                    '@' => {
                        state = .saw_at_sign;
                    },
                    '=' => {
                        state = .equal;
                    },
                    '!' => {
                        state = .bang;
                    },
                    '|' => {
                        state = .pipe;
                    },
                    '(' => {
                        result.tag = .l_paren;
                        self.index += 1;
                        break;
                    },
                    ')' => {
                        result.tag = .r_paren;
                        self.index += 1;
                        break;
                    },
                    '[' => {
                        result.tag = .l_bracket;
                        self.index += 1;
                        break;
                    },
                    ']' => {
                        result.tag = .r_bracket;
                        self.index += 1;
                        break;
                    },
                    ';' => {
                        result.tag = .semicolon;
                        self.index += 1;
                        break;
                    },
                    ',' => {
                        result.tag = .comma;
                        self.index += 1;
                        break;
                    },
                    '?' => {
                        result.tag = .question_mark;
                        self.index += 1;
                        break;
                    },
                    ':' => {
                        result.tag = .colon;
                        self.index += 1;
                        break;
                    },
                    '%' => {
                        state = .percent;
                    },
                    '*' => {
                        state = .asterisk;
                    },
                    '+' => {
                        state = .plus;
                    },
                    '<' => {
                        state = .angle_bracket_left;
                    },
                    '>' => {
                        state = .angle_bracket_right;
                    },
                    '^' => {
                        state = .caret;
                    },
                    '\\' => {
                        state = .backslash;
                        result.tag = .multiline_string_literal_line;
                    },
                    '{' => {
                        result.tag = .l_brace;
                        self.index += 1;
                        break;
                    },
                    '}' => {
                        result.tag = .r_brace;
                        self.index += 1;
                        break;
                    },
                    '~' => {
                        result.tag = .tilde;
                        self.index += 1;
                        break;
                    },
                    '.' => {
                        state = .period;
                    },
                    '-' => {
                        state = .minus;
                    },
                    '/' => {
                        state = .slash;
                    },
                    '&' => {
                        state = .ampersand;
                    },
                    '0' => {
                        state = .zero;
                        result.tag = .integer_literal;
                    },
                    '1'...'9' => {
                        state = .int_literal_dec;
                        result.tag = .integer_literal;
                    },
                    else => {
                        result.tag = .invalid;
                        result.loc.end = self.index;
                        self.index += 1;
                        return result;
                    },
                },

                .saw_at_sign => switch (c) {
                    '"' => {
                        result.tag = .identifier;
                        state = .string_literal;
                    },
                    'a'...'z', 'A'...'Z', '_' => {
                        state = .builtin;
                        result.tag = .builtin;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .ampersand => switch (c) {
                    '=' => {
                        result.tag = .ampersand_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .ampersand;
                        break;
                    },
                },

                .asterisk => switch (c) {
                    '=' => {
                        result.tag = .asterisk_equal;
                        self.index += 1;
                        break;
                    },
                    '*' => {
                        result.tag = .asterisk_asterisk;
                        self.index += 1;
                        break;
                    },
                    '%' => {
                        state = .asterisk_percent;
                    },
                    '|' => {
                        state = .asterisk_pipe;
                    },
                    else => {
                        result.tag = .asterisk;
                        break;
                    },
                },

                .asterisk_percent => switch (c) {
                    '=' => {
                        result.tag = .asterisk_percent_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .asterisk_percent;
                        break;
                    },
                },

                .asterisk_pipe => switch (c) {
                    '=' => {
                        result.tag = .asterisk_pipe_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .asterisk_pipe;
                        break;
                    },
                },

                .percent => switch (c) {
                    '=' => {
                        result.tag = .percent_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .percent;
                        break;
                    },
                },

                .plus => switch (c) {
                    '=' => {
                        result.tag = .plus_equal;
                        self.index += 1;
                        break;
                    },
                    '+' => {
                        result.tag = .plus_plus;
                        self.index += 1;
                        break;
                    },
                    '%' => {
                        state = .plus_percent;
                    },
                    '|' => {
                        state = .plus_pipe;
                    },
                    else => {
                        result.tag = .plus;
                        break;
                    },
                },

                .plus_percent => switch (c) {
                    '=' => {
                        result.tag = .plus_percent_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .plus_percent;
                        break;
                    },
                },

                .plus_pipe => switch (c) {
                    '=' => {
                        result.tag = .plus_pipe_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .plus_pipe;
                        break;
                    },
                },

                .caret => switch (c) {
                    '=' => {
                        result.tag = .caret_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .caret;
                        break;
                    },
                },

                .identifier => switch (c) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                    else => {
                        if (Token.getKeyword(self.buffer[result.loc.start..self.index])) |tag| {
                            result.tag = tag;
                        }
                        break;
                    },
                },
                .builtin => switch (c) {
                    'a'...'z', 'A'...'Z', '_', '0'...'9' => {},
                    else => break,
                },
                .backslash => switch (c) {
                    '\\' => {
                        state = .multiline_string_literal_line;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },
                .string_literal => switch (c) {
                    '\\' => {
                        state = .string_literal_backslash;
                    },
                    '"' => {
                        self.index += 1;
                        break;
                    },
                    0 => {
                        if (self.index == self.buffer.len) {
                            break;
                        } else {
                            self.checkLiteralCharacter();
                        }
                    },
                    '\n' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => self.checkLiteralCharacter(),
                },

                .string_literal_backslash => switch (c) {
                    0, '\n' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => {
                        state = .string_literal;
                    },
                },

                .char_literal => switch (c) {
                    0 => {
                        result.tag = .invalid;
                        break;
                    },
                    '\\' => {
                        state = .char_literal_backslash;
                    },
                    '\'', 0x80...0xbf, 0xf8...0xff => {
                        result.tag = .invalid;
                        break;
                    },
                    0xc0...0xdf => { // 110xxxxx
                        remaining_code_units = 1;
                        state = .char_literal_unicode;
                    },
                    0xe0...0xef => { // 1110xxxx
                        remaining_code_units = 2;
                        state = .char_literal_unicode;
                    },
                    0xf0...0xf7 => { // 11110xxx
                        remaining_code_units = 3;
                        state = .char_literal_unicode;
                    },
                    else => {
                        state = .char_literal_end;
                    },
                },

                .char_literal_backslash => switch (c) {
                    0, '\n' => {
                        result.tag = .invalid;
                        break;
                    },
                    'x' => {
                        state = .char_literal_hex_escape;
                        seen_escape_digits = 0;
                    },
                    'u' => {
                        state = .char_literal_unicode_escape_saw_u;
                    },
                    else => {
                        state = .char_literal_end;
                    },
                },

                .char_literal_hex_escape => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        seen_escape_digits += 1;
                        if (seen_escape_digits == 2) {
                            state = .char_literal_end;
                        }
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .char_literal_unicode_escape_saw_u => switch (c) {
                    0 => {
                        result.tag = .invalid;
                        break;
                    },
                    '{' => {
                        state = .char_literal_unicode_escape;
                    },
                    else => {
                        result.tag = .invalid;
                        state = .char_literal_unicode_invalid;
                    },
                },

                .char_literal_unicode_escape => switch (c) {
                    0 => {
                        result.tag = .invalid;
                        break;
                    },
                    '0'...'9', 'a'...'f', 'A'...'F' => {},
                    '}' => {
                        state = .char_literal_end; // too many/few digits handled later
                    },
                    else => {
                        result.tag = .invalid;
                        state = .char_literal_unicode_invalid;
                    },
                },

                .char_literal_unicode_invalid => switch (c) {
                    // Keep consuming characters until an obvious stopping point.
                    // This consolidates e.g. `u{0ab1Q}` into a single invalid token
                    // instead of creating the tokens `u{0ab1`, `Q`, `}`
                    '0'...'9', 'a'...'z', 'A'...'Z', '}' => {},
                    else => break,
                },

                .char_literal_end => switch (c) {
                    '\'' => {
                        result.tag = .char_literal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .char_literal_unicode => switch (c) {
                    0x80...0xbf => {
                        remaining_code_units -= 1;
                        if (remaining_code_units == 0) {
                            state = .char_literal_end;
                        }
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },

                .multiline_string_literal_line => switch (c) {
                    0 => break,
                    '\n' => {
                        self.index += 1;
                        break;
                    },
                    '\t' => {},
                    else => self.checkLiteralCharacter(),
                },

                .bang => switch (c) {
                    '=' => {
                        result.tag = .bang_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .bang;
                        break;
                    },
                },

                .pipe => switch (c) {
                    '=' => {
                        result.tag = .pipe_equal;
                        self.index += 1;
                        break;
                    },
                    '|' => {
                        result.tag = .pipe_pipe;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .pipe;
                        break;
                    },
                },

                .equal => switch (c) {
                    '=' => {
                        result.tag = .equal_equal;
                        self.index += 1;
                        break;
                    },
                    '>' => {
                        result.tag = .equal_angle_bracket_right;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .equal;
                        break;
                    },
                },

                .minus => switch (c) {
                    '>' => {
                        result.tag = .arrow;
                        self.index += 1;
                        break;
                    },
                    '=' => {
                        result.tag = .minus_equal;
                        self.index += 1;
                        break;
                    },
                    '%' => {
                        state = .minus_percent;
                    },
                    '|' => {
                        state = .minus_pipe;
                    },
                    else => {
                        result.tag = .minus;
                        break;
                    },
                },

                .minus_percent => switch (c) {
                    '=' => {
                        result.tag = .minus_percent_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .minus_percent;
                        break;
                    },
                },
                .minus_pipe => switch (c) {
                    '=' => {
                        result.tag = .minus_pipe_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .minus_pipe;
                        break;
                    },
                },

                .angle_bracket_left => switch (c) {
                    '<' => {
                        state = .angle_bracket_angle_bracket_left;
                    },
                    '=' => {
                        result.tag = .angle_bracket_left_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_left;
                        break;
                    },
                },

                .angle_bracket_angle_bracket_left => switch (c) {
                    '=' => {
                        result.tag = .angle_bracket_angle_bracket_left_equal;
                        self.index += 1;
                        break;
                    },
                    '|' => {
                        state = .angle_bracket_angle_bracket_left_pipe;
                    },
                    else => {
                        result.tag = .angle_bracket_angle_bracket_left;
                        break;
                    },
                },

                .angle_bracket_angle_bracket_left_pipe => switch (c) {
                    '=' => {
                        result.tag = .angle_bracket_angle_bracket_left_pipe_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_angle_bracket_left_pipe;
                        break;
                    },
                },

                .angle_bracket_right => switch (c) {
                    '>' => {
                        state = .angle_bracket_angle_bracket_right;
                    },
                    '=' => {
                        result.tag = .angle_bracket_right_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_right;
                        break;
                    },
                },

                .angle_bracket_angle_bracket_right => switch (c) {
                    '=' => {
                        result.tag = .angle_bracket_angle_bracket_right_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .angle_bracket_angle_bracket_right;
                        break;
                    },
                },

                .period => switch (c) {
                    '.' => {
                        state = .period_2;
                    },
                    '*' => {
                        state = .period_asterisk;
                    },
                    else => {
                        result.tag = .period;
                        break;
                    },
                },

                .period_2 => switch (c) {
                    '.' => {
                        result.tag = .ellipsis3;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .ellipsis2;
                        break;
                    },
                },

                .period_asterisk => switch (c) {
                    '*' => {
                        result.tag = .invalid_periodasterisks;
                        break;
                    },
                    else => {
                        result.tag = .period_asterisk;
                        break;
                    },
                },

                .slash => switch (c) {
                    '/' => {
                        state = .line_comment_start;
                    },
                    '=' => {
                        result.tag = .slash_equal;
                        self.index += 1;
                        break;
                    },
                    else => {
                        result.tag = .slash;
                        break;
                    },
                },
                .line_comment_start => switch (c) {
                    0 => {
                        if (self.index != self.buffer.len) {
                            result.tag = .invalid;
                            self.index += 1;
                        }
                        break;
                    },
                    '/' => {
                        state = .doc_comment_start;
                    },
                    '!' => {
                        result.tag = .container_doc_comment;
                        state = .doc_comment;
                    },
                    '\n' => {
                        state = .start;
                        result.loc.start = self.index + 1;
                    },
                    '\t', '\r' => state = .line_comment,
                    else => {
                        state = .line_comment;
                        self.checkLiteralCharacter();
                    },
                },
                .doc_comment_start => switch (c) {
                    '/' => {
                        state = .line_comment;
                    },
                    0, '\n' => {
                        result.tag = .doc_comment;
                        break;
                    },
                    '\t', '\r' => {
                        state = .doc_comment;
                        result.tag = .doc_comment;
                    },
                    else => {
                        state = .doc_comment;
                        result.tag = .doc_comment;
                        self.checkLiteralCharacter();
                    },
                },
                .line_comment => switch (c) {
                    0 => break,
                    '\n' => {
                        state = .start;
                        result.loc.start = self.index + 1;
                    },
                    '\t', '\r' => {},
                    else => self.checkLiteralCharacter(),
                },
                .doc_comment => switch (c) {
                    0, '\n' => break,
                    '\t', '\r' => {},
                    else => self.checkLiteralCharacter(),
                },
                .zero => switch (c) {
                    'b' => {
                        state = .int_literal_bin_no_underscore;
                    },
                    'o' => {
                        state = .int_literal_oct_no_underscore;
                    },
                    'x' => {
                        state = .int_literal_hex_no_underscore;
                    },
                    '0'...'9', '_', '.', 'e', 'E' => {
                        // reinterpret as a decimal number
                        self.index -= 1;
                        state = .int_literal_dec;
                    },
                    'a', 'c', 'd', 'f'...'n', 'p'...'w', 'y', 'z', 'A'...'D', 'F'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
                .int_literal_bin_no_underscore => switch (c) {
                    '0'...'1' => {
                        state = .int_literal_bin;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },
                .int_literal_bin => switch (c) {
                    '_' => {
                        state = .int_literal_bin_no_underscore;
                    },
                    '0'...'1' => {},
                    '2'...'9', 'a'...'z', 'A'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
                .int_literal_oct_no_underscore => switch (c) {
                    '0'...'7' => {
                        state = .int_literal_oct;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },
                .int_literal_oct => switch (c) {
                    '_' => {
                        state = .int_literal_oct_no_underscore;
                    },
                    '0'...'7' => {},
                    '8', '9', 'a'...'z', 'A'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
                .int_literal_dec_no_underscore => switch (c) {
                    '0'...'9' => {
                        state = .int_literal_dec;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },
                .int_literal_dec => switch (c) {
                    '_' => {
                        state = .int_literal_dec_no_underscore;
                    },
                    '.' => {
                        state = .num_dot_dec;
                        result.tag = .invalid;
                    },
                    'e', 'E' => {
                        state = .float_exponent_unsigned;
                        result.tag = .float_literal;
                    },
                    '0'...'9' => {},
                    'a'...'d', 'f'...'z', 'A'...'D', 'F'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
                .int_literal_hex_no_underscore => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        state = .int_literal_hex;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },
                .int_literal_hex => switch (c) {
                    '_' => {
                        state = .int_literal_hex_no_underscore;
                    },
                    '.' => {
                        state = .num_dot_hex;
                        result.tag = .invalid;
                    },
                    'p', 'P' => {
                        state = .float_exponent_unsigned;
                        result.tag = .float_literal;
                    },
                    '0'...'9', 'a'...'f', 'A'...'F' => {},
                    'g'...'o', 'q'...'z', 'G'...'O', 'Q'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
                .num_dot_dec => switch (c) {
                    '.' => {
                        result.tag = .integer_literal;
                        self.index -= 1;
                        state = .start;
                        break;
                    },
                    '0'...'9' => {
                        result.tag = .float_literal;
                        state = .float_fraction_dec;
                    },
                    '_', 'a'...'z', 'A'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
                .num_dot_hex => switch (c) {
                    '.' => {
                        result.tag = .integer_literal;
                        self.index -= 1;
                        state = .start;
                        break;
                    },
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        result.tag = .float_literal;
                        state = .float_fraction_hex;
                    },
                    '_', 'g'...'z', 'G'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
                .float_fraction_dec_no_underscore => switch (c) {
                    '0'...'9' => {
                        state = .float_fraction_dec;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },
                .float_fraction_dec => switch (c) {
                    '_' => {
                        state = .float_fraction_dec_no_underscore;
                    },
                    'e', 'E' => {
                        state = .float_exponent_unsigned;
                    },
                    '0'...'9' => {},
                    'a'...'d', 'f'...'z', 'A'...'D', 'F'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
                .float_fraction_hex_no_underscore => switch (c) {
                    '0'...'9', 'a'...'f', 'A'...'F' => {
                        state = .float_fraction_hex;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },
                .float_fraction_hex => switch (c) {
                    '_' => {
                        state = .float_fraction_hex_no_underscore;
                    },
                    'p', 'P' => {
                        state = .float_exponent_unsigned;
                    },
                    '0'...'9', 'a'...'f', 'A'...'F' => {},
                    'g'...'o', 'q'...'z', 'G'...'O', 'Q'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
                .float_exponent_unsigned => switch (c) {
                    '+', '-' => {
                        state = .float_exponent_num_no_underscore;
                    },
                    else => {
                        // reinterpret as a normal exponent number
                        self.index -= 1;
                        state = .float_exponent_num_no_underscore;
                    },
                },
                .float_exponent_num_no_underscore => switch (c) {
                    '0'...'9' => {
                        state = .float_exponent_num;
                    },
                    else => {
                        result.tag = .invalid;
                        break;
                    },
                },
                .float_exponent_num => switch (c) {
                    '_' => {
                        state = .float_exponent_num_no_underscore;
                    },
                    '0'...'9' => {},
                    'a'...'z', 'A'...'Z' => {
                        result.tag = .invalid;
                        break;
                    },
                    else => break,
                },
            }
        }

        if (result.tag == .eof) {
            if (self.pending_invalid_token) |token| {
                self.pending_invalid_token = null;
                return token;
            }
            result.loc.start = self.index;
        }

        result.loc.end = self.index;
        return result;
    }

    fn checkLiteralCharacter(self: *Tokenizer) void {
        if (self.pending_invalid_token != null) return;
        const invalid_length = self.getInvalidCharacterLength();
        if (invalid_length == 0) return;
        self.pending_invalid_token = .{
            .tag = .invalid,
            .loc = .{
                .start = self.index,
                .end = self.index + invalid_length,
            },
        };
    }

    fn getInvalidCharacterLength(self: *Tokenizer) u3 {
        // NOTE(Ivan): probably can just remove the function?
        const c0 = self.buffer[self.index];
        if (c0 < 0x80) {
            if (c0 < 0x20 or c0 == 0x7f) {
                // ascii control codes are never allowed
                // (note that \n was checked before we got here)
                return 1;
            }
            // looks fine to me.
            return 0;
        } else {
            // // check utf8-encoded character.
            // const length = std.unicode.utf8ByteSequenceLength(c0) catch return 1;
            // if (self.index + length > self.buffer.len) {
            //     return @intCast(u3, self.buffer.len - self.index);
            // }
            // const bytes = self.buffer[self.index .. self.index + length];
            // switch (length) {
            //     2 => {
            //         const value = std.unicode.utf8Decode2(bytes) catch return length;
            //         if (value == 0x85) return length; // U+0085 (NEL)
            //     },
            //     3 => {
            //         const value = std.unicode.utf8Decode3(bytes) catch return length;
            //         if (value == 0x2028) return length; // U+2028 (LS)
            //         if (value == 0x2029) return length; // U+2029 (PS)
            //     },
            //     4 => {
            //         _ = std.unicode.utf8Decode4(bytes) catch return length;
            //     },
            //     else => unreachable,
            // }
            // self.index += length - 1;
            return 0;
        }
    }
};
