const mqtt = @This();

pub const decode = @import("decode.zig");
pub const encode = @import("encode.zig");
pub const string = @import("string.zig");
pub const topic = @import("topic.zig");
pub const uvar = @import("uvar.zig");
pub const v3_11 = @import("v3_11.zig");
pub const v5_00 = @import("v5_00.zig");

pub const Decoder = @import("decoder.zig");
pub const Encoder = @import("encoder.zig");

pub const target_endian = @import("builtin").target.cpu.arch.endian();
pub const is_16bit = @bitSizeOf(usize) <= 16;

pub const KeepAlive = enum(u16) {
    unlimited = 0,
    _,
};

/// The non-zero ID of an MQTT packet.
pub const PacketID = enum(u16) {
    invalid = 0,
    _,

    /// Returns a valid packet ID or an error.
    pub fn from(val: u16) InvalidPacketID!PacketID {
        const id: PacketID = @enumFromInt(val);
        return if (id != .invalid) id else error.InvalidPacketID;
    }

    /// Returns the non-zero packet ID or null.
    pub fn get(self: PacketID) ?u16 {
        return if (self == .invalid) null else @intFromEnum(self);
    }
};

/// The header contents (fixed and variable) of an MQTT message.
pub const Header = struct {
    /// The encoded format of the fixed header byte.
    pub const Byte = packed struct(u8) {
        msg_flags: mqtt.MessageFlags,
        msg_type: mqtt.MessageType,
    };

    msg_flags: mqtt.MessageFlags,
    msg_type: mqtt.MessageType,
    remaining_len: mqtt.uvar,

    /// Returns the length in bytes of the MQTT message.
    pub fn packetLen(self: *const mqtt.Header) mqtt.InvalidSize!usize {
        return if (comptime mqtt.is_16bit)
            self.remaining_len.castUsize() orelse return error.PacketTooLarge
        else
            self.remaining_len.castUsize();
    }
};

/// The MQTT protocol version.
pub const Version = enum(u8) {
    /// The MQTT v3.1.1 identifier.
    v3_11 = 4,
    /// The MQTT v5 identifier.
    v5 = 5,
};

/// The type of an MQTT message.
pub const MessageType = enum(u4) {
    /// The CONNECT message code.
    connect = 1,
    /// The CONNACK message code.
    connack = 2,
    /// The PUBLISH message code.
    publish = 3,
    /// The PUBACK message code.
    puback = 4,
    /// The PUBREC message code.
    pubrec = 5,
    pubrel = 6,
    pubcomp = 7,
    subscribe = 8,
    suback = 9,
    unsubscribe = 10,
    unsuback = 11,
    pingreq = 12,
    pingresp = 13,
    disconnect = 14,
    auth = 15,

    /// Returns an uppercase string for the given message type.
    pub inline fn string(self: MessageType) []const u8 {
        switch (self) {
            inline else => |tag| comptime {
                const tag_name = @tagName(tag);
                var buf: [tag_name.len:0]u8 = undefined;
                @memcpy(&buf, tag_name);
                for (&buf) |*c|
                    c.* = toUpper(c.*);
                buf[buf.len] = 0;
                const result = buf;
                return &result;
            },
        }
    }
};

/// The flags of an MQTT message header.
pub const MessageFlags = packed struct(u4) {
    retain: bool = false,
    qos: mqtt.Qos = .at_most_once,
    dup: bool = false,

    pub fn eql(a: MessageFlags, b: MessageFlags) bool {
        return a.retain == b.retain and a.qos == b.qos and a.dup == b.dup;
    }

    pub inline fn requiredFor(msg_type: MessageType) ?MessageFlags {
        return switch (msg_type) {
            .publish => null,
            .pubrel, .subscribe, .unsubscribe => .{ .qos = .at_least_once },
            else => .{},
        };
    }
};

/// The "quality of service" for an MQTT message transmission.
pub const Qos = enum(u2) {
    pub const @"0" = Qos.at_most_once;
    pub const @"1" = Qos.at_least_once;
    pub const @"2" = Qos.exactly_once;

    at_most_once = 0,
    at_least_once = 1,
    exactly_once = 2,

    pub fn get(self: Qos) u2 {
        return @intFromEnum(self);
    }
};

/// The last will of an MQTT client as declared in its CONNECT message.
pub const Will = struct {
    retain: bool,
    qos: mqtt.Qos,
    topic: []const u8,
    payload: []const u8,
};

/// The authentication data for an MQTT connect message.
pub const Auth = union(enum) {
    /// Authentication by user name only.
    user_only: []const u8,
    /// Authentication by user name and password.
    full: struct {
        user: []const u8,
        pass: []const u8,
    },

    pub fn strings(self: Auth) struct { []const u8, ?[]const u8 } {
        return switch (self) {
            .user_only => |user| .{ user, null },
            .full => |full| .{ full.user, full.pass },
        };
    }
};

/// The flags of an CONNECT message.
pub const ConnectFlags = packed struct(u8) {
    reserved: u1 = 0,
    clean_session: bool,
    will_flag: bool,
    will_qos: mqtt.Qos,
    will_retain: bool,
    pass_flag: bool,
    user_flag: bool,
};

pub const Subscribe = struct {
    packet_id: mqtt.PacketId,
};

