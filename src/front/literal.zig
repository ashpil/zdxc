//! Numeric and character literals as clang reads them (NumericLiteralParser,
//! CharLiteralParser, with dxc's `.#INF`): the one reading shared by the
//! preprocessor's `#if` and Sema, so both reject what dxc rejects and agree
//! on the value of the rest.

const std = @import("std");
const source = @import("source.zig");
const Diagnostics = @import("../diag.zig").Diagnostics;
const Loc = source.Loc;

// -------------------------------------------------------------------------
// Numbers

pub const Number = struct { end: usize, float: bool, inf: bool = false };

/// `0x...`: a hexadecimal literal, integer or (with `p`) floating.
pub fn isHex(text: []const u8) bool {
    return text.len > 1 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X');
}

/// `0b101`: a binary integer literal (clang accepts them in HLSL).
pub fn isBinary(text: []const u8) bool {
    return text.len > 2 and text[0] == '0' and (text[1] == 'b' or text[1] == 'B') and (text[2] == '0' or text[2] == '1');
}

/// Whether clang's radix for an integer literal is 10: not hex, binary, or
/// anything starting with `0` (`0` itself is octal).
pub fn isDecimal(text: []const u8) bool {
    return text.len > 0 and text[0] != '0';
}

/// The digits of a numeric literal: where the suffix starts and whether it
/// is floating.
pub fn scan(text: []const u8) Number {
    var i: usize = 0;
    if (isBinary(text)) {
        i = 2;
        while (i < text.len and (text[i] == '0' or text[i] == '1')) i += 1;
        return .{ .end = i, .float = false };
    }
    const hex = isHex(text);
    if (hex) i = 2;
    const isDigit = struct {
        fn f(c: u8, h: bool) bool {
            return if (h) std.ascii.isHex(c) else std.ascii.isDigit(c);
        }
    }.f;
    while (i < text.len and isDigit(text[i], hex)) i += 1;
    var float = false;
    if (i < text.len and text[i] == '.') {
        float = true;
        i += 1;
        while (i < text.len and isDigit(text[i], hex)) i += 1;
    }
    const exp_chars: []const u8 = if (hex) "pP" else "eE";
    if (i < text.len and std.mem.indexOfScalar(u8, exp_chars, text[i]) != null) {
        var j = i + 1;
        if (j < text.len and (text[j] == '+' or text[j] == '-')) j += 1;
        if (j < text.len and std.ascii.isDigit(text[j])) {
            float = true;
            i = j;
            while (i < text.len and std.ascii.isDigit(text[i])) i += 1;
        }
    }
    if (float and std.mem.startsWith(u8, text[i..], "#INF")) return .{ .end = i + 4, .float = true, .inf = true };
    return .{ .end = i, .float = float };
}

/// `u`, `l`, `ll` in either order and any case, but the two letters of `ll`
/// alike: `1lL` is an invalid suffix.
pub fn isIntSuffix(suffix: []const u8) bool {
    var s = suffix;
    if (s.len > 0 and (s[0] == 'u' or s[0] == 'U')) {
        s = s[1..];
    } else if (s.len > 0 and (s[s.len - 1] == 'u' or s[s.len - 1] == 'U')) {
        s = s[0 .. s.len - 1];
    }
    return switch (s.len) {
        0 => true,
        1 => s[0] == 'l' or s[0] == 'L',
        2 => (s[0] == 'l' or s[0] == 'L') and s[1] == s[0],
        else => false,
    };
}

/// `f`, `h`, `l` in any case, or the fixed-size `f16` / `f32` / `f64`.
pub fn isFloatSuffix(suffix: []const u8) bool {
    return switch (suffix.len) {
        0 => true,
        1 => std.mem.indexOfScalar(u8, "fFhHlL", suffix[0]) != null,
        3 => (suffix[0] == 'f' or suffix[0] == 'F') and (std.mem.eql(u8, suffix[1..], "16") or std.mem.eql(u8, suffix[1..], "32") or std.mem.eql(u8, suffix[1..], "64")),
        else => false,
    };
}

/// The value of an integer literal's digits (no suffix), or null if it
/// does not fit 64 bits.
pub fn parseDigits(digits: []const u8) ?u64 {
    var base: u8 = 10;
    var body = digits;
    if (isHex(digits)) {
        base = 16;
        body = digits[2..];
    } else if (isBinary(digits)) {
        base = 2;
        body = digits[2..];
    } else if (digits.len > 1 and digits[0] == '0') {
        base = 8;
        body = digits[1..];
    }
    return std.fmt.parseInt(u64, body, base) catch null;
}

/// Why a literal's digits do not form a number, and where in the token.
pub const Problem = struct {
    at: u32,
    kind: union(enum) {
        /// `0x`, `0xg`: the suffix of the integer `0`.
        invalid_suffix: []const u8,
        needs_significand,
        needs_exponent,
        exponent_no_digits,
        invalid_digit: struct { c: u8, base: []const u8 },
        too_large,
    },
};

