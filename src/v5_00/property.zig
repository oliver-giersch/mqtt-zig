const mqtt = @import("../mqtt.zig");

const builtin = @import("std").builtin;

/// The total set of all properties supported in MQTT v5.
pub const Property = enum(u28) {
    /// The data associated with a property.
    pub const Data = enum {
        /// A boolean value.
        bool,
        /// A QoS value.
        qos,
        /// A payload format indicator.
        payload_format,
        /// An 8-bit integer value.
        u8,
        /// An 16-bit integer value.
        u16,
        /// A non-zero 16-bit integer value.
        non_zero_u16,
        /// An 32-bit integer value.
        u32,
        /// A non-zero 32-bit integer value.
        non_zero_u32,
        /// A variable integer value.
        uvar,
        /// A non-zero variable integer value.
        non_zero_uvar,
        /// A slice of binary data.
        binary_data,
        /// An UTF-8 encoded string.
        utf8_string,
        /// A tuple of two UTF-8 encoded strings.
        utf8_string_pair,

        /// Returns the payload type associated with this property data.
        pub fn Type(comptime self: Property.Data) type {
            return switch (self) {
                .bool => bool,
                .qos => mqtt.Qos,
                .payload_format => mqtt.v5_00.PayloadFormat,
                .u8 => u8,
                .u16 => u16,
                .non_zero_u16 => u16,
                .u32 => u32,
                .non_zero_u32 => u32,
                .uvar => mqtt.uvar,
                .non_zero_uvar => mqtt.uvar,
                .binary_data, .utf8_string => []const u8,
                .utf8_string_pair => mqtt.v5_00.StringPair,
            };
        }
    };

    /// A subset of the given set of properties.
    pub fn Subset(comptime properties: []const Property) type {
        var field_names: [properties.len][]const u8 = undefined;
        var field_values: [properties.len]u28 = undefined;

        for (
            properties,
            &field_names,
            &field_values,
        ) |property, *name, *value| {
            name.* = @tagName(property);
            value.* = @intFromEnum(property);
        }

        // FIXME: calculate the exact number of bits required
        return @Enum(u28, .exhaustive, &field_names, &field_values);
    }

    /// The tagged union for the payload of a property subset.
    pub fn Payload(comptime E: type) type {
        const UnionField = builtin.Type.UnionField;

        const sub_properties = @typeInfo(E).@"enum".fields;
        var field_names: [sub_properties.len][]const u8 = undefined;
        var field_types: [sub_properties.len]type = undefined;
        var field_attrs: [sub_properties.len]UnionField.Attributes = undefined;

        for (
            sub_properties,
            &field_names,
            &field_types,
            &field_attrs,
        ) |sub_property, *field_name, *field_type, *field_attr| {
            const property: Property = @enumFromInt(sub_property.value);
            const T = property.data().Type();

            field_name.* = @tagName(property);
            field_type.* = T;
            field_attr.@"align" = null;
        }

        return @Union(.auto, E, &field_names, &field_types, &field_attrs);
    }

    payload_format_indicator = 0x01,
    message_expiry_interval = 0x02,
    content_type = 0x03,
    response_topic = 0x08,
    correlation_data = 0x09,
    subscription_identifier = 0x0b,
    session_expiry_interval = 0x11,
    assigned_client_id = 0x12,
    server_keep_alive = 0x13,
    auth_method = 0x15,
    auth_data = 0x16,
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

    /// Returns the subset of all unique properties in the given list of
    /// properties.
    pub inline fn uniqueProperties(
        comptime msg_type: mqtt.MessageType,
        comptime E: type,
    ) []const ?E {
        const enum_fields = @typeInfo(E).@"enum".fields;

        var array: [enum_fields.len]?E = @splat(null);
        for (enum_fields, &array) |field, *p| {
            const property: Property = @enumFromInt(field.value);
            if (property.isUnique(msg_type))
                p.* = @enumFromInt(field.value);
        }

        const final = array;
        return final[0..];
    }

    /// Returns the payload type for the given property.
    pub fn data(comptime self: Property) Data {
        return metadata(self).property_data;
    }

    /// Returns `true` if a given property must be used at most once per
    /// message.
    fn isUnique(
        comptime self: Property,
        comptime msg_type: mqtt.MessageType,
    ) bool {
        return switch (self) {
            inline else => |property| metadata(property).isUnique(msg_type),
        };
    }
};

