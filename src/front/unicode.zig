//! Unicode in source text: which characters may appear in identifiers,
//! which count as whitespace, and decoding of UTF-8 and universal character
//! names (`α`, `\U000003B1`).
//!
//! dxc lexes HLSL as clang does C++03: identifiers take the characters of
//! C++03's [extendid] annex (Latin, Greek, Cyrillic, ..., CJK), the same set
//! at the start of an identifier as after it. The table below was read off
//! dxc 1.10 by compiling every code point at both positions.

const std = @import("std");

const Range = struct { u21, u21 };

/// Non-ASCII code points allowed in identifiers, sorted.
const ident_ranges = [_]Range{
    .{ 0x00C0, 0x00D6 }, .{ 0x00D8, 0x00F6 }, .{ 0x00F8, 0x01F5 }, .{ 0x01FA, 0x0217 },
    .{ 0x0250, 0x02A8 }, .{ 0x0384, 0x0384 }, .{ 0x0388, 0x038A }, .{ 0x038C, 0x038C },
    .{ 0x038E, 0x03A1 }, .{ 0x03A3, 0x03CE }, .{ 0x03D0, 0x03D6 }, .{ 0x03DA, 0x03DA },
    .{ 0x03DC, 0x03DC }, .{ 0x03DE, 0x03DE }, .{ 0x03E0, 0x03E0 }, .{ 0x03E2, 0x03F3 },
    .{ 0x0401, 0x040D }, .{ 0x040F, 0x044F }, .{ 0x0451, 0x045C }, .{ 0x045E, 0x0481 },
    .{ 0x0490, 0x04C4 }, .{ 0x04C7, 0x04C8 }, .{ 0x04CB, 0x04CC }, .{ 0x04D0, 0x04EB },
    .{ 0x04EE, 0x04F5 }, .{ 0x04F8, 0x04F9 }, .{ 0x0531, 0x0556 }, .{ 0x0561, 0x0587 },
    .{ 0x05D0, 0x05EA }, .{ 0x05F0, 0x05F4 }, .{ 0x0621, 0x063A }, .{ 0x0640, 0x0652 },
    .{ 0x0670, 0x06B7 }, .{ 0x06BA, 0x06BE }, .{ 0x06C0, 0x06CE }, .{ 0x06E5, 0x06E7 },
    .{ 0x0905, 0x0939 }, .{ 0x0958, 0x0962 }, .{ 0x0985, 0x098C }, .{ 0x098F, 0x0990 },
    .{ 0x0993, 0x09A8 }, .{ 0x09AA, 0x09B0 }, .{ 0x09B2, 0x09B2 }, .{ 0x09B6, 0x09B9 },
    .{ 0x09DC, 0x09DD }, .{ 0x09DF, 0x09E1 }, .{ 0x09F0, 0x09F1 }, .{ 0x0A05, 0x0A0A },
    .{ 0x0A0F, 0x0A10 }, .{ 0x0A13, 0x0A28 }, .{ 0x0A2A, 0x0A30 }, .{ 0x0A32, 0x0A33 },
    .{ 0x0A35, 0x0A36 }, .{ 0x0A38, 0x0A39 }, .{ 0x0A59, 0x0A5C }, .{ 0x0A5E, 0x0A5E },
    .{ 0x0A85, 0x0A8B }, .{ 0x0A8D, 0x0A8D }, .{ 0x0A8F, 0x0A91 }, .{ 0x0A93, 0x0AA8 },
    .{ 0x0AAA, 0x0AB0 }, .{ 0x0AB2, 0x0AB3 }, .{ 0x0AB5, 0x0AB9 }, .{ 0x0AE0, 0x0AE0 },
    .{ 0x0B05, 0x0B0C }, .{ 0x0B0F, 0x0B10 }, .{ 0x0B13, 0x0B28 }, .{ 0x0B2A, 0x0B30 },
    .{ 0x0B32, 0x0B33 }, .{ 0x0B36, 0x0B39 }, .{ 0x0B5C, 0x0B5D }, .{ 0x0B5F, 0x0B61 },
    .{ 0x0B85, 0x0B8A }, .{ 0x0B8E, 0x0B90 }, .{ 0x0B92, 0x0B95 }, .{ 0x0B99, 0x0B9A },
    .{ 0x0B9C, 0x0B9C }, .{ 0x0B9E, 0x0B9F }, .{ 0x0BA3, 0x0BA4 }, .{ 0x0BA8, 0x0BAA },
    .{ 0x0BAE, 0x0BB5 }, .{ 0x0BB7, 0x0BB9 }, .{ 0x0C05, 0x0C0C }, .{ 0x0C0E, 0x0C10 },
    .{ 0x0C12, 0x0C28 }, .{ 0x0C2A, 0x0C33 }, .{ 0x0C35, 0x0C39 }, .{ 0x0C60, 0x0C61 },
    .{ 0x0C85, 0x0C8C }, .{ 0x0C8E, 0x0C90 }, .{ 0x0C92, 0x0CA8 }, .{ 0x0CAA, 0x0CB3 },
    .{ 0x0CB5, 0x0CB9 }, .{ 0x0CE0, 0x0CE1 }, .{ 0x0D05, 0x0D0C }, .{ 0x0D0E, 0x0D10 },
    .{ 0x0D12, 0x0D28 }, .{ 0x0D2A, 0x0D39 }, .{ 0x0D60, 0x0D61 }, .{ 0x0E01, 0x0E30 },
    .{ 0x0E32, 0x0E33 }, .{ 0x0E40, 0x0E46 }, .{ 0x0E4F, 0x0E5B }, .{ 0x0E81, 0x0E82 },
    .{ 0x0E84, 0x0E84 }, .{ 0x0E87, 0x0E88 }, .{ 0x0E8A, 0x0E8A }, .{ 0x0E8D, 0x0E8D },
    .{ 0x0E94, 0x0E97 }, .{ 0x0E99, 0x0E9F }, .{ 0x0EA1, 0x0EA3 }, .{ 0x0EA5, 0x0EA5 },
    .{ 0x0EA7, 0x0EA7 }, .{ 0x0EAA, 0x0EAB }, .{ 0x0EAD, 0x0EB0 }, .{ 0x0EB2, 0x0EB3 },
    .{ 0x0EBD, 0x0EBD }, .{ 0x0EC0, 0x0EC4 }, .{ 0x0EC6, 0x0EC6 }, .{ 0x10A0, 0x10C5 },
    .{ 0x10D0, 0x10F6 }, .{ 0x1100, 0x1159 }, .{ 0x1161, 0x11A2 }, .{ 0x11A8, 0x11F9 },
    .{ 0x1E00, 0x1E9A }, .{ 0x1EA0, 0x1EF9 }, .{ 0x1F00, 0x1F15 }, .{ 0x1F18, 0x1F1D },
    .{ 0x1F20, 0x1F45 }, .{ 0x1F48, 0x1F4D }, .{ 0x1F50, 0x1F57 }, .{ 0x1F59, 0x1F59 },
    .{ 0x1F5B, 0x1F5B }, .{ 0x1F5D, 0x1F5D }, .{ 0x1F5F, 0x1F7D }, .{ 0x1F80, 0x1FB4 },
    .{ 0x1FB6, 0x1FBC }, .{ 0x1FC2, 0x1FC4 }, .{ 0x1FC6, 0x1FCC }, .{ 0x1FD0, 0x1FD3 },
    .{ 0x1FD6, 0x1FDB }, .{ 0x1FE0, 0x1FEC }, .{ 0x1FF2, 0x1FF4 }, .{ 0x1FF6, 0x1FFC },
    .{ 0x3041, 0x3094 }, .{ 0x309B, 0x309E }, .{ 0x30A1, 0x30FE }, .{ 0x3105, 0x312C },
    .{ 0x4E00, 0x9FA5 }, .{ 0xF900, 0xFA2D }, .{ 0xFB1F, 0xFB36 }, .{ 0xFB38, 0xFB3C },
    .{ 0xFB3E, 0xFB3E }, .{ 0xFB40, 0xFB44 }, .{ 0xFB46, 0xFBB1 }, .{ 0xFBD3, 0xFD3F },
    .{ 0xFD50, 0xFD8F }, .{ 0xFD92, 0xFDC7 }, .{ 0xFDF0, 0xFDFB }, .{ 0xFE70, 0xFE72 },
    .{ 0xFE74, 0xFE74 }, .{ 0xFE76, 0xFEFC }, .{ 0xFF21, 0xFF3A }, .{ 0xFF41, 0xFF5A },
    .{ 0xFF66, 0xFFBE }, .{ 0xFFC2, 0xFFC7 }, .{ 0xFFCA, 0xFFCF }, .{ 0xFFD2, 0xFFD7 },
    .{ 0xFFDA, 0xFFDC },
};

