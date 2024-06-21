//! Image encoders written from scratch: binary PPM and PNG (zlib "stored"
//! blocks, so no compression library is needed).
const std = @import("std");
const render = @import("render.zig");

pub fn writePpm(image: render.Image, writer: anytype) !void {
    try writer.print("P6\n{d} {d}\n255\n", .{ image.width, image.height });
    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        var x: usize = 0;
        while (x < image.width) : (x += 1) {
            try writer.writeAll(&image.rgb8(x, y));
        }
    }
}

const crc_table = blk: {
    @setEvalBranchQuota(10000);
    var table: [256]u32 = undefined;
    for (&table, 0..) |*entry, n| {
        var c: u32 = @intCast(n);
        var k: usize = 0;
        while (k < 8) : (k += 1) {
            c = if (c & 1 != 0) 0xEDB88320 ^ (c >> 1) else c >> 1;
        }
        entry.* = c;
    }
    break :blk table;
};

pub fn crc32(data: []const u8) u32 {
    var c: u32 = 0xFFFFFFFF;
    for (data) |b| c = crc_table[(c ^ b) & 0xFF] ^ (c >> 8);
    return c ^ 0xFFFFFFFF;
}

pub fn adler32(data: []const u8) u32 {
    var a: u32 = 1;
    var b: u32 = 0;
    for (data) |byte| {
        a = (a + byte) % 65521;
        b = (b + a) % 65521;
    }
    return (b << 16) | a;
}

fn writeChunk(writer: anytype, kind: *const [4]u8, data: []const u8) !void {
    var len: [4]u8 = undefined;
    std.mem.writeInt(u32, &len, @intCast(data.len), .big);
    try writer.writeAll(&len);
    try writer.writeAll(kind);
    try writer.writeAll(data);
    var crc_input = std.ArrayList(u8).init(std.heap.page_allocator);
    defer crc_input.deinit();
    try crc_input.appendSlice(kind);
    try crc_input.appendSlice(data);
    var crc: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc, crc32(crc_input.items), .big);
    try writer.writeAll(&crc);
}

/// Encodes the image as an 8-bit RGB PNG. The pixel data is wrapped in a
/// zlib stream made of uncompressed ("stored") deflate blocks of up to 65535
/// bytes, which every PNG reader accepts.
pub fn writePng(allocator: std.mem.Allocator, image: render.Image, writer: anytype) !void {
    try writer.writeAll(&[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' });

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], @intCast(image.width), .big);
    std.mem.writeInt(u32, ihdr[4..8], @intCast(image.height), .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 2; // colour type RGB
    ihdr[10] = 0; // compression
    ihdr[11] = 0; // filter
    ihdr[12] = 0; // interlace
    try writeChunk(writer, "IHDR", &ihdr);

    // raw scanlines, each prefixed with filter type 0
    var raw = std.ArrayList(u8).init(allocator);
    defer raw.deinit();
    var y: usize = 0;
    while (y < image.height) : (y += 1) {
        try raw.append(0);
        var x: usize = 0;
        while (x < image.width) : (x += 1) try raw.appendSlice(&image.rgb8(x, y));
    }

    var zlib = std.ArrayList(u8).init(allocator);
    defer zlib.deinit();
    try zlib.appendSlice(&[_]u8{ 0x78, 0x01 }); // zlib header: deflate, no dictionary
    var offset: usize = 0;
    while (offset < raw.items.len or raw.items.len == 0) {
        const remaining = raw.items.len - offset;
        const block_len: usize = @min(remaining, 65535);
        const last: u8 = if (offset + block_len >= raw.items.len) 1 else 0;
        try zlib.append(last); // BFINAL bit, BTYPE = 00 (stored)
        var len_bytes: [2]u8 = undefined;
        std.mem.writeInt(u16, &len_bytes, @intCast(block_len), .little);
        try zlib.appendSlice(&len_bytes);
        std.mem.writeInt(u16, &len_bytes, @intCast(~@as(u16, @intCast(block_len))), .little);
        try zlib.appendSlice(&len_bytes);
        try zlib.appendSlice(raw.items[offset .. offset + block_len]);
        offset += block_len;
        if (raw.items.len == 0) break;
    }
    var adler: [4]u8 = undefined;
    std.mem.writeInt(u32, &adler, adler32(raw.items), .big);
    try zlib.appendSlice(&adler);

    try writeChunk(writer, "IDAT", zlib.items);
    try writeChunk(writer, "IEND", &[_]u8{});
}

test "crc32 and adler32 match known values" {
    try std.testing.expectEqual(@as(u32, 0xCBF43926), crc32("123456789"));
    try std.testing.expectEqual(@as(u32, 0x11E60398), adler32("Wikipedia"));
}

test "png encoder writes a well formed file" {
    const allocator = std.testing.allocator;
    var image = try render.Image.init(allocator, 3, 2);
    defer image.deinit();
    image.pixels[0] = .{ .x = 1, .y = 0, .z = 0 };
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try writePng(allocator, image, out.writer());
    const bytes = out.items;
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1A, '\n' }, bytes[0..8]);
    try std.testing.expectEqualSlices(u8, "IHDR", bytes[12..16]);
    try std.testing.expectEqual(@as(u32, 3), std.mem.readInt(u32, bytes[16..20], .big));
    try std.testing.expectEqual(@as(u32, 2), std.mem.readInt(u32, bytes[20..24], .big));
    // the IHDR crc covers type + data
    try std.testing.expectEqual(crc32(bytes[12..29]), std.mem.readInt(u32, bytes[29..33], .big));
    try std.testing.expectEqualSlices(u8, "IEND", bytes[bytes.len - 8 .. bytes.len - 4]);
    // decode our own zlib stream with the standard library to prove it is valid
    const idat_len = std.mem.readInt(u32, bytes[33..37], .big);
    const idat = bytes[41 .. 41 + idat_len];
    var stream = std.io.fixedBufferStream(idat);
    var decompressor = std.compress.zlib.decompressor(stream.reader());
    const decoded = try decompressor.reader().readAllAlloc(allocator, 1 << 16);
    defer allocator.free(decoded);
    try std.testing.expectEqual(@as(usize, 2 * (1 + 3 * 3)), decoded.len);
    try std.testing.expectEqualSlices(u8, &[_]u8{ 0, 255, 0, 0 }, decoded[0..4]);
}

test "ppm header" {
    const allocator = std.testing.allocator;
    var image = try render.Image.init(allocator, 2, 1);
    defer image.deinit();
    var out = std.ArrayList(u8).init(allocator);
    defer out.deinit();
    try writePpm(image, out.writer());
    try std.testing.expectEqualSlices(u8, "P6\n2 1\n255\n", out.items[0..11]);
    try std.testing.expectEqual(@as(usize, 11 + 6), out.items.len);
}
