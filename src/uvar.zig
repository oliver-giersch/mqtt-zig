//! The type as well as encoding and decoding facilities for a
//! "variable length integer" (uvar) as defined by the MQTT specification.

const Self = @This();

const mqtt = @import("mqtt.zig");

/// The maximum value for an uvar.
pub const max: u28 = ~@as(u28, 0);

/// The number of bits of the value part of each individual byte.
const bits = 7;
/// The mask for the continuation bit.
const cont_bit: u8 = 1 << bits;
/// The mask for the value part of each individual byte.
const mask = ~cont_bit;

comptime {
    mqtt.assert(max == 0x0fffffff);
    mqtt.assert(mask == 0x7f);
}

/// The set of all possible errors when decoding a variable length integer.
pub const DecodeError = mqtt.InvalidUvar || mqtt.IncompleteBuffer;

/// The byte representation of an `mqtt.uvar`.
pub const Bytes = struct {
    pub const zero = Bytes{ .arr = @splat(0) };

    arr: [4]u8,

    pub fn slice(self: *const Bytes) []const u8 {
        const len = self.count();
        return self.arr[0..len];
    }

    fn count(self: Bytes) u3 {
        const b1, const b2, const b3 = self.arr[1..].*;
        return if ((b1 | b2 | b3) == 0)
            1
        else if ((b2 | b3) == 0)
            2
        else if (b3 == 0)
            3
        else
            4;
    }
};

/// The decoded value of a variable length integer.
val: u28,

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
        bytes[i] = @truncate(num & mask);
        num >>= bits;

        if (num == 0)
            break;

        bytes[i] |= cont_bit;
    }

    return .{ .arr = bytes };
}

pub fn decode(buf: []const u8) DecodeError!struct { Self, usize } {
    const avail = @min(buf.len, 4);

    var val: u28 = 0;
    var i: u5 = 0;

    while (i < avail) {
        const byte: u28 = buf[i];
        if (i > 0 and byte == 0)
            return error.InvalidValue;

        val += (byte & mask) << (bits * i);
        i += 1;

        if (byte & cont_bit == 0)
            return .{ Self{ .val = val }, i };
    }

    return if (avail == 4) error.InvalidValue else error.IncompleteBuffer;
}

const tt = @import("std").testing;

test "encode uvar" {
    var uvar = mqtt.uvar{ .val = 0x0 };
    try tt.expectEqualSlices(u8, &.{0x0}, uvar.encode().slice());
    uvar = mqtt.uvar{ .val = 0x1 };
    try tt.expectEqualSlices(u8, &.{0x1}, uvar.encode().slice());
    uvar = mqtt.uvar{ .val = 0x7F };
    try tt.expectEqualSlices(u8, &.{0x7F}, uvar.encode().slice());
    uvar = mqtt.uvar{ .val = 0x80 };
    try tt.expectEqualSlices(u8, &.{ 0x80, 0x1 }, uvar.encode().slice());
    uvar = mqtt.uvar{ .val = 0x3FFF };
    try tt.expectEqualSlices(u8, &.{ 0xFF, 0x7F }, uvar.encode().slice());
}

test "decode uvar (0 byte)" {
    try tt.expectError(DecodeError.IncompleteBuffer, decode(&.{}));
}

test "decode uvar (1 byte)" {
    var uvar, var bytes = try decode(&.{0});
    try tt.expectEqual(mqtt.uvar{ .val = 0 }, uvar);
    try tt.expectEqual(1, bytes);

    uvar, bytes = try decode(&.{1});
    try tt.expectEqual(mqtt.uvar{ .val = 1 }, uvar);
    try tt.expectEqual(1, bytes);

    uvar, bytes = try decode(&.{100});
    try tt.expectEqual(mqtt.uvar{ .val = 100 }, uvar);
    try tt.expectEqual(1, bytes);

    uvar, bytes = try decode(&.{mqtt.uvar.mask});
    try tt.expectEqual(mqtt.uvar{ .val = mqtt.uvar.mask }, uvar);
    try tt.expectEqual(1, bytes);

    const err = decode(&.{mqtt.uvar.mask + 1});
    try tt.expectError(error.IncompleteBuffer, err);
}

test "decode uvar (2 byte)" {
    var uvar: mqtt.uvar = undefined;
    var bytes: usize = undefined;

    uvar, bytes = try decode(&.{ 1, 0 });
    try tt.expectEqual(mqtt.uvar{ .val = 1 }, uvar);
    try tt.expectEqual(1, bytes);

    var err = decode(&.{ 128, 0 });
    try tt.expectError(error.InvalidValue, err);

    err = decode(&.{ 128, 128 });
    try tt.expectError(error.IncompleteBuffer, err);

    uvar, bytes = try decode(&.{ 0xc1, 0x2 });
    try tt.expectEqual(mqtt.uvar{ .val = 321 }, uvar);
    try tt.expectEqual(2, bytes);
}

test "decode uvar (4 byte)" {
    var uvar: mqtt.uvar = undefined;
    var bytes: usize = undefined;

    uvar, bytes = try decode(&.{ 0xff, 0xff, 0xff, 0x7f });
    try tt.expectEqual(mqtt.uvar.max, uvar.val);
    try tt.expectEqual(4, bytes);

    const err = decode(&.{ 0xff, 0xff, 0xff, 0xff });
    try tt.expectError(error.InvalidValue, err);
}
