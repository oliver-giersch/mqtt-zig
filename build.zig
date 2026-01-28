const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const mqtt = b.addModule("mqtt", .{
        .root_source_file = b.path("src/mqtt.zig"),
        .target = target,
    });

    const mqtt_tests = b.addTest(.{ .root_module = mqtt });
    const run_mqtt_tests = b.addRunArtifact(mqtt_tests);
    const test_step = b.step("test", "Run tests");
    test_step.dependOn(&run_mqtt_tests.step);
}