/// The subset of valid CONNECT properties.
pub const ConnectProperty = Property.Subset(&.{
    .session_expiry_interval,
    .receive_maximum,
    .maximum_packet_size,
    .topic_alias_maximum,
    .request_response_information,
    .request_problem_information,
    .user_property,
    .auth_method,
    .auth_data,
});

pub const ConnackProperty = Property.Subset(&.{
    .session_expiry_interval,
    .receive_maximum,
    .maximum_qos,
    .retain_available,
    .maximum_packet_size,
    .assigned_client_id,
    .topic_alias_maximum,
    .reason_string,
    .user_property,
    .wildcard_subscription_available,
    .subscription_identifier_available,
    .shared_subscription_available,
    .server_keep_alive,
    .response_information,
    .server_reference,
    .auth_method,
    .auth_data,
});

/// The subset of valid will properties.
pub const WillProperty = Property.Subset(&.{
    .payload_format_indicator,
    .message_expiry_interval,
    .content_type,
    .response_topic,
    .correlation_data,
    .user_property,
});

pub const PublishProperty = Property.Subset(&.{
    .payload_format_indicator,
    .message_expiry_interval,
    .content_type,
    .response_topic,
    .correlation_data,
    .subscription_identifier,
    .topic_alias,
    .user_property,
});

pub const PubackProperty = Property.Subset(&.{
    .reason_string,
    .user_property,
});

pub const SubscribeProperty = Property.Subset(&.{
    .subscription_identifier,
    .user_property,
});

/// Only .user_property and .subscription_identifier are repeatable, but for
/// the latter uniqueness is actually message type dependent!
fn metadata(comptime property: Property) type {
    return switch (property) {
        .payload_format_indicator => unique(.payload_format),
        .message_expiry_interval => unique(.u32),
        .content_type => unique(.utf8_string),
        .response_topic => unique(.utf8_string),
        .correlation_data => unique(.binary_data),
        .subscription_identifier => subID(),
        .session_expiry_interval => unique(.u32),
        .assigned_client_id => unique(.utf8_string),
        .server_keep_alive => unique(.u16),
        .auth_method => unique(.utf8_string),
        .auth_data => unique(.binary_data),
        .request_problem_information => unique(.bool),
        .will_delay_interval => unique(.u32),
        .request_response_information => unique(.bool),
        .response_information => unique(.utf8_string),
        .server_reference => unique(.utf8_string),
        .reason_string => unique(.utf8_string),
        .receive_maximum => unique(.non_zero_u16),
        .topic_alias_maximum => unique(.u32),
        .topic_alias => unique(.u16),
        .maximum_qos => unique(.qos),
        .retain_available => unique(.bool),
        .user_property => repeatable(.utf8_string_pair),
        .maximum_packet_size => unique(.non_zero_u32),
        .wildcard_subscription_available => unique(.bool),
        .subscription_identifier_available => unique(.bool),
        .shared_subscription_available => unique(.bool),
    };
}

// metadata helper functions

fn unique(comptime data: Property.Data) type {
    return maybeUnique(data, always(true));
}

fn repeatable(comptime data: Property.Data) type {
    return maybeUnique(data, always(false));
}

fn subID() type {
    const is_unique_fn = struct {
        fn isUnique(comptime msg_type: mqtt.MessageType) bool {
            return switch (msg_type) {
                .connect => true,
                .subscribe => false,
                else => comptime unreachable,
            };
        }
    }.isUnique;

    return maybeUnique(.non_zero_uvar, is_unique_fn);
}

const Metadata = struct {
    const Uniqueness = union(enum) {
        _unique: void,
        _repeatable: void,
        _dependant: *const fn (mqtt.MessageType) bool,
    };

    data: Property.Data,
    uniqueness: Metadata.Uniqueness,

    pub fn isUnique(self: *const Metadata, msg_type: mqtt.MessageType) bool {
        return switch (self.uniqueness) {
            ._unique => true,
            ._repeatable => false,
            .dependent => |f| f(msg_type),
        };
    }
};

fn maybeUnique(
    comptime data: Property.Data,
    comptime is_unique_fn: fn (comptime mqtt.MessageType) bool,
) type {
    return struct {
        pub const property_data = data;

        pub fn isUnique(comptime msg_type: mqtt.MessageType) bool {
            return is_unique_fn(msg_type);
        }
    };
}

fn always(comptime value: bool) fn (comptime mqtt.MessageType) bool {
    return struct {
        fn always(comptime _: mqtt.MessageType) bool {
            return value;
        }
    }.always;
}
