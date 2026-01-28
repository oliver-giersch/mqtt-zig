const mqtt = @import("../mqtt.zig");

/// The total set of all properties supported in MQTT v5.
pub const Property = enum(u28) {
    payload_format_indicator = 0x01,
    message_expiry_interval = 0x02,
    content_type = 0x03,
    response_topic = 0x08,
    correlation_data = 0x09,
    subscription_identifier = 0x0b,
    session_expiry_interval = 0x11,
    assigned_client_identifier = 0x12,
    server_keep_alive = 0x13,
    authentication_method = 0x15,
    authentication_data = 0x16,
    request_problem_information = 0x17,
    will_delay_interval = 0x18,
    request_response_information = 0x19,
    response_information = 0x1a,
    server_reference = 0x1c,
    reason_string = 0x1f,
    receive_maximum = 0x21,
    topic_alias_maximum = 0x22,
    topic_alias = 0x23,
    maximum_qos = 0x24,
    retain_available = 0x25,
    user_property = 0x26,
    maximum_packet_size = 0x27,
    wildcard_subscription_available = 0x28,
    subscription_identifier_available = 0x29,
    shared_subscription_available = 0x2a,

    /// Returns `true` if a given property must be used at most once per
    /// message.
    pub inline fn isUnique(self: Property) bool {
        return metadata[self.index()].is_unique;
    }

    /// Returns the payload type for the given property.
    pub inline fn payload(self: Property) PayloadType {
        return metadata[self.index()].payload;
    }

    pub inline fn validate(comptime self: Property, val: self.payload().Type()) !void {
        switch (self) {
            .payload_format_indicator => {
                const specifier: u8 = val;
                if (specifier > 1)
                    return error.InvalidPayloadFormatSpecifier;
            },
            .subscription_identifier => {
                const id: mqtt.uvar = val;
                if (id.val == 0)
                    return error.InvalidSubscriptionIdentifier;
            },
            else => {},
        }
    }

    inline fn index(self: Property) usize {
        for (all_properties, 0..) |property, i| {
            if (self == property)
                return i;
        }

        unreachable;
    }
};

/// Returns a `union` of all payload types for the given set of properties.
pub fn Payload(comptime properties: []const Property) type {
    const UnionField = @import("std").builtin.Type.UnionField;

    var field_names: [properties.len][]const u8 = undefined;
    var field_types: [properties.len]type = undefined;
    var field_attrs: [properties.len]UnionField.Attributes = undefined;

    for (properties, &field_names, &field_types, &field_attrs) |property, *field_name, *field_type, *field_attr| {
        const T = property.payload().Type();

        field_name.* = @tagName(property);
        field_type.* = T;
        field_attr.@"align" = null;
    }

    return @Union(.auto, null, &field_names, &field_types, &field_attrs);
}

/// Returns the subset of all unique properties in the given list of properties.
pub inline fn uniqueProperties(comptime properties: []const Property) []const Property {
    var unique: [properties.len]Property = undefined;
    var count: usize = 0;
    for (properties) |property| {
        if (property.isUnique()) {
            unique[count] = property;
            count += 1;
        }
    }

    const final = unique;
    return final[0..count];
}

pub const Metadata = struct {
    is_unique: bool,
    payload: PayloadType,
};

/// The different kinds of supported property payload types.
pub const PayloadType = enum {
    /// A boolean value.
    bool,
    /// An 8-bit integer value.
    u8,
    /// An 16-bit integer value.
    u16,
    /// An 32-bit integer value.
    u32,
    /// A variable integer value.
    uvar,
    /// A slice of binary data.
    binary_data,
    /// An UTF-8 encoded string.
    utf8_string,
    /// A tuple of two UTF-8 encoded strings.
    utf8_string_pair,

    pub inline fn Type(comptime self: PayloadType) type {
        return switch (self) {
            .bool => bool,
            .u8 => u8,
            .u16 => u16,
            .u32 => u32,
            .uvar => mqtt.uvar,
            .binary_data,
            .utf8_string,
            => []const u8,
            .utf8_string_pair => mqtt.v5_00.StringPair,
        };
    }
};

/// The array of all properties.
const all_properties = block: {
    const fields = @typeInfo(Property).@"enum".fields;
    var result: [fields.len]Property = undefined;
    for (fields, &result) |src, *dst|
        dst.* = @enumFromInt(src.value);

    break :block result;
};

const metadata = mapMetadata(.{
    .payload_format_indicator = Metadata{ .is_unique = true, .payload = .u8 },
    .message_expiry_interval = Metadata{ .is_unique = true, .payload = .u32 },
    .content_type = Metadata{ .is_unique = true, .payload = .utf8_string },
    .response_topic = Metadata{ .is_unique = true, .payload = .utf8_string },
    .correlation_data = Metadata{ .is_unique = true, .payload = .binary_data },
    .subscription_identifier = Metadata{ .is_unique = true, .payload = .uvar },
    .session_expiry_interval = Metadata{ .is_unique = false, .payload = .u32 },
    .assigned_client_identifier = Metadata{ .is_unique = false, .payload = .utf8_string },
    .server_keep_alive = Metadata{ .is_unique = false, .payload = .u16 },
    .authentication_method = Metadata{ .is_unique = false, .payload = .utf8_string },
    .authentication_data = Metadata{ .is_unique = false, .payload = .binary_data },
    .request_problem_information = Metadata{ .is_unique = false, .payload = .u8 },
    .will_delay_interval = Metadata{ .is_unique = false, .payload = .u32 },
    .request_response_information = Metadata{ .is_unique = false, .payload = .u8 },
    .response_information = Metadata{ .is_unique = false, .payload = .utf8_string },
    .server_reference = Metadata{ .is_unique = false, .payload = .utf8_string },
    .reason_string = Metadata{ .is_unique = false, .payload = .utf8_string },
    .receive_maximum = Metadata{ .is_unique = false, .payload = .u16 },
    .topic_alias_maximum = Metadata{ .is_unique = false, .payload = .u16 },
    .topic_alias = Metadata{ .is_unique = false, .payload = .u16 },
    .maximum_qos = Metadata{ .is_unique = false, .payload = .u8 },
    .retain_available = Metadata{ .is_unique = false, .payload = .u8 },
    .user_property = Metadata{ .is_unique = false, .payload = .utf8_string_pair },
    .maximum_packet_size = Metadata{ .is_unique = false, .payload = .u32 },
    .wildcard_subscription_available = Metadata{ .is_unique = false, .payload = .u8 },
    .subscription_identifier_available = Metadata{ .is_unique = false, .payload = .u8 },
    .shared_subscription_available = Metadata{ .is_unique = false, .payload = .u8 },
});

fn mapMetadata(map: anytype) [all_properties.len]Metadata {
    const ti = @typeInfo(@TypeOf(map));
    const fields = ti.@"struct".fields;
    if (fields.len != all_properties.len)
        @compileError("map must set metadata for all properties");

    var result: [all_properties.len]Metadata = undefined;
    outer: for (fields) |field| {
        if (field.type != Metadata)
            @compileError("map must only contain metadata fields");
        for (all_properties) |property| {
            @setEvalBranchQuota(4000);
            if (mqtt.eql(@tagName(property), field.name)) {
                result[property.index()] = @field(map, field.name);
                continue :outer;
            }
        }

        @compileError("map contains invalid property: " ++ field.name);
    }

    return result;
}