/// Whether `cp` (non-ASCII) may appear in an identifier.
pub fn isIdentCodepoint(cp: u21) bool {
    if (cp < ident_ranges[0][0]) return false;
    var lo: usize = 0;
    var hi: usize = ident_ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        const r = ident_ranges[mid];
        if (cp < r[0]) hi = mid else if (cp > r[1]) lo = mid + 1 else return true;
    }
    return false;
}

/// Non-ASCII whitespace, which dxc skips with a warning
/// (-Wunicode-whitespace).
pub fn isWhitespace(cp: u21) bool {
    return switch (cp) {
        0x0085, 0x00A0, 0x1680, 0x180E, 0x2000...0x200A, 0x2028, 0x2029, 0x202F, 0x205F, 0x3000 => true,
        else => false,
    };
}

pub const Decoded = struct { cp: u21, len: u4 };

/// The UTF-8 sequence starting at `text[i]`, or null if it is malformed
/// (truncated, overlong, a surrogate, or past U+10FFFF).
pub fn decodeUtf8(text: []const u8, i: usize) ?Decoded {
    const len = std.unicode.utf8ByteSequenceLength(text[i]) catch return null;
    if (i + len > text.len) return null;
    const cp = std.unicode.utf8Decode(text[i..][0..len]) catch return null;
    return .{ .cp = cp, .len = len };
}

