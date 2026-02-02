const mqtt = @import("../../mqtt.zig");

pub const Property = mqtt.v5_00.Property;

pub const ConnectPropertyDecoder = Decoder(mqtt.v5_00.ConnectProperty);
pub const WillPropertyDecoder = Decoder(mqtt.v5_00.WillProperty);
pub const PublishPropertyDecoder = Decoder(mqtt.v5_00.PublishProperty);
pub const PubackPropertyDecoder = Decoder(mqtt.v5_00.PubackProperty);
pub const SubscribePropertyDecoder = Decoder(mqtt.v5_00.SubscribeProperty);

fn Decoder(comptime E: type) type {
    return struct {
        const Self = @This();

        pub const SubProperty = E;
        pub const Payload = mqtt.v5_00.Property.Payload(SubProperty);

        const BitSet = u16;

        const unique_properties = mqtt.v5_00.Property.uniqueProperties(SubProperty);
        comptime {
            if (unique_properties.len >= @bitSizeOf(BitSet))
                @compileError("unique properties can't be tracked with bit set size");
        }

        inner: mqtt.Decoder,
        unique_mask: BitSet = 0,

        pub fn splitOff(decoder: *mqtt.Decoder) !Self {
            const property_len = try decoder.split(mqtt.uvar);
            const byte_count: usize = @intCast(property_len.val);
            const inner = try decoder.splitOff(byte_count);

            return .{ .inner = inner };
        }

        pub fn decodeNext(self: *Self) !?Self.Payload {
            const sub_property = try self.decodeId() orelse return null;
            const payload = switch (sub_property) {
                inline else => |p| block: {
                    const payload = self.decodePayload(p) catch
                        return error.InvalidPropertyPayload;
                    break :block payload;
                },
            };

            const property = toSuper(sub_property);
            if (property.isUnique()) {
                const bit = Self.uniqueBit(property);
                if (self.unique_mask & bit != 0)
                    return error.InvalidDuplicateProperty;
                self.unique_mask |= bit;
            }

            return payload;
        }

        fn decodeId(self: *Self) !?SubProperty {
            const id = self.inner.split(mqtt.uvar) catch |err| return switch (err) {
                error.PacketLengthMismatch => null,
                else => err,
            };

            const property = mqtt.decode.resultCode(SubProperty, id.val) orelse
                return error.InvalidProperty;
            return property;
        }

        fn decodePayload(self: *Self, comptime sub_property: SubProperty) !Payload {
            const property = toSuper(sub_property);
            const value = switch (comptime property.payload()) {
                .bool => try self.inner.splitBool(),
                .u8 => try self.inner.split(u8),
                .u16 => try self.inner.split(u16),
                .u32 => try self.inner.split(u32),
                .uvar => try self.inner.split(mqtt.uvar),
                .binary_data => try self.inner.splitByteString(),
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
            return @unionInit(Payload, @tagName(sub_property), value);
        }

        inline fn toSuper(sub: SubProperty) Property {
            const code: u28 = @intFromEnum(sub);
            return @enumFromInt(code);
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

const testing = @import("std").testing;

test "will property payload" {
    const Payload = WillPropertyDecoder.Payload;
    try comptime testing.expectEqual(u8, @FieldType(Payload, "payload_format_indicator"));
    try comptime testing.expectEqual(u32, @FieldType(Payload, "message_expiry_interval"));
    try comptime testing.expectEqual([]const u8, @FieldType(Payload, "content_type"));
    try comptime testing.expectEqual([]const u8, @FieldType(Payload, "response_topic"));
    try comptime testing.expectEqual([]const u8, @FieldType(Payload, "correlation_data"));
    try comptime testing.expectEqual(mqtt.v5_00.StringPair, @FieldType(Payload, "user_property"));
}

test "subscribe property decode" {
    const Payload = SubscribePropertyDecoder.Payload;
    try comptime testing.expectEqual(mqtt.uvar, @FieldType(Payload, "subscription_identifier"));
    try comptime testing.expectEqual(mqtt.v5_00.StringPair, @FieldType(Payload, "user_property"));

    var decoder = mqtt.Decoder{ .buf = &.{ 0x0b, 0x00 } };
    var sub_decoder = SubscribePropertyDecoder{ .inner = decoder };

    try testing.expectError(error.InvalidPropertyPayload, sub_decoder.decodeNext());
    try testing.expect(try sub_decoder.decodeNext() == null);

    decoder = mqtt.Decoder{ .buf = &.{ 0x0b, 0x0a, 0x26, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54, 0x00, 0x04, 0x4D, 0x51, 0x54, 0x54 } };
    sub_decoder = SubscribePropertyDecoder{ .inner = decoder };

    var next = try sub_decoder.decodeNext();
    try testing.expect(next.?.subscription_identifier.val == 0xa);
    next = try sub_decoder.decodeNext();
    const pair = next.?.user_property;
    try testing.expectEqualStrings("MQTT", pair.key);
    try testing.expectEqualStrings("MQTT", pair.val);
    try testing.expect(try sub_decoder.decodeNext() == null);
}