pub fn NumberedPacket(comptime msg_type: mqtt.MessageType) type {
    return struct {
        const _ = msg_type;
        packet_id: mqtt.PacketId,
    };
}

pub const IncompleteBuffer = error{IncompleteBuffer};
pub const PacketLengthMismatch = error{PacketLengthMismatch};
pub const PacketTooLarge = error{PacketTooLarge};

pub const InvalidBool = error{InvalidBool};
pub const InvalidMessageType = error{InvalidMessageType};
pub const InvalidMessageFlags = error{InvalidFlags} || InvalidQos;
pub const InvalidMessageHeader = InvalidMessageType || InvalidMessageFlags;
pub const InvalidVersion = error{ InvalidProtocolName, InvalidProtocolVersion };
pub const InvalidPacketID = error{InvalidPacketID};
pub const InvalidStringLength = error{InvalidStringLength};
pub const InvalidQos = error{InvalidQos};
pub const InvalidUvar = error{InvalidValue};

pub const InvalidSize = if (is_16bit) PacketTooLarge else error{};

pub fn validateClientId(client_id: []const u8, strict: bool) !void {
    const valid_chars = "0123456789abcdefghijklmnopqrstuvwxyz";

    if (!strict)
        return;

    if (client_id.len > 23)
        return error.IdTooLong;

    outer: for (client_id) |c| {
        const lower = mqtt.toLower(c);
        for (valid_chars) |v| {
            if (lower == v)
                continue :outer;
        }
        return error.InvalidCharacter;
    }

    return;
}

// Helper and utility functions

const enable_assertions = true; // fixme: get from build options

pub fn assert(ok: bool) void {
    if (comptime enable_assertions)
        if (!ok) unreachable;
}

pub fn debugAssert(ok: bool) void {
    if (comptime @import("builtin").mode == .Debug) {
        if (!ok) unreachable;
    }
}

/// A re-export of `std.mem.eql(u8, a, b)`.
pub inline fn eql(a: []const u8, b: []const u8) bool {
    return @import("std").mem.eql(u8, a, b);
}

pub inline fn toLower(char: u8) u8 {
    return char | @as(u8, 1 << 5);
}

pub inline fn toUpper(char: u8) u8 {
    return char & ~@as(u8, 1 << 5);
}

pub fn reverseBytes(bytes: []u8) void {
    const len = bytes.len;
    for (0..(len / 2)) |i| {
        const tmp = bytes[len - i - 1];
        bytes[len - i - 1] = bytes[i];
        bytes[i] = tmp;
    }
}

const testing = @import("std").testing;

test {
    _ = decode;
    _ = encode;
    _ = string;
    _ = topic;
    _ = uvar;
    _ = v3_11;
    _ = v5_00;

    _ = Decoder;
    _ = Encoder;
}

test "reverse bytes" {
    var bytes: [4]u8 = .{ 0, 1, 2, 3 };
    mqtt.reverseBytes(&bytes);
    try testing.expectEqualSlices(u8, &.{ 3, 2, 1, 0 }, &bytes);
}

test "msg type string" {
    try testing.expectEqualStrings("CONNECT", MessageType.connect.string());
    try testing.expectEqualStrings("CONNACK", MessageType.connack.string());
    try testing.expectEqualStrings("AUTH", MessageType.auth.string());
}

test "decode CONNECT message" {
    const buf: []const u8 = &.{
        0x10, 0x10, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04,
        0x02, 0x00, 0x3c, 0x00, 0x04, 0x44, 0x49, 0x47, 0x49,
    };

    var streaming = mqtt.Decoder.streaming(buf);
    const header = try streaming.splitHeader(.connect);

    try testing.expectEqual(.connect, header.msg_type);
    try testing.expectEqual(16, header.remaining_len.val);
    try testing.expectEqual(streaming.decoder.cursor, 2);

    var decoder = try streaming.splitPacket(&header);
    const version = try mqtt.decode.connect.version(&decoder);
    const msg = switch (version) {
        .v3_11 => try mqtt.v3_11.decode.connect(&decoder, true),
        .v5 => unreachable,
    };

    try testing.expectEqual(.connect, header.msg_type);
    try testing.expect(msg.auth == null);
    try testing.expect(msg.will == null);
    try testing.expectEqual(60, msg.keep_alive);
    try testing.expectEqualStrings("DIGI", msg.client_id);

    try decoder.finalize();
}

test "encode CONNECT message" {
    const msg: v3_11.Connect = .{
        .clean_session = true,
        .will = null,
        .auth = null,
        .keep_alive = 60,
        .client_id = "DIGI",
    };

    var buf: [18]u8 = undefined;
    const remaining_len, const byte_count = try mqtt.v3_11.encode.connect.validate(&msg);
    try testing.expectEqual(18, byte_count);

    mqtt.v3_11.encode.connect.populate(&msg, remaining_len, &buf);
    const expected: []const u8 = &.{
        0x10, 0x10, 0x00, 0x04, 0x4d, 0x51, 0x54, 0x54, 0x04,
        0x02, 0x00, 0x3c, 0x00, 0x04, 0x44, 0x49, 0x47, 0x49,
    };
    try testing.expectEqualSlices(u8, expected, &buf);
}