/// The universal character name starting at `text[i]` (a backslash), or
/// null if there is none: `\u` and four hex digits or `\U` and eight.
/// Surrogates and values past U+10FFFF are not character names.
pub fn decodeUcn(text: []const u8, i: usize) ?Decoded {
    if (i + 1 >= text.len or text[i] != '\\') return null;
    const digits: u4 = switch (text[i + 1]) {
        'u' => 4,
        'U' => 8,
        else => return null,
    };
    if (i + 2 + digits > text.len) return null;
    var v: u32 = 0;
    for (text[i + 2 ..][0..digits]) |h| v = v * 16 + (std.fmt.charToDigit(h, 16) catch return null);
    if (v > 0x10FFFF or (v >= 0xD800 and v <= 0xDFFF)) return null;
    return .{ .cp = @intCast(v), .len = 2 + digits };
}

/// An identifier's spelling with its universal character names written as
/// UTF-8 (the spelling dxc gives the identifier).
pub fn ucnsToUtf8(gpa: std.mem.Allocator, spelling: []const u8) ![]const u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, spelling.len);
    var i: usize = 0;
    while (i < spelling.len) {
        if (decodeUcn(spelling, i)) |u| {
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(u.cp, &buf) catch unreachable;
            out.appendSliceAssumeCapacity(buf[0..n]); // never longer than the UCN
            i += u.len;
        } else {
            out.appendAssumeCapacity(spelling[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(gpa);
}

test "identifier code points" {
    try std.testing.expect(isIdentCodepoint(0x03B1)); // α
    try std.testing.expect(isIdentCodepoint(0x4E00)); // 一
    try std.testing.expect(isIdentCodepoint(0x00C0));
    try std.testing.expect(isIdentCodepoint(0xFFDC));
    try std.testing.expect(!isIdentCodepoint(0x00D7)); // ×
    try std.testing.expect(!isIdentCodepoint(0x0301)); // combining acute
    try std.testing.expect(!isIdentCodepoint(0x0661)); // Arabic-Indic one
    try std.testing.expect(!isIdentCodepoint(0x1F600)); // emoji
    try std.testing.expect(!isIdentCodepoint(0xAC00)); // Hangul syllables: not in the set
    for (ident_ranges[1..], 1..) |r, i| try std.testing.expect(r[0] > ident_ranges[i - 1][1] + 1);
}

test "universal character names" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Decoded{ .cp = 0x3B1, .len = 6 }, decodeUcn("\\u03b1", 0).?);
    try std.testing.expectEqual(Decoded{ .cp = 0x3B1, .len = 10 }, decodeUcn("\\U000003B1", 0).?);
    try std.testing.expect(decodeUcn("\\u03b", 0) == null);
    try std.testing.expect(decodeUcn("\\ud800", 0) == null);
    try std.testing.expect(decodeUcn("\\U00110000", 0) == null);
    const s = try ucnsToUtf8(a, "x\\u03b1\\U000003B2y");
    defer a.free(s);
    try std.testing.expectEqualStrings("xαβy", s);
}
