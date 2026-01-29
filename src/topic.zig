const mqtt = @import("mqtt.zig");

pub const FilterError = error{ InvalidEmptyFilter, InvalidWildcardPosition };

pub const wildcards = struct {
    pub const single_level = '+';
    pub const multi_level = '#';
};

pub fn validate(buf: []const u8) !void {
    if (containsWildcard(buf))
        return error.InvalidWildcard;
}

pub fn validateFilter(buf: []const u8) FilterError!void {
    if (buf.len == 0)
        return error.InvalidEmptyFilter;

    var it = LevelIterator{ .remaining = buf };
    while (it.next()) |part| {
        if (part.len == 0)
            continue;

        if (part.len > 1) {
            // c.f. §MQTT-4.7.1-2 and §MQTT-4.7.1-3
            if (isWildcard(part[0]))
                return error.InvalidWildcardPosition;
            if (containsWildcard(part[1..]))
                return error.InvalidWildcardPosition;
        }

        if (part[0] == '#' and it.remaining != null)
            return error.InvalidWildcardPosition;
    }
}

fn containsWildcard(buf: []const u8) bool {
    for (buf) |c| {
        if (isWildcard(c))
            return true;
    }

    return false;
}

pub const LevelIterator = struct {
    /// The remaining characters in the topic.
    remaining: ?[]const u8,

    pub fn next(self: *LevelIterator) ?[]const u8 {
        const rem = self.remaining orelse return null;
        if (findSeparator(rem)) |pos| {
            const part = rem[0..pos];
            self.remaining = rem[pos..][1..];
            return part;
        }

        self.remaining = null;
        return rem;
    }
};

fn findSeparator(topic: []const u8) ?usize {
    for (topic, 0..) |c, i|
        if (c == '/') return i;
    return null;
}

fn isWildcard(c: u8) bool {
    return c == wildcards.single_level or c == wildcards.multi_level;
}

const testing = @import("std").testing;

test "topic levels" {
    const topic = "abc/def/ghi";
    var iter = LevelIterator{ .remaining = topic };
    try testing.expectEqualStrings("abc", iter.next().?);
    try testing.expectEqualStrings("def", iter.next().?);
    try testing.expectEqualStrings("ghi", iter.next().?);
    try testing.expectEqual(null, iter.remaining);
    try testing.expectEqual(null, iter.next());
}

test "validate topic" {
    try mqtt.topic.validate("abc/def/ghi");
}

test "topic filters" {
    const err = error.InvalidWildcardPosition;
    try testing.expectError(err, mqtt.topic.validateFilter("abc+/def"));
    try testing.expectError(err, mqtt.topic.validateFilter("a/##"));
    try testing.expectError(err, mqtt.topic.validateFilter("ab+"));
    try testing.expectError(err, mqtt.topic.validateFilter("ab+"));
    try testing.expectError(err, mqtt.topic.validateFilter("+/#/+"));
    try testing.expectError(err, mqtt.topic.validateFilter("+/a/a+"));

    try mqtt.topic.validateFilter("#");
    try mqtt.topic.validateFilter("sport/#");
    try mqtt.topic.validateFilter("sport/tennis/#");
    try mqtt.topic.validateFilter("+");
    try mqtt.topic.validateFilter("+/tennis/#");
    try mqtt.topic.validateFilter("+/+");
}
