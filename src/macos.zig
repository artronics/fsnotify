const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @cImport({
    @cInclude("CoreServices/CoreServices.h");
});
const testing = std.testing;
const expect = testing.expect;

fn stringToCFString(str: []const u8) c.CFStringRef {
    return c.CFStringCreateWithCString(null, str.ptr, c.kCFStringEncodingUTF8);
}
fn createCFStringArray(alloc: Allocator, strings: []const []const u8) !c.CFArrayRef {
    const arr = try alloc.alloc(?*const anyopaque, strings.len);
    defer alloc.free(arr);

    for (strings, 0..strings.len) |str, i| {
        const s = stringToCFString(str);
        arr[i] = s;
    }

    return c.CFArrayCreate(null, arr.ptr, @bitCast(strings.len), &c.kCFTypeArrayCallBacks);
}

test "CF utils" {
    const alloc = testing.allocator;
    const foo = "foo";
    const bar = "bar";

    const cf_str = stringToCFString(foo);
    try expect(cf_str != null);

    const arr = [2][]const u8{ foo, bar };
    const cf_str_arr = try createCFStringArray(alloc, &arr);
    try expect(cf_str_arr != null);
}
const Notify = struct {
    fn init(allocator: Allocator, path: []const u8) !void {
        const paths = .{path};
        const arr = try createCFStringArray(allocator, &paths);
        var context = c.FSEventStreamContext{
            .version = 0,
            .info = null,
            .retain = null,
            .release = null,
            .copyDescription = null,
        };
        var stream_flags: c_uint = c.kFSEventStreamCreateFlagFileEvents;
        const stream = c.FSEventStreamCreate(
            null,
            null,
            &context,
            arr,
            c.kFSEventStreamEventIdSinceNow,
            1.0,
            stream_flags,
        );
        const fsevents_queue = c.dispatch_queue_create("fsnotify_event_queue", null);
        c.FSEventStreamSetDispatchQueue(stream, fsevents_queue);
    }
};

const EventCallback = struct {
    //ConstFSEventStreamRef, ?*anyopaque, usize, ?*anyopaque, [*c]const FSEventStreamEventFlags, [*c]const FSEventStreamEventId
    fn callback(
        stream: c.ConstFSEventStreamRef,
        clientCallBackInfo: ?*anyopaque,
        numEvents: usize,
        eventPaths: ?*anyopaque,
        eventFlags: [*c]const c.FSEventStreamEventFlags,
        id: [*c]const c.FSEventStreamEventId,
    ) callconv(.C) void {
        std.log.warn("numEvents: {d}", .{numEvents});
        _ = eventFlags;
        _ = eventPaths;
        _ = clientCallBackInfo;
        _ = stream;
        _ = id;
    }
};

test "macos" {
    const c_string: [*c]const u8 = "/Users/jalal/tmp";
    var s: ?*const anyopaque = c.CFStringCreateWithCString(null, c_string, c.kCFStringEncodingUTF8);
    const arr = c.CFArrayCreate(null, &s, 1, &c.kCFTypeArrayCallBacks);
    var context = c.FSEventStreamContext{
        .version = 0,
        .info = null,
        .retain = null,
        .release = null,
        .copyDescription = null,
    };
    var stream_flags: c_uint = c.kFSEventStreamCreateFlagFileEvents;

    const stream = c.FSEventStreamCreate(
        null,
        EventCallback.callback,
        &context,
        arr,
        c.kFSEventStreamEventIdSinceNow,
        1.0,
        stream_flags,
    );
    const fsevents_queue = c.dispatch_queue_create("fsnotify_event_queue", null);
    c.FSEventStreamSetDispatchQueue(stream, fsevents_queue);
    const started = c.FSEventStreamStart(stream);
    if (started != 0) {
        while (true) {}
    } else {
        try expect(false);
    }

}
