//! The type as well as encoding and decoding facilities for a
//! "variable length integer" (uvar) as defined by the MQTT specification.

const mqtt = @import("mqtt.zig");

const Self = @This();

/// The maximum value for an uvar.
pub const max: u28 = ~@as(u28, 0);

/// The number of bits of the value part of each individual byte.
const bits = 7;
/// The mask for the continuation bit.
const continuation_bit: u8 = 1 << bits;
/// The mask for the value part of each individual byte.
const value_mask = ~continuation_bit;

const uvar_align = @alignOf(Self);

comptime {
    mqtt.assert(max == 0x0fffffff);
    mqtt.assert(value_mask == 0x7f);
}

/// The set of all possible errors when decoding a variable length integer.
pub const DecodeError = mqtt.InvalidUvar || mqtt.IncompleteBuffer;

/// The byte representation of an `mqtt.uvar`.
pub const Bytes = struct {
    pub const zero = Bytes{ .array = @splat(0) };

    /// The underlying 4-byte array.
    array: [4]u8 align(uvar_align),

    pub fn slice(self: *const Bytes) []const u8 {
        const len = self.count();
        return self.array[0..len];
    }

    fn count(self: Bytes) usize {
        const ptr: *const u32 = @ptrCast(&self.array);
        const lz: usize = @clz(ptr.*);
        return @max(1, @sizeOf(u32) - (lz / 8));
    }
};

/// The decoded value of a variable length integer.
val: u28,

pub fn castUsize(self: Self) if (mqtt.is_16bit) ?usize else usize {
    if (!comptime mqtt.is_16bit)
        return @as(usize, self.val);

    // On a 16-bit CPU, the value may not fit into an `usize`.
    const max_u16: u28 = ~@as(u16, 0);
    return if (self.val <= max_u16)
        @intCast(self.val)
    else
        null;
}

/// Returns the number of bytes required to encode the value.
pub fn encodedBytes(self: Self) u3 {
    return switch (self.val) {
        0x000000...0x00007F => 1,
        0x000080...0x003FFF => 2,
        0x004000...0x1FFFFF => 3,
        0x200000...max => 4,
    };
}

/// Encodes the value into its byte representation.
pub fn encode(self: Self) Bytes {
    var bytes: [4]u8 = @splat(0);
    var num = self.val;

    for (0..4) |i| {
        bytes[i] = @truncate(num & value_mask);
        num >>= bits;

        if (num == 0)
            break;

        bytes[i] |= continuation_bit;
    }

    return .{ .array = bytes };
}

/// Decodes the variable length integer stored in the given buffer.
///
/// Returns the decoded value and the count of bytes (between 1 and 4) it takes
/// up in the buffer.
pub fn decode(buf: []const u8) DecodeError!struct { Self, usize } {
    var val: u28 = 0;
    var i: u4 = 0;

    const avail = @min(buf.len, 4);
    while (i < avail) {
        const byte: u28 = buf[i];
        if (i > 0 and byte == 0)
            return error.InvalidValue;

        const shift: u5 = bits * @as(u5, i);
        val += (byte & value_mask) << shift;
        i += 1;

        if (byte & continuation_bit == 0)
            return .{ Self{ .val = val }, i };
    }

    return if (avail == 4)
        error.InvalidValue
    else
        error.IncompleteBuffer;
}

const testing = @import("std").testing;

test "bytes count" {
    var bytes: Bytes = .zero;

    try testing.expectEqual(1, bytes.count());
    bytes.array[0] = 0xFF;
    try testing.expectEqual(1, bytes.count());
    bytes.array[1] = 0xFF;
    try testing.expectEqual(2, bytes.count());
    bytes.array[2] = 0xFF;
    try testing.expectEqual(3, bytes.count());
    bytes.array[3] = 0xFF;
    try testing.expectEqual(4, bytes.count());
    bytes.array[0] = 0;
    try testing.expectEqual(4, bytes.count());
}

test "encode uvar" {
    var uvar = mqtt.uvar{ .val = 0x0 };
    try testing.expectEqualSlices(u8, &.{0x0}, uvar.encode().slice());
    uvar = mqtt.uvar{ .val = 0x1 };
    try testing.expectEqualSlices(u8, &.{0x1}, uvar.encode().slice());
    uvar = mqtt.uvar{ .val = 0x7F };
    try testing.expectEqualSlices(u8, &.{0x7F}, uvar.encode().slice());
    uvar = mqtt.uvar{ .val = 0x80 };
    try testing.expectEqualSlices(u8, &.{ 0x80, 0x1 }, uvar.encode().slice());
    uvar = mqtt.uvar{ .val = 0x3FFF };
    try testing.expectEqualSlices(u8, &.{ 0xFF, 0x7F }, uvar.encode().slice());
}

test "decode uvar (0 byte)" {
    try testing.expectError(DecodeError.IncompleteBuffer, decode(&.{}));
}

test "decode uvar (1 byte)" {
    var uvar, var bytes = try decode(&.{0});
    try testing.expectEqual(mqtt.uvar{ .val = 0 }, uvar);
    try testing.expectEqual(1, bytes);

    uvar, bytes = try decode(&.{1});
    try testing.expectEqual(mqtt.uvar{ .val = 1 }, uvar);
    try testing.expectEqual(1, bytes);

    uvar, bytes = try decode(&.{100});
    try testing.expectEqual(mqtt.uvar{ .val = 100 }, uvar);
    try testing.expectEqual(1, bytes);

    uvar, bytes = try decode(&.{mqtt.uvar.value_mask});
    try testing.expectEqual(mqtt.uvar{ .val = mqtt.uvar.value_mask }, uvar);
    try testing.expectEqual(1, bytes);

    const err = decode(&.{mqtt.uvar.value_mask + 1});
    try testing.expectError(error.IncompleteBuffer, err);
}

test "decode uvar (2 byte)" {
    var uvar: mqtt.uvar = undefined;
    var bytes: usize = undefined;

    uvar, bytes = try decode(&.{ 1, 0 });
    try testing.expectEqual(mqtt.uvar{ .val = 1 }, uvar);
    try testing.expectEqual(1, bytes);

    var err = decode(&.{ 128, 0 });
    try testing.expectError(error.InvalidValue, err);

    err = decode(&.{ 128, 128 });
    try testing.expectError(error.IncompleteBuffer, err);

    uvar, bytes = try decode(&.{ 0xc1, 0x2 });
    try testing.expectEqual(mqtt.uvar{ .val = 321 }, uvar);
    try testing.expectEqual(2, bytes);
}

test "decode uvar (4 byte)" {
    var uvar: mqtt.uvar = undefined;
    var bytes: usize = undefined;

    uvar, bytes = try decode(&.{ 0xff, 0xff, 0xff, 0x7f });
    try testing.expectEqual(mqtt.uvar.max, uvar.val);
    try testing.expectEqual(4, bytes);

    const err = decode(&.{ 0xff, 0xff, 0xff, 0xff });
    try testing.expectError(error.InvalidValue, err);
}
