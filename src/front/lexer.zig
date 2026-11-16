//! HLSL lexer producing preprocessing tokens. Keywords are not distinguished
//! here; the parser classifies identifiers.

const std = @import("std");
const source = @import("source.zig");
const scan = @import("scan.zig");
const unicode = @import("unicode.zig");
const diag = @import("../diag.zig");
const Diagnostics = diag.Diagnostics;

pub const Kind = enum(u8) {
    eof,
    /// Unlexable input (stray character, unterminated literal).
    invalid,
    identifier,
    /// pp-number: integer and floating literals with suffixes.
    number,
    string,
    char,
    /// Produced by the preprocessor for `#pragma` lines; text holds the
    /// pragma body.
    pragma,
    /// End of a directive: the newline (or end of input) ending its line,
    /// in directive mode (`Lexer.beginDirective`). Empty, at the newline.
    eod,

    l_paren,
    r_paren,
    l_brace,
    r_brace,
    l_square,
    r_square,
    semi,
    comma,
    colon,
    colon_colon,
    question,
    period,
    ellipsis,
    arrow,
    plus,
    plus_plus,
    plus_equal,
    minus,
    minus_minus,
    minus_equal,
    star,
    star_equal,
    slash,
    slash_equal,
    percent,
    percent_equal,
    amp,
    amp_amp,
    amp_equal,
    pipe,
    pipe_pipe,
    pipe_equal,
    caret,
    caret_equal,
    tilde,
    exclaim,
    exclaim_equal,
    equal,
    equal_equal,
    less,
    less_equal,
    less_less,
    less_less_equal,
    greater,
    greater_equal,
    greater_greater,
    greater_greater_equal,
    hash,
    hash_hash,

    pub fn isPunct(k: Kind) bool {
        return @backingInt(k) >= @backingInt(Kind.l_paren);
    }
};

pub const Flags = packed struct(u8) {
    /// First token on its (physical) line.
    bol: bool = false,
    /// Preceded by whitespace or a comment.
    space: bool = false,
    /// Painted by the preprocessor: never macro-expand this identifier.
    no_expand: bool = false,
    /// Transient, during macro substitution: the token came from an argument.
    from_arg: bool = false,
    /// An identifier whose universal character names `text` spells in
    /// UTF-8; the source spelling (for `#`) is `ucn_len` bytes at `loc`.
    ucn: bool = false,
    _: u3 = 0,
};

pub const Token = struct {
    kind: Kind,
    flags: Flags = .{},
    /// Spelling. Points into the source text, or into preprocessor-owned
    /// memory for tokens created by `#` and `##`.
    text: []const u8,
    loc: source.Loc,
    /// With `flags.ucn`: the length of the source spelling, which is longer
    /// than `text`. (It fits in what would be padding.)
    ucn_len: u32 = 0,

    /// Length of the token as written in the source, for diagnostics.
    pub fn sourceLen(t: Token) u32 {
        return if (t.flags.ucn) t.ucn_len else @intCast(t.text.len);
    }

    pub fn is(t: Token, kind: Kind) bool {
        return t.kind == kind;
    }

    pub inline fn isIdent(t: Token, name: []const u8) bool {
        // Length first: most keyword checks fail on it without a call.
        return t.kind == .identifier and t.text.len == name.len and std.mem.eql(u8, t.text, name);
    }
};