/// Literals whose digits do not form a number (clang's NumericLiteralParser
/// errors). Whatever passes this and has a valid suffix, parseDigits and
/// std.fmt.parseFloat read: all three take the digits from `scan`.
pub fn checkDigits(text: []const u8, lit: Number) ?Problem {
    const hex = isHex(text);
    const binary = isBinary(text);
    if (hex) {
        // `0x`, `0xp1`: no significand and no `.`, so the suffix starts at `x`.
        var i: usize = 2;
        while (i < text.len and std.ascii.isHex(text[i])) i += 1;
        if (i == 2) {
            if (i == text.len or text[i] != '.') return .{ .at = 1, .kind = .{ .invalid_suffix = text[1..] } };
            // `0x.`, `0x.p1`: a `.` with no digits on either side.
            i += 1;
            const frac = i;
            while (i < text.len and std.ascii.isHex(text[i])) i += 1;
            if (i == frac) return .{ .at = @intCast(i), .kind = .needs_significand };
        }
    }
    const end: u32 = @intCast(lit.end);
    if (lit.end < text.len) {
        const c = text[lit.end];
        if (binary) {
            // clang: any hex digit after the binary digits (`0b12`, `0b1f`).
            if (std.ascii.isHex(c)) return .{ .at = end, .kind = .{ .invalid_digit = .{ .c = c, .base = "binary" } } };
        } else if (std.mem.indexOfScalar(u8, if (hex) "pP" else "eE", c) != null) {
            return .{ .at = end, .kind = .exponent_no_digits };
        }
    }
    if (lit.inf) return null;
    const digits = text[0..lit.end];
    if (hex and lit.float and std.mem.indexOfAny(u8, digits, "pP") == null) return .{ .at = end, .kind = .needs_exponent };
    if (lit.float) return null;
    if (!hex and !binary) {
        if (digits.len > 1 and digits[0] == '0') for (digits[1..], 1..) |c, i| if (c >= '8') {
            return .{ .at = @intCast(i), .kind = .{ .invalid_digit = .{ .c = c, .base = "octal" } } };
        };
        // clang: a hex letter after decimal / octal digits (`1f`, `0f`, `07a`).
        if (lit.end < text.len and std.ascii.isHex(text[lit.end])) {
            return .{ .at = end, .kind = .{ .invalid_digit = .{ .c = text[lit.end], .base = if (digits[0] == '0') "octal" else "decimal" } } };
        }
    }
    if (parseDigits(digits) == null) return .{ .at = 0, .kind = .too_large };
    return null;
}

pub fn report(diags: *Diagnostics, loc: Loc, p: Problem) void {
    const at = loc.advance(p.at);
    switch (p.kind) {
        .invalid_suffix => |suffix| diags.err(at, "invalid suffix '{s}' on integer constant", .{suffix}),
        .needs_significand => diags.err(at, "hexadecimal floating constants require a significand", .{}),
        .needs_exponent => diags.err(at, "hexadecimal floating constants require an exponent", .{}),
        .exponent_no_digits => diags.err(at, "exponent has no digits", .{}),
        .invalid_digit => |d| diags.err(at, "invalid digit '{c}' in {s} constant", .{ d.c, d.base }),
        .too_large => diags.err(at, "integer literal is too large to be represented in any integer type", .{}),
    }
}

// -------------------------------------------------------------------------
// Character constants

pub const Char = struct {
    /// Of one character, its value as a (signed) `char`: `'\xff'` is -1.
    /// Of a multi-character constant, the characters shifted into an int.
    value: i64 = 0,
    /// Characters between the quotes: 0 for `''`.
    count: u32 = 0,
    problem: ?struct { at: u32, kind: enum { hex_no_digits, hex_too_large, octal_too_large } } = null,
    /// The first escape that is none (`'\q'`): its value is the character.
    unknown_escape: ?struct { at: u32, c: u8 } = null,
};

