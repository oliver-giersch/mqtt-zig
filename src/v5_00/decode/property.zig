const mqtt = @import("../../mqtt.zig");

pub const Property = mqtt.v5_00.Property;

pub const ConnectPropertyDecoder = Decoder(.connect, mqtt.v5_00.ConnectProperty);
pub const WillPropertyDecoder = Decoder(.connect, mqtt.v5_00.WillProperty);
pub const PublishPropertyDecoder = Decoder(.publish, mqtt.v5_00.PublishProperty);
pub const PubackPropertyDecoder = Decoder(.puback, mqtt.v5_00.PubackProperty);
pub const SubscribePropertyDecoder = Decoder(.subscribe, mqtt.v5_00.SubscribeProperty);

pub const PropertyError = mqtt.Decoder.Error(
    mqtt.InvalidUvar || mqtt.v5_00.InvalidPropertyID || mqtt.v5_00.InvalidPropertyPayload || error{InvalidDuplicateProperty},
);

/// A decoder for a byte sequence containing the property payloads of a specific
/// MQTT message type.
fn Decoder(comptime msg_type: mqtt.MessageType, comptime E: type) type {
    return struct {
        const Self = @This();

        pub const PropertySubset = E;
        pub const Payload = mqtt.v5_00.Property.Payload(PropertySubset);

        const BitSet = u16;

        /// The array of all property subset enum values (typically a small
        /// and dense array of sparse values).
        const property_subset: []const E = block: {
            const enum_fields = @typeInfo(E).@"enum".fields;

            var array: [enum_fields.len]E = undefined;
            for (enum_fields, &array) |field, *p|
                p.* = @enumFromInt(field.value);
            const final = array;
            break :block final[0..];
        };

        const unique_properties: []const u8 = block: {
            const unique = Property.uniqueProperties(msg_type, PropertySubset);
            var bits: [unique.len]u8 = @splat(0xFF);
            var bit: u4 = 0;
            for (unique, &bits) |u, *b| {
                if (u != null) {
                    b.* = bit;
                    bit += 1;
                }
            }

            const final = bits;
            break :block final[0..];
        };

        inner: mqtt.Decoder,
        unique_mask: BitSet = 0,

        pub fn splitOff(decoder: *mqtt.Decoder) !Self {
            const property_len = try decoder.split(mqtt.uvar);
            const byte_count: usize = @intCast(property_len.val);
            const inner = try decoder.splitOff(byte_count);

            return .{ .inner = inner };
        }

        pub fn decodeNext(self: *Self) PropertyError!?Self.Payload {
            const property = try self.decodeId() orelse return null;
            const payload = self.decodePayload(property) catch
                return error.InvalidPropertyPayload;

            if (uniqueBit(property)) |bit| {
                if (self.unique_mask & bit != 0)
                    return error.InvalidDuplicateProperty;
                self.unique_mask |= bit;
            }

            return payload;
        }

        fn decodeId(self: *Self) !?PropertySubset {
            const id = self.inner.split(mqtt.uvar) catch |err| return switch (err) {
                error.PacketLengthMismatch => null,
                else => err,
            };

            const property = mqtt.decode.resultCode(PropertySubset, id.val) orelse
                return error.InvalidPropertyID;
            return property;
        }

        fn decodePayload(self: *Self, property: PropertySubset) !Payload {
            switch (property) {
                inline else => |p| {
                    const data = comptime toSuper(p).data();
                    const value = switch (data) {
                        .bool => try self.inner.splitBool(),
                        .qos => block: {
                            const byte = try self.inner.split(u8);
                            break :block try mqtt.decode.qos(@truncate(byte));
                        },
                        .payload_format => {},
                        .u8 => try self.inner.split(u8),
                        .u16, .non_zero_u16 => try self.inner.split(u16),
                        .u32, .non_zero_u32 => try self.inner.split(u32),
                        .uvar, .non_zero_uvar => try self.inner.split(mqtt.uvar),
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

                    switch (data) {
                        .non_zero_u16, .non_zero_u32 => {
                            if (value == 0)
                                return error.InvalidZeroValue;
                        },
                        .non_zero_uvar => {
                            if (value.eql(.zero))
                                return error.InvalidZeroValue;
                        },
                        else => {},
                    }

                    return @unionInit(Payload, @tagName(p), value);
                },
            }
        }

        inline fn toSuper(sub: PropertySubset) Property {
            const code: u28 = @intFromEnum(sub);
            return @enumFromInt(code);
        }

        // what would be cool, would be a lookup table, where there is an array
        // indexable by a PropertySubset and that contains either null or the unique bit!
        fn uniqueBit(property: PropertySubset) ?u4 {
            const idx = propertyIndex(property);
            return if (unique_properties[idx] != 0xFF)
                @intCast(unique_properties[idx])
            else
                null;
        }

        fn propertyIndex(property: PropertySubset) usize {
            return for (property_subset, 0..) |p, idx| {
                if (property == p)
                    return idx;
            } else unreachable;
        }
    };
}

const testing = @import("std").testing;

test "will property payload" {
    const Payload = WillPropertyDecoder.Payload;
    try comptime testing.expectEqual(mqtt.v5_00.PayloadFormat, @FieldType(Payload, "payload_format_indicator"));
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
