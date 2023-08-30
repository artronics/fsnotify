const std = @import("std");
const testing = std.testing;
const c = @cImport({
    @cInclude("CoreServices/CoreServices.h");
});

export fn add(a: i32, b: i32) i32 {
    return a + b;
}

test "basic add functionality" {
    const c_string: [*c]const u8 = "/Users/jalal/tmp";
    const s = c.CFStringCreateWithCString(null, c_string, c.kCFStringEncodingUTF8);
    std.log.warn("string: {s}", .{s.?});
    try testing.expect(s != null);
}
