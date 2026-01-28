const mqtt = @import("mqtt.zig");

pub const max_len = 0xffff;

const ascii_mask = 0x80;
const word_size: usize = @sizeOf(usize);
const ascii_word_mask = block: {
    var mask: usize = 0;
    for (0..word_size) |i|
        mask |= @as(usize, ascii_mask << (i * @bitSizeOf(u8)));
    break :block mask;
};

pub const DecodeError = error{ InvalidUtf8, InternalNull };

pub fn validateLength(buf: []const u8) !void {
    if (buf.len > max_len)
        return error.InvalidStringLength;
}

pub fn validate(buf: []const u8) DecodeError!void {
    const len = buf.len;

    var curr: [*]const u8 = buf.ptr;
    const end = curr + len;
    const block_end = blockEnd(4 * word_size, end);

    while (curr != end) {
        ascii: {
            simd: {
                // Validate individual bytes until pointer is word aligned.
                const aligned = wordAlign(curr);
                while (curr != aligned) {
                    if (try checkByte(curr[0]) == .non_ascii)
                        break :ascii;

                    curr += 1;

                    if (curr == end)
                        return;
                }

                // Perform blockwise validation with vectorization.
                const words = block: {
                    if (try checkBlock(4, &curr, block_end) == .non_ascii)
                        break :block 4;
                    break :simd;
                };

                const block: [*]const usize = @alignCast(@ptrCast(curr));
                const pos = findNonAsciiPos(words, block[0..words]);
                curr += pos;

                break :ascii;
            }

            while (true) {
                curr += 1;
                if (curr == end)
                    return;
                if (try checkByte(curr[0]) == .non_ascii)
                    break :ascii;
            }
        }

        try checkUtf8Codepoint(&curr, end);
    }
}

const Result = enum {
    ok,
    non_ascii,
};

fn checkBlock(comptime words: usize, curr: *[*]const u8, block_end: [*]const u8) !Result {
    const chunk_size = words * word_size;
    const Chunk = @Vector(chunk_size, u8);

    while (@intFromPtr(curr.*) < @intFromPtr(block_end)) {
        const chunk: Chunk = curr.*[0..@sizeOf(Chunk)].*;
        var mask: Chunk = @splat(ascii_mask);
        if (@reduce(.Or, chunk & mask == mask))
            return .non_ascii;
        mask = @splat(0xff);
        if (@reduce(.Or, chunk & mask == @as(Chunk, @splat(0))))
            return error.InternalNull;

        curr.* += @sizeOf(Chunk);
    }

    return .ok;
}

fn findNonAsciiPos(comptime words: usize, block: *const [words]usize) usize {
    for (block, 0..) |word, i| {
        const tz = @ctz(word & ascii_word_mask);
        if (tz < @bitSizeOf(usize)) {
            const byte = tz / word_size;
            return byte + (i * word_size);
        }
    }

    unreachable;
}

fn checkUtf8Codepoint(curr: *[*]const u8, end: [*]const u8) !void {
    const byte = curr.*[0];
    switch (utf8Width(byte)) {
        2 => {
            if (try nextSigned(curr, end) >= -64)
                return error.InvalidUtf8;
        },
        3 => {
            const n = try next(curr, end);
            switch (byte) {
                0xE0 => if (!(0xA0 <= n and n <= 0xBF))
                    return error.InvalidUtf8,
                0xE1...0xEC => if (!(0x80 <= n and n <= 0xBF))
                    return error.InvalidUtf8,
                0xED => if (!(0x80 <= n and n <= 0x9F))
                    return error.InvalidUtf8,
                0xEE...0xEF => if (!(0x80 <= n and n <= 0xBF))
                    return error.InvalidUtf8,
                else => return error.InvalidUtf8,
            }

            if (try nextSigned(curr, end) >= -64)
                return error.InvalidUtf8;
        },
        4 => {
            const n = try next(curr, end);
            switch (byte) {
                0xF0 => if (!(0x90 <= n and n <= 0xBF))
                    return error.InvalidUtf8,
                0xF1...0xF3 => if (!(0x80 <= n and n <= 0xBF))
                    return error.InvalidUtf8,
                0xF4 => if (!(0x90 <= n and n <= 0xBF))
                    return error.InvalidUtf8,
                else => return error.InvalidUtf8,
            }

            if (try nextSigned(curr, end) >= -64)
                return error.InvalidUtf8;
            if (try nextSigned(curr, end) >= -64)
                return error.InvalidUtf8;
        },
        else => return error.InvalidUtf8,
    }
}

inline fn checkByte(byte: u8) !Result {
    if (byte >= ascii_mask) {
        return .non_ascii;
    } else if (byte != 0) {
        return .ok;
    } else {
        @branchHint(.cold);
        return error.InternalNull;
    }
}

inline fn wordAlign(ptr: [*]const u8) [*]const u8 {
    const addr: usize = @intFromPtr(ptr);
    return @ptrFromInt((addr + word_size - 1) & ~(word_size - 1));
}

inline fn blockEnd(comptime block_size: usize, end: [*]const u8) [*]const u8 {
    return @ptrCast(end - block_size + 1);
}

inline fn utf8Width(byte: u8) usize {
    const width_table: [256]u8 = .{
        // 1  2  3  4  5  6  7  8  9  A  B  C  D  E  F
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 0
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 1
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 2
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 3
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 4
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 5
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 6
        1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, 1, // 7
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 8
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // 9
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // A
        0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // B
        0, 0, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // C
        2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, 2, // D
        3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, 3, // E
        4, 4, 4, 4, 4, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, // F
    };

    return width_table[byte];
}

inline fn next(curr: *[*]const u8, end: [*]const u8) !u8 {
    curr.* += 1;
    if (curr.* == end)
        return error.InvalidUtf8;
    return curr.*[0];
}

inline fn nextSigned(curr: *[*]const u8, end: [*]const u8) !i8 {
    const n = try next(curr, end);
    return @bitCast(n);
}

test "utf-8 validation" {
    const str = "MQTT";
    try mqtt.string.validate(str);
}