pub const Lexer = struct {
    text: []const u8,
    file: source.FileId,
    pos: u32 = 0,
    at_bol: bool = true,
    /// Owns the UTF-8 spelling of identifiers written with universal
    /// character names (`\u03b1` is spelled `α`, as dxc names it); null
    /// keeps them as written.
    names: ?std.mem.Allocator = null,
    /// Diagnostics for stray Unicode; null lexes raw.
    sink: ?*Sink = null,
    /// Directive mode, from `beginDirective` to the `.eod` token that ends
    /// the line: the lexer does not go past the line's newline.
    in_directive: bool = false,
    /// The token being lexed needs a second look: it has a universal
    /// character name, or a backslash that is not one. (False at the start
    /// of every token.)
    unusual: bool = false,

    /// What a file the preprocessor reads reports to. Unicode whitespace is
    /// skipped with a warning, and outside directives a character that
    /// cannot start a token is dropped with an error, as dxc does (raw
    /// lexing keeps either as an `.invalid` token). Every token is lexed
    /// once, so each problem is reported once.
    pub const Sink = struct {
        diags: *Diagnostics,
        /// In a skipped group: nothing is diagnosed.
        quiet: bool = false,
        /// Preprocessed output (-P): stray Unicode is kept as tokens, and
        /// only bad universal character names are diagnosed.
        passthrough: bool = false,
    };

    pub fn init(text: []const u8, file: source.FileId) Lexer {
        return .{ .text = text, .file = file };
    }

    /// Stray Unicode is kept as tokens.
    fn raw(l: *const Lexer) bool {
        const sink = l.sink orelse return true;
        return sink.passthrough;
    }

    /// Enter directive mode for the rest of the current line (the
    /// preprocessor has read the `#` starting a directive): the line ends
    /// with an `.eod` token, after which the lexer leaves directive mode.
    pub fn beginDirective(l: *Lexer) void {
        l.in_directive = true;
    }

    /// Where to report a diagnostic about stray Unicode at the current
    /// position, if anywhere.
    fn reportTo(l: *const Lexer) ?*Sink {
        const sink = l.reportUcnTo() orelse return null;
        if (sink.passthrough) return null;
        return sink;
    }

    /// Where to report a bad universal character name, if anywhere: unlike
    /// stray Unicode, it is diagnosed in preprocessed output too, as by dxc.
    fn reportUcnTo(l: *const Lexer) ?*Sink {
        const sink = l.sink orelse return null;
        if (sink.quiet) return null;
        return sink;
    }

    fn report(l: *Lexer, sink: *Sink, severity: diag.Severity, len: u32, group: ?[]const u8, comptime fmt: []const u8, args: anytype) void {
        _ = sink.diags.report(.{ .severity = severity, .loc = .{ .file = l.file, .offset = l.pos }, .len = len, .group = group }, fmt, args);
    }

    fn peekAt(l: *const Lexer, i: usize) u8 {
        return if (i < l.text.len) l.text[i] else 0;
    }

    /// Skip whitespace and comments; report whether any was seen and whether
    /// a newline was crossed. In directive mode, stops at a newline.
    fn skipTrivia(l: *Lexer) struct { space: bool, newline: bool } {
        var space = false;
        var newline = false;
        while (l.pos < l.text.len) {
            const c = l.text[l.pos];
            switch (c) {
                ' ', '\t', '\r', 0x0b, 0x0c => {
                    space = true;
                    l.pos += 1;
                },
                '\n' => {
                    if (l.in_directive) break; // lexed as `.eod`
                    newline = true;
                    space = false;
                    l.pos += 1;
                },
                0x80...0xff, '\\' => switch (l.unicodeTrivia()) {
                    .space => space = true,
                    .dropped => {},
                    .token => break,
                },
                '/' => {
                    const n = l.peekAt(l.pos + 1);
                    if (n == '/') {
                        l.pos = @intCast(scan.findNewline(l.text, l.pos + 2));
                        space = true;
                    } else if (n == '*') {
                        // A newline inside a block comment does not start a
                        // new line for directive purposes (the comment is one
                        // space after translation phase 3). An unterminated
                        // comment runs to EOF.
                        l.pos = @intCast(scan.skipBlockComment(l.text, l.pos + 2));
                        space = true;
                    } else break;
                },
                else => break,
            }
        }
        return .{ .space = space, .newline = newline };
    }

    pub fn next(l: *Lexer) Token {
        const trivia = l.skipTrivia();
        if (trivia.newline) l.at_bol = true;
        var flags: Flags = .{ .bol = l.at_bol, .space = trivia.space };
        if (l.at_bol) flags.space = false;
        l.at_bol = false;
        const start = l.pos;
        const kind = l.lexToken();
        var t: Token = .{
            .kind = kind,
            .flags = flags,
            .text = l.text[start..l.pos],
            .loc = .{ .file = l.file, .offset = start },
        };
        if (l.unusual) if (l.unusualToken(kind, t.text, start)) |utf8| {
            t.text = utf8;
            t.flags.ucn = true;
            t.ucn_len = l.pos - start;
        };
        return t;
    }

    /// The UTF-8 spelling of an identifier with universal character names,
    /// or null to keep the source spelling; an invalid token is diagnosed
    /// if it is a bad universal character name.
    noinline fn unusualToken(l: *Lexer, kind: Kind, text: []const u8, start: u32) ?[]const u8 {
        @branchHint(.cold);
        defer l.unusual = false;
        if (kind == .identifier) {
            const names = l.names orelse return null;
            // (Out of memory keeps the spelling; the allocator's owner
            // fails on its next allocation.)
            return unicode.ucnsToUtf8(names, text) catch null;
        }
        if (kind == .invalid and text[0] == '\\') l.diagnoseUcn(start);
        return null;
    }

    /// At a non-ASCII byte or backslash in trivia: Unicode whitespace, a
    /// dropped character, or the start of a token.
    noinline fn unicodeTrivia(l: *Lexer) enum { space, dropped, token } {
        @branchHint(.cold);
        if (l.text[l.pos] == '\\') return if (l.skipUcnWhitespace()) .space else .token;
        if (l.skipUnicode()) return .space;
        return if (l.dropNonAscii()) .dropped else .token;
    }

    /// At a non-ASCII byte in trivia: skip Unicode whitespace (with a
    /// warning), unless lexing raw.
    fn skipUnicode(l: *Lexer) bool {
        if (l.raw()) return false;
        const d = unicode.decodeUtf8(l.text, l.pos) orelse return false;
        if (!unicode.isWhitespace(d.cp)) return false;
        l.skipWhitespace(d.len);
        return true;
    }

    /// At a backslash in trivia: skip a universal character name for
    /// Unicode whitespace (with a warning), unless lexing raw.
    fn skipUcnWhitespace(l: *Lexer) bool {
        if (l.raw()) return false;
        const u = unicode.decodeUcn(l.text, l.pos) orelse return false;
        if (!unicode.isWhitespace(u.cp)) return false;
        l.skipWhitespace(u.len);
        return true;
    }

    fn skipWhitespace(l: *Lexer, len: u32) void {
        if (l.reportTo()) |sink| l.report(sink, .warning, len, "unicode-whitespace", "treating Unicode character as whitespace", .{});
        l.pos += len;
    }

    /// At a non-ASCII byte that is not whitespace, outside directives and
    /// unless lexing raw: drop it with an error unless it starts an
    /// identifier (dxc drops it rather than letting the parser trip over
    /// it). Malformed UTF-8 drops a byte.
    fn dropNonAscii(l: *Lexer) bool {
        if (l.raw() or l.in_directive) return false;
        const decoded = unicode.decodeUtf8(l.text, l.pos);
        if (decoded) |d| if (unicode.isIdentCodepoint(d.cp)) return false;
        const len: u32, const msg = if (decoded) |d|
            .{ d.len, "non-ASCII characters are not allowed outside of literals and identifiers" }
        else
            .{ 1, "source file is not valid UTF-8" };
        if (l.reportTo()) |sink| l.report(sink, .@"error", len, null, "{s}", .{msg});
        l.pos += len;
        return true;
    }

    /// At a backslash lexed as an invalid token: dxc's diagnostics for a
    /// universal character name that is not one. A complete name past
    /// U+10FFFF, or for a character that cannot be in an identifier
    /// (`\u00D7`), is left undiagnosed, as by clang: the parser reports the
    /// tokens it becomes.
    fn diagnoseUcn(l: *Lexer, at: u32) void {
        const e = unicode.scanEscape(l.text, at) orelse return;
        const save = l.pos;
        defer l.pos = save;
        l.pos = at;
        const sink = l.reportUcnTo() orelse return;
        const len = e.len();
        const v = e.value;
        if (e.digits == 0) {
            l.report(sink, .warning, 1, "unicode", "\\{c} used with no following hex digits; treating as '\\' followed by identifier", .{l.text[at + 1]});
        } else if (!e.complete()) {
            l.report(sink, .warning, 1, "unicode", "incomplete universal character name; treating as '\\' followed by identifier", .{});
        } else if (v >= 0xD800 and v <= 0xDFFF) {
            l.report(sink, .warning, len, "unicode", "universal character name refers to a surrogate character", .{});
        } else if (v < 0x20 or (v >= 0x7F and v < 0xA0)) {
            l.report(sink, .@"error", len, null, "universal character name refers to a control character", .{});
        } else if (v < 0x7F and v != '$' and v != '@' and v != '`') {
            l.report(sink, .@"error", len, null, "character '{c}' cannot be specified by a universal character name", .{@as(u8, @intCast(v))});
        }
    }

    /// Rest of the current line, used for `#error`, `#pragma` and similar.
    /// Leaves the lexer at the newline, out of directive mode.
    pub fn restOfLine(l: *Lexer) []const u8 {
        l.in_directive = false;
        const start = l.pos;
        while (l.pos < l.text.len and l.text[l.pos] != '\n') {
            // Block comments may contain newlines; skip them as a unit.
            if (l.text[l.pos] == '/' and l.peekAt(l.pos + 1) == '*') {
                if (std.mem.indexOfPos(u8, l.text, l.pos + 2, "*/")) |end| {
                    l.pos = @intCast(end + 2);
                    continue;
                }
            }
            if (l.text[l.pos] == '/' and l.peekAt(l.pos + 1) == '/') {
                const s = l.text[start..l.pos];
                while (l.pos < l.text.len and l.text[l.pos] != '\n') l.pos += 1;
                return std.mem.trim(u8, s, " \t\r");
            }
            l.pos += 1;
        }
        return std.mem.trim(u8, l.text[start..l.pos], " \t\r");
    }

    /// After `#include` (in directive mode), lex `<...>` as a header name.
    /// Returns null if the next token does not start with `<`.
    pub fn headerName(l: *Lexer) ?Token {
        std.debug.assert(l.in_directive);
        const trivia = l.skipTrivia();
        if (l.peekAt(l.pos) != '<') return null;
        const start = l.pos;
        var i = l.pos + 1;
        while (i < l.text.len and l.text[i] != '>' and l.text[i] != '\n') i += 1;
        if (i >= l.text.len or l.text[i] != '>') return null;
        l.pos = @intCast(i + 1);
        return .{ .kind = .string, .flags = .{ .space = trivia.space }, .text = l.text[start..l.pos], .loc = .{ .file = l.file, .offset = start } };
    }

    /// Skip the rest of the current line, through its `.eod` (used for
    /// skipped conditional blocks and after directives). Works token by
    /// token so that `/*` or `//` inside string literals is not mistaken
    /// for a comment.
    pub fn skipLine(l: *Lexer) void {
        l.beginDirective();
        while (l.next().kind != .eod) {}
    }

    /// The `.eod` ending directive mode, at a newline (left for the next
    /// token to cross, which starts a line) or the end of input.
    fn endDirective(l: *Lexer) Kind {
        l.in_directive = false;
        return .eod;
    }

    fn lexToken(l: *Lexer) Kind {
        if (l.pos >= l.text.len) return if (l.in_directive) l.endDirective() else .eof;
        const c = l.text[l.pos];
        l.pos += 1;
        switch (c) {
            // (Only reached in directive mode: trivia skips it otherwise.)
            '\n' => {
                l.pos -= 1;
                return l.endDirective();
            },
            'a'...'z', 'A'...'Z', '_' => {
                l.lexIdentRest();
                return .identifier;
            },
            0x80...0xff, '\\' => return l.lexUnicodeStart(c),
            '0'...'9' => {
                l.lexPpNumber();
                return .number;
            },
            '.' => {
                if (std.ascii.isDigit(l.peekAt(l.pos))) {
                    l.lexPpNumber();
                    return .number;
                }
                if (l.peekAt(l.pos) == '.' and l.peekAt(l.pos + 1) == '.') {
                    l.pos += 2;
                    return .ellipsis;
                }
                return .period;
            },
            '"' => return l.lexQuoted('"', .string),
            '\'' => return l.lexQuoted('\'', .char),
            '(' => return .l_paren,
            ')' => return .r_paren,
            '{' => return .l_brace,
            '}' => return .r_brace,
            '[' => return .l_square,
            ']' => return .r_square,
            ';' => return .semi,
            ',' => return .comma,
            '?' => return .question,
            '~' => return .tilde,
            ':' => return if (l.eat(':')) .colon_colon else .colon,
            '+' => return if (l.eat('+')) .plus_plus else if (l.eat('=')) .plus_equal else .plus,
            '-' => return if (l.eat('-')) .minus_minus else if (l.eat('=')) .minus_equal else if (l.eat('>')) .arrow else .minus,
            '*' => return if (l.eat('=')) .star_equal else .star,
            '/' => return if (l.eat('=')) .slash_equal else .slash,
            '%' => return if (l.eat('=')) .percent_equal else .percent,
            '&' => return if (l.eat('&')) .amp_amp else if (l.eat('=')) .amp_equal else .amp,
            '|' => return if (l.eat('|')) .pipe_pipe else if (l.eat('=')) .pipe_equal else .pipe,
            '^' => return if (l.eat('=')) .caret_equal else .caret,
            '!' => return if (l.eat('=')) .exclaim_equal else .exclaim,
            '=' => return if (l.eat('=')) .equal_equal else .equal,
            '#' => return if (l.eat('#')) .hash_hash else .hash,
            '<' => {
                if (l.eat('<')) return if (l.eat('=')) .less_less_equal else .less_less;
                return if (l.eat('=')) .less_equal else .less;
            },
            '>' => {
                if (l.eat('>')) return if (l.eat('=')) .greater_greater_equal else .greater_greater;
                return if (l.eat('=')) .greater_equal else .greater;
            },
            else => return .invalid,
        }
    }

    /// After a non-ASCII byte or a backslash that starts a token: an
    /// identifier, or an invalid token.
    noinline fn lexUnicodeStart(l: *Lexer, c: u8) Kind {
        @branchHint(.cold);
        const start = l.pos - 1;
        const ucn = c == '\\';
        if (ucn) l.unusual = true;
        const d = (if (ucn) unicode.decodeUcn(l.text, start) else unicode.decodeUtf8(l.text, start)) orelse return .invalid;
        // A character that cannot start an identifier is a token by itself;
        // a backslash before such a universal character name is one alone.
        const ident = unicode.isIdentCodepoint(d.cp);
        if (ident or !ucn) l.pos = @intCast(start + d.len);
        if (!ident) return .invalid;
        l.lexIdentRest();
        return .identifier;
    }

    /// The rest of an identifier: ASCII identifier characters, and the
    /// Unicode ones spelled in UTF-8 or as universal character names.
    fn lexIdentRest(l: *Lexer) void {
        while (true) {
            l.pos = @intCast(scan.skipIdent(l.text, l.pos));
            if (!l.eatUnicodeIdentChar()) return;
        }
    }

    /// Consume one non-ASCII identifier character, if one is next.
    inline fn eatUnicodeIdentChar(l: *Lexer) bool {
        const c = l.peekAt(l.pos);
        if (!maybe_unicode[c]) return false;
        return l.eatUnicodeIdentCharSlow(c);
    }

    noinline fn eatUnicodeIdentCharSlow(l: *Lexer, c: u8) bool {
        @branchHint(.cold);
        if (c >= 0x80) {
            const d = unicode.decodeUtf8(l.text, l.pos) orelse return false;
            if (!unicode.isIdentCodepoint(d.cp)) return false;
            l.pos += d.len;
            return true;
        }
        if (c == '\\') {
            const u = unicode.decodeUcn(l.text, l.pos) orelse return false;
            if (!unicode.isIdentCodepoint(u.cp)) return false;
            l.pos += u.len;
            l.unusual = true;
            return true;
        }
        return false;
    }

    fn eat(l: *Lexer, c: u8) bool {
        if (l.peekAt(l.pos) == c) {
            l.pos += 1;
            return true;
        }
        return false;
    }

    fn lexPpNumber(l: *Lexer) void {
        while (l.pos < l.text.len) {
            const c = l.text[l.pos];
            if ((c == '+' or c == '-') and l.pos > 0) {
                const p = l.text[l.pos - 1];
                if (p == 'e' or p == 'E' or p == 'p' or p == 'P') {
                    l.pos += 1;
                    continue;
                }
                break;
            }
            // dxc also takes '#' (for `1.#INF`).
            if (isIdentChar(c) or c == '.' or c == '#') {
                l.pos += 1;
                continue;
            }
            if (l.eatUnicodeIdentChar()) continue;
            break;
        }
    }

    fn lexQuoted(l: *Lexer, quote: u8, kind: Kind) Kind {
        while (l.pos < l.text.len) {
            const c = l.text[l.pos];
            if (c == '\n') return .invalid;
            l.pos += 1;
            if (c == '\\' and l.pos < l.text.len) {
                l.pos += 1;
                continue;
            }
            if (c == quote) return kind;
        }
        return .invalid;
    }
};