/// Reads a character constant token (`'a'`, `'\n'`, `'\x41'`, `'\101'`).
pub fn parseChar(text: []const u8) Char {
    var r: Char = .{};
    const end = if (text.len >= 2 and text[text.len - 1] == '\'') text.len - 1 else text.len;
    var acc: u32 = 0;
    var i: usize = 1;
    while (i < end) {
        const start: u32 = @intCast(i);
        var c: u32 = text[i];
        i += 1;
        if (c == '\\' and i < end) {
            const esc = text[i];
            i += 1;
            c = switch (esc) {
                'a' => 7,
                'b' => 8,
                'e', 'E' => 27, // an extension clang does not warn about by default
                'f' => 12,
                'n' => 10,
                'r' => 13,
                't' => 9,
                'v' => 11,
                'x' => hex: {
                    // A maximal series of hex digits.
                    const first = i;
                    var v: u32 = 0;
                    var overflow = false;
                    while (i < end) : (i += 1) {
                        const d = std.fmt.charToDigit(text[i], 16) catch break;
                        if (v & 0xF000_0000 != 0) overflow = true;
                        v = (v << 4) | d;
                    }
                    if (i == first) {
                        if (r.problem == null) r.problem = .{ .at = start, .kind = .hex_no_digits };
                    } else if (overflow or v > 0xff) {
                        if (r.problem == null) r.problem = .{ .at = start, .kind = .hex_too_large };
                    }
                    break :hex v & 0xff;
                },
                '0'...'7' => octal: {
                    // Up to three octal digits: `'\1011'` is two characters.
                    i -= 1;
                    var v: u32 = 0;
                    var n: u32 = 0;
                    while (i < end and n < 3 and text[i] >= '0' and text[i] <= '7') : ({
                        i += 1;
                        n += 1;
                    }) v = (v << 3) | (text[i] - '0');
                    if (v > 0xff and r.problem == null) r.problem = .{ .at = start, .kind = .octal_too_large };
                    break :octal v & 0xff;
                },
                '\\', '\'', '"', '?', '(', '{', '[', '%' => esc,
                else => unknown: {
                    if (r.unknown_escape == null) r.unknown_escape = .{ .at = start, .c = esc };
                    break :unknown esc;
                },
            };
        }
        acc = (acc << 8) | c;
        r.count += 1;
    }
    r.value = if (r.count == 1) @as(i8, @bitCast(@as(u8, @truncate(acc)))) else @as(i32, @bitCast(acc));
    return r;
}

/// The diagnostics of a character constant that do not depend on where it
/// is used. False if one was an error.
pub fn reportChar(diags: *Diagnostics, loc: Loc, c: Char) bool {
    if (c.problem) |p| {
        const at = loc.advance(p.at);
        switch (p.kind) {
            .hex_no_digits => diags.err(at, "\\x used with no following hex digits", .{}),
            .hex_too_large => diags.err(at, "hex escape sequence out of range", .{}),
            .octal_too_large => diags.err(at, "octal escape sequence out of range", .{}),
        }
        return false;
    }
    if (c.unknown_escape) |u| warn(diags, loc.advance(u.at), "unknown-escape-sequence", "unknown escape sequence '\\{c}'", .{u.c});
    if (c.count == 0) warn(diags, loc, "invalid-pp-token", "empty character constant", .{});
    // (clang takes four characters for a four-char code, without a word.)
    if (c.count > 1 and c.count != 4) warn(diags, loc, "multichar", "multi-character character constant", .{});
    return true;
}

fn warn(diags: *Diagnostics, loc: Loc, group: []const u8, comptime fmt: []const u8, args: anytype) void {
    _ = diags.report(.{ .severity = .warning, .loc = loc, .group = group }, fmt, args);
}

// -------------------------------------------------------------------------
// Tests

test "character constants" {
    const expectEqual = std.testing.expectEqual;
    try expectEqual(@as(i64, 97), parseChar("'a'").value);
    try expectEqual(@as(i64, 10), parseChar("'\\n'").value);
    try expectEqual(@as(i64, 27), parseChar("'\\e'").value);
    try expectEqual(@as(i64, 65), parseChar("'\\x41'").value);
    try expectEqual(@as(i64, 65), parseChar("'\\101'").value);
    try expectEqual(@as(i64, 0), parseChar("'\\0'").value);
    // A `char` is signed.
    try expectEqual(@as(i64, -1), parseChar("'\\xff'").value);
    try expectEqual(@as(i64, -1), parseChar("'\\377'").value);
    try expectEqual(@as(u32, 0), parseChar("''").count);
    try expectEqual(@as(u32, 2), parseChar("'ab'").count);
    try expectEqual(@as(i64, 0x6162), parseChar("'ab'").value);
    try expectEqual(@as(u32, 2), parseChar("'\\1011'").count);
    try std.testing.expect(parseChar("'\\x'").problem.?.kind == .hex_no_digits);
    try std.testing.expect(parseChar("'\\x141'").problem.?.kind == .hex_too_large);
    try std.testing.expect(parseChar("'\\400'").problem.?.kind == .octal_too_large);
    try expectEqual(@as(u8, 'q'), parseChar("'\\q'").unknown_escape.?.c);
    try expectEqual(@as(i64, 'q'), parseChar("'\\q'").value);
}

test "integer suffixes" {
    for ([_][]const u8{ "", "u", "U", "l", "L", "ul", "LU", "ll", "LL", "ull", "LLu", "uLL", "llU" }) |s| try std.testing.expect(isIntSuffix(s));
    for ([_][]const u8{ "lL", "Ll", "ulL", "uu", "lul", "lll", "f", "i" }) |s| try std.testing.expect(!isIntSuffix(s));
}
