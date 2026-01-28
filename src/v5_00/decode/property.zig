const mqtt = @import("../../mqtt.zig");

const Property = mqtt.v5_00.property.Property;

pub const PublishPropertyDecoder = Decoder(&.{
    .payload_format_indicator,
    .message_expiry_interval,
    .content_type,
    .response_topic,
    .correlation_data,
    .subscription_identifier,
    .topic_alias,
    .user_property,
});

pub const SubscribePropertyDecoder = Decoder(&.{
    .subscription_identifier,
    .user_property,
});

pub const WillPropertyDecoder = Decoder(&.{
    .payload_format_indicator,
    .message_expiry_interval,
    .content_type,
    .response_topic,
    .correlation_data,
    .user_property,
});

fn Decoder(comptime properties: []const Property) type {
    return struct {
        const Self = @This();

        pub const Payload = mqtt.v5_00.property.Payload(properties);

        const BitSet = u16;

        const unique_properties = mqtt.v5_00.property.uniqueProperties(properties);
        comptime {
            if (unique_properties.len >= @bitSizeOf(BitSet))
                @compileError("unique properties can't be tracked with bit set size");
        }

        inner: mqtt.Decoder,
        unique_mask: BitSet = 0,

        pub fn decodeNext(self: *Self) ?(anyerror!Self.Payload) {
            const property = try self.decodeId() orelse return null;
            const payload = block: {
                inline for (properties) |p| {
                    if (property == p) {
                        const payload = self.decodePayload(p) catch
                            return error.InvalidPropertyPayload;
                        break :block payload;
                    }
                }
                unreachable;
            };

            if (property.isUnique()) {
                const bit = Self.uniqueBit(property);
                if (self.unique_mask & bit != 0)
                    return error.InvalidDuplicateProperty;
                self.unique_mask |= bit;
            }

            return payload;
        }

        fn decodeId(self: *Self) !?Property {
            const id = self.inner.split(mqtt.uvar) catch |err| switch (err) {
                mqtt.Decoder.insufficient_bytes => return null,
                else => return err,
            };

            for (properties) |property| {
                if (@intFromEnum(property) == id.val)
                    return property;
            }

            return error.InvalidProperty;
        }

        fn decodePayload(self: *Self, comptime property: Property) !Payload {
            const value = switch (comptime property.payload()) {
                .@"bool" => block: {
                    const byte = try self.inner.split(u8);
                    break :block switch (byte) {
                        0 => false,
                        1 => true,
                        else => return error.InvalidBool,
                    };
                },
                .@"u8" => try self.inner.split(u8),
                .@"u16" => try self.inner.split(u16),
                .@"u32" => try self.inner.split(u32),
                .uvar => try self.inner.split(mqtt.uvar),
                .binary_data => try self.inner.splitByteStr(),
                .utf8_string => try self.inner.splitUtf8String(),
                .utf8_string_pair => block: {
                    const key = try self.inner.splitUtf8String();
                    const val = try self.inner.splitUtf8String();
                    break :block mqtt.v5_00.StringPair{
                        .key = key,
                        .val = val,
                    };
                },
            };

            try property.validate(value);
            return @unionInit(Payload, @tagName(property), value);
        }

        inline fn uniqueBit(property: Property) u4 {
            for (unique_properties, 0..) |unique, bit| {
                if (property == unique)
                    return @intCast(bit);
            }

            unreachable;
        }
    };
}

const tt = @import("std").testing;

test "will property payload" {
    const Payload = WillPropertyDecoder.Payload;
    try comptime tt.expectEqual(u8, @FieldType(Payload, "payload_format_indicator"));
    try comptime tt.expectEqual(u32, @FieldType(Payload, "message_expiry_interval"));
    try comptime tt.expectEqual([]const u8, @FieldType(Payload, "content_type"));
    try comptime tt.expectEqual([]const u8, @FieldType(Payload, "response_topic"));
    try comptime tt.expectEqual([]const u8, @FieldType(Payload, "correlation_data"));
    try comptime tt.expectEqual(mqtt.v5_00.StringPair, @FieldType(Payload, "user_property"));
}

test "subscribe property decode" {
    const Payload = SubscribePropertyDecoder.Payload;
    try comptime tt.expectEqual(mqtt.uvar, @FieldType(Payload, "subscription_identifier"));
    try comptime tt.expectEqual(mqtt.v5_00.StringPair, @FieldType(Payload, "user_property"));

    var decoder = mqtt.Decoder{ .buf = &.{ 0x0b, 0x00 } };
    var sub_decoder = SubscribePropertyDecoder{ .inner = decoder };

    var next = sub_decoder.decodeNext().?;
    try tt.expectError(error.InvalidPropertyPayload, next);
    try tt.expect(sub_decoder.decodeNext() == null);

    decoder = mqtt.Decoder{
        .buf = &.{ 0x0b, 0x0a, 0x26, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54 }
    };
    sub_decoder = SubscribePropertyDecoder{ .inner = decoder };

    next = sub_decoder.decodeNext().?;
    try tt.expect((try next).subscription_identifier.val == 0xa);
    next = sub_decoder.decodeNext().?;
    const pair = (try next).user_property;
    try tt.expectEqualStrings("MQTT", pair.key);
    try tt.expectEqualStrings("MQTT", pair.val);
    try tt.expect(sub_decoder.decodeNext() == null);
}