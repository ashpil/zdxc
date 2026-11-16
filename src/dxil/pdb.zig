//! The PDB of a shader: an MSF file whose stream 5 is a DXIL container
//! with the debug parts, as dxc's lib/DXIL/DxilPDB.cpp writes it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const block_size = 512;
const magic = "Microsoft C/C++ MSF 7.00\r\n\x1aDS\x00\x00\x00";

fn blocksFor(size: usize) u32 {
    return @intCast((size + block_size - 1) / block_size);
}

/// A PDB holding `debug_container`; `digest` (the shader's hash) is its
/// identity. Owned by the caller.
pub fn write(gpa: Allocator, debug_container: []const u8, digest: [16]u8) ![]u8 {
    // The PDB information stream: version (VC70), signature, age, the
    // identity and an empty name table.
    var info: [28 + 7 * 4]u8 = @splat(0);
    std.mem.writeInt(u32, info[0..4], 20000404, .little);
    std.mem.writeInt(u32, info[8..12], 1, .little);
    @memcpy(info[12..28], &digest);
    std.mem.writeInt(u32, info[28 + 8 ..][0..4], 1, .little); // capacity

    // Streams: the old directory, the PDB information, TPI, DBI, IPI (all
    // empty but the second) and the container.
    const streams = [_][]const u8{ "", &info, "", "", "", debug_container };
    var stream_blocks: u32 = 0;
    for (streams) |s| stream_blocks += blocksFor(s.len);
    const dir_bytes: u32 = @intCast(4 + streams.len * 4 + @as(usize, stream_blocks) * 4);
    const dir_blocks = blocksFor(dir_bytes);
    const addr_blocks = blocksFor(@as(usize, dir_blocks) * 4);
    // The superblock, two free block maps, the directory's block
    // addresses, the directory, the streams.
    const block_map = 3;
    const dir_start = block_map + addr_blocks;
    const stream_start = dir_start + dir_blocks;
    const total = stream_start + stream_blocks;

    const out = try gpa.alloc(u8, @as(usize, total) * block_size);
    @memset(out, 0);
    @memcpy(out[0..magic.len], magic);
    const sb = out[magic.len..];
    std.mem.writeInt(u32, sb[0..4], block_size, .little);
    std.mem.writeInt(u32, sb[4..8], 1, .little); // free block map
    // (As dxc: the count leaves out the blocks of the address table.)
    std.mem.writeInt(u32, sb[8..12], 3 + stream_blocks + dir_blocks, .little);
    std.mem.writeInt(u32, sb[12..16], dir_bytes, .little);
    std.mem.writeInt(u32, sb[20..24], block_map, .little);

    for (0..dir_blocks) |k| {
        std.mem.writeInt(u32, out[block_map * block_size + k * 4 ..][0..4], @intCast(dir_start + k), .little);
    }
    var at: usize = @as(usize, dir_start) * block_size;
    std.mem.writeInt(u32, out[at..][0..4], streams.len, .little);
    at += 4;
    for (streams) |s| {
        std.mem.writeInt(u32, out[at..][0..4], @intCast(s.len), .little);
        at += 4;
    }
    var block: u32 = stream_start;
    for (streams) |s| for (0..blocksFor(s.len)) |_| {
        std.mem.writeInt(u32, out[at..][0..4], block, .little);
        at += 4;
        block += 1;
    };
    at = @as(usize, stream_start) * block_size;
    for (streams) |s| {
        @memcpy(out[at..][0..s.len], s);
        at += @as(usize, blocksFor(s.len)) * block_size;
    }
    return out;
}

test "the container is stream 5" {
    const gpa = std.testing.allocator;
    const data: []const u8 = &@as([700]u8, @splat('x'));
    const out = try write(gpa, data, @splat(7));
    defer gpa.free(out);
    try std.testing.expectEqual(@as(usize, 0), out.len % block_size);
    try std.testing.expectEqualSlices(u8, magic, out[0..magic.len]);
    // Directory: 6 streams, the last 700 bytes in two blocks.
    const dir = out[4 * block_size ..];
    try std.testing.expectEqual(@as(u32, 6), std.mem.readInt(u32, dir[0..4], .little));
    try std.testing.expectEqual(@as(u32, 700), std.mem.readInt(u32, dir[4 + 5 * 4 ..][0..4], .little));
    const first = std.mem.readInt(u32, dir[4 + 6 * 4 + 4 ..][0..4], .little);
    try std.testing.expectEqualSlices(u8, data[0..block_size], out[first * block_size ..][0..block_size]);
}
