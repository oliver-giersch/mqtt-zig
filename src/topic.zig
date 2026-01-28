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

    var iter = LevelIterator{ .remaining = buf };
    while (iter.next()) |part| {
        if (part.len == 0)
            continue;

        if (part.len > 1) {
            // c.f. §MQTT-4.7.1-2 and §MQTT-4.7.1-3
            if (isWildcard(part[0]))
                return error.InvalidWildcardPosition;
            if (containsWildcard(part[1..]))
                return error.InvalidWildcardPosition;
        }

        if (part[0] == '#' and iter.remaining != null)
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
    for (topic, 0..) |c, i| {
        if (c == '/') return i;
    }
    return null;
}

fn isWildcard(c: u8) bool {
    return c == wildcards.single_level or c == wildcards.multi_level;
}

const tt = @import("std").testing;

test "topic levels" {
    const topic = "abc/def/ghi";
    var iter = LevelIterator{ .remaining = topic };
    try tt.expectEqualStrings("abc", iter.next().?);
    try tt.expectEqualStrings("def", iter.next().?);
    try tt.expectEqualStrings("ghi", iter.next().?);
    try tt.expectEqual(null, iter.remaining);
    try tt.expectEqual(null, iter.next());
}

test "validate topic" {
    try mqtt.topic.validate("abc/def/ghi");
}

test "topic filters" {
    const err = error.InvalidWildcardPosition;
    try tt.expectError(err, mqtt.topic.validateFilter("abc+/def"));
    try tt.expectError(err, mqtt.topic.validateFilter("a/##"));
    try tt.expectError(err, mqtt.topic.validateFilter("ab+"));
    try tt.expectError(err, mqtt.topic.validateFilter("ab+"));
    try tt.expectError(err, mqtt.topic.validateFilter("+/#/+"));
    try tt.expectError(err, mqtt.topic.validateFilter("+/a/a+"));

    try mqtt.topic.validateFilter("#");
    try mqtt.topic.validateFilter("sport/#");
    try mqtt.topic.validateFilter("sport/tennis/#");
    try mqtt.topic.validateFilter("+");
    try mqtt.topic.validateFilter("+/tennis/#");
    try mqtt.topic.validateFilter("+/+");
}