/// Bytes that may start a non-ASCII identifier character: UTF-8 lead and
/// continuation bytes, and the backslash of a universal character name.
const maybe_unicode: [256]bool = blk: {
    var t: [256]bool = @splat(false);
    for (0x80..0x100) |c| t[c] = true;
    t['\\'] = true;
    break :blk t;
};

pub fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

fn expectKinds(text: []const u8, kinds: []const Kind) !void {
    var l = Lexer.init(text, 0);
    for (kinds) |k| try std.testing.expectEqual(k, l.next().kind);
    try std.testing.expectEqual(Kind.eof, l.next().kind);
}

test "punctuators and literals" {
    try expectKinds("a+=b<<=c>>1.5e-3f", &.{ .identifier, .plus_equal, .identifier, .less_less_equal, .identifier, .greater_greater, .number });
    try expectKinds("x::y->z...", &.{ .identifier, .colon_colon, .identifier, .arrow, .identifier, .ellipsis });
    try expectKinds("\"a\\\"b\" 'c' .5h 0x1Fu", &.{ .string, .char, .number, .number });
    try expectKinds("1.#INF.xxx -1.#INF", &.{ .number, .minus, .number });
    try expectKinds("# ## #x", &.{ .hash, .hash_hash, .hash, .identifier });
}

