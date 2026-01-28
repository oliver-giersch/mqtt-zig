const mqtt = @import("mqtt.zig");

const is_16bit = switch (@sizeOf(usize)) {
    2 => true,
    else => false,
};

/// Calculates the packet length in its "variable integer" (uvar) representation
/// as well as its regular numeric representation.
///
/// # Errors
///
/// Fails, if the calculation would overflow an `usize` (only for 16-bit
/// targets).
pub fn packetSize(remaining_len: usize) !struct { mqtt.uvar, usize } {
    if (remaining_len > mqtt.uvar.max)
        return error.PacketTooLarge;

    const uvar = mqtt.uvar{ .val = @truncate(remaining_len) };
    const header_len = 1 + uvar.encodedBytes();

    const total_len = if (comptime is_16bit)
        try checkedAdd(header_len, remaining_len)
    else
        header_len + remaining_len;

    return .{ uvar, total_len };
}

/// Returns the number of bytes required to represent `string`
/// in an MQTT packet.
pub fn stringBytes(string: []const u8) !usize {
    try mqtt.string.validateLength(string);
    return if (is_16bit)
        checkedAdd(2, string.len)
    else
        string.len + 2;
}

pub fn checkedAdd(a: usize, b: usize) !usize {
    const res, const overflow = @addWithOverflow(a, b);
    return if (overflow == 0)
        res
    else
        return error.PacketTooLarge;
}
