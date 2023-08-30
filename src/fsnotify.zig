const std = @import("std");
const c = @cImport({
    @cInclude("CoreServices/CoreServices.h");
});
const expect = std.testing.expect;

test "fsnotify" {
    const c_string: [*c]const u8 = "/Users/jalal/tmp";
    var s: ?*const anyopaque = c.CFStringCreateWithCString(null, c_string, c.kCFStringEncodingUTF8);
    const arr = c.CFArrayCreate(null, &s, 0, &c.kCFTypeArrayCallBacks);
    var context = c.FSEventStreamContext{
        .version = 0,
        .info = null,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    var stream_flags:c_uint = c.kFSEventStreamCreateFlagFileEvents;
    _ = c.FSEventStreamCreate(
        null,
        null,
        &context,
        arr,
        c.kFSEventStreamEventIdSinceNow,
        1.0,
        stream_flags,
    );
    try expect(arr == null);
}