test "skipLine ignores comment markers inside strings" {
    var l = Lexer.init("x = \"/*\"; y\n#endif\n", 0);
    l.skipLine();
    const t = l.next();
    try std.testing.expect(t.kind == .hash and t.flags.bol);
}

test "comments, flags and lines" {
    var l = Lexer.init("a /* x\n y */ b // c\n  c", 0);
    const a = l.next();
    try std.testing.expect(a.flags.bol);
    const b = l.next();
    try std.testing.expect(!b.flags.bol and b.flags.space);
    const c = l.next();
    try std.testing.expect(c.flags.bol);
    try std.testing.expectEqualStrings("c", c.text);
}

test "Unicode identifiers" {
    // UTF-8 and universal character names, starting or continuing one.
    try expectKinds("αβ+速度 x\\u03b1y \\U000003B1", &.{ .identifier, .plus, .identifier, .identifier, .identifier });
    try expectKinds("1α", &.{.number});
    // Raw lexing keeps what cannot be in an identifier as tokens.
    try expectKinds("x\u{1F600} x\u{301} ×", &.{ .identifier, .invalid, .identifier, .invalid, .invalid });
    try expectKinds("x\xff", &.{ .identifier, .invalid });
    try expectKinds("x\\u0301 \\u03b", &.{ .identifier, .invalid, .identifier, .invalid, .identifier });
    var l = Lexer.init("x\u{1F600}", 0);
    try std.testing.expectEqualStrings("x", l.next().text);
    try std.testing.expectEqualStrings("\u{1F600}", l.next().text);
}

test "directive mode ends at the line's newline with .eod" {
    var l = Lexer.init("# define A 1 /* x\n y */ 2 // c\nB\n#x", 0);
    try std.testing.expectEqual(Kind.hash, l.next().kind);
    l.beginDirective();
    for ([_][]const u8{ "define", "A", "1", "2" }) |s| try std.testing.expectEqualStrings(s, l.next().text);
    const eod = l.next();
    try std.testing.expectEqual(Kind.eod, eod.kind);
    try std.testing.expectEqual(@as(usize, 0), eod.text.len);
    // The next line starts a line, as if the lexer had never stopped.
    const b = l.next();
    try std.testing.expect(b.isIdent("B") and b.flags.bol);
    try std.testing.expect(l.next().flags.bol);
    // At the end of input, .eod comes before .eof.
    l.beginDirective();
    try std.testing.expectEqual(Kind.identifier, l.next().kind);
    try std.testing.expectEqual(Kind.eod, l.next().kind);
    try std.testing.expectEqual(Kind.eof, l.next().kind);
    // An empty directive is just its .eod.
    var e = Lexer.init("#\nx", 0);
    _ = e.next();
    e.beginDirective();
    try std.testing.expectEqual(Kind.eod, e.next().kind);
    try std.testing.expect(e.next().flags.bol);
}

test "an identifier with universal character names keeps its source length" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var l = Lexer.init("x\\u03b1\\U000003B2 y", 0);
    l.names = arena.allocator();
    const t = l.next();
    try std.testing.expectEqualStrings("x\u{3B1}\u{3B2}", t.text);
    try std.testing.expectEqual(@as(u32, 17), t.sourceLen());
    try std.testing.expectEqual(@as(u32, 1), l.next().sourceLen());
    // The length takes what would otherwise be padding.
    try std.testing.expectEqual(@as(usize, 32), @sizeOf(Token));
}
