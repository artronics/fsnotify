const std = @import("std");
const Allocator = std.mem.Allocator;
const ArenaAllocator = std.heap.ArenaAllocator;
const c = @cImport({
    @cInclude("CoreServices/CoreServices.h");
});
const testing = std.testing;
const expect = testing.expect;

pub const Event = struct {
    path: []const u8,
    flag: StreamCreateFlags,
    id: Id,
    pub const Id = struct {
        const since_now = Id{ .value = c.kFSEventStreamEventIdSinceNow };
        value: u64,
    };
};
pub const StreamCreateFlags = enum(u32) {
    none = c.kFSEventStreamCreateFlagNone,
    use_cf_types = c.kFSEventStreamCreateFlagUseCFTypes,
    no_defer = c.kFSEventStreamCreateFlagNoDefer,
    watch_root = c.kFSEventStreamCreateFlagWatchRoot,
    ignore_self = c.kFSEventStreamCreateFlagIgnoreSelf,
    file_events = c.kFSEventStreamCreateFlagFileEvents,
    mark_self = c.kFSEventStreamCreateFlagMarkSelf,
    use_extended_data = c.kFSEventStreamCreateFlagUseExtendedData,
    full_history = c.kFSEventStreamCreateFlagFullHistory,
    fn combine(flags: []const StreamCreateFlags) c_uint {
        var f: c_uint = 0;
        for (flags) |flag| {
            f |= @intCast(@intFromEnum(flag));
        }

        return f;
    }
    test "StreamCreateFlags" {
        const flags = [_]StreamCreateFlags{ StreamCreateFlags.none, StreamCreateFlags.use_cf_types, StreamCreateFlags.no_defer };
        const exp_flags = StreamCreateFlags.combine(&flags);
        try expect(3 == exp_flags);
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
const TestStream = struct {
    const UserCbFn = fn (sum: usize) void;
    const FsStCbFn = fn (info: ?*anyopaque, a: usize, b: usize) void;
    info: *const MyInfo,
    user_cb: *const UserCbFn,
    //align(@alignOf(@TypeOf(*anyopaque)))
    var user_cb_val: *const UserCbFn = undefined;

    const MyInfo = struct { user_cb: *const UserCbFn, other: usize = 0 };

    const MyCb = struct {
        fn my_cb(info: ?*anyopaque, a: usize, b: usize) void {
            // _ = info;
            std.log.warn("MY STREAM callback started a: {d}, b: {d}", .{ a, b });
            // user_cb_val(a + b);
            const my_info: ?*align(@alignOf(anyopaque)) const MyInfo = @ptrCast(info);
            // const my_info: *align(1) const MyInfo = @ptrCast(info);
            // const user_cb: *const UserCbFn = @ptrCast(info.user_cb);
            my_info.?.user_cb(a + b);
        }

        fn my_cb2(self: MyCb, a: usize, b: usize) void {
            _ = self;
            std.log.warn("MY STREAM callback started a: {d}, b: {d}", .{ a, b });
            user_cb_val(a + b);
        }
    };

    fn start(ms: TestStream) void {
        // const my_cb = MyCb{};
        const fs = FsStream{ .info = @constCast(ms.info), .fs_cb = MyCb.my_cb };
        fs.run();
    }
    const FsStream = struct {
        fs_cb: *const FsStCbFn,
        info: ?*anyopaque,
        fn run(st: FsStream) void {
            std.log.warn("FS STREAM callback started", .{});
            st.fs_cb(st.info, 10, 20);
        }
    };
    const UserCb = struct {
        fn userCb1(sum: usize) void {
            std.log.warn("USER callback1 val: {d}", .{sum});
        }
        fn userCb2(sum: usize) void {
            std.log.warn("USER callback2 val: {d}", .{sum});
        }
    };
};
test "cb" {
    const info1 = TestStream.MyInfo{ .user_cb = TestStream.UserCb.userCb1, .other = 4 };
    // TestStream.user_cb_val = TestStream.UserCb.userCb1;
    const st1 = TestStream{ .info = &info1, .user_cb = TestStream.UserCb.userCb1 };

    const info2 = TestStream.MyInfo{ .user_cb = TestStream.UserCb.userCb2, .other = 8 };
    // TestStream.user_cb_val = TestStream.UserCb.userCb2;
    const st2 = TestStream{ .info = &info2, .user_cb = TestStream.UserCb.userCb2 };
    st1.start();
    st2.start();
}

pub const FsEvent = struct {
    pub fn Stream(comptime UserInfo: type) type {
        return struct {
            const Self = @This();

            pub const UserCallback = fn (info: ?*UserInfo, events: []Event) void;

            const Info = struct {
                user_info: ?*UserInfo,
                user_callback: *const UserCallback,
            };

            arena: ArenaAllocator,
            callback: *const UserCallback,
            context: Context,
            paths: []const [:0]const u8,
            latency: f64,
            create_flags: c_uint,

            //?*const fn (ConstFSEventStreamRef, ?*anyopaque, usize, ?*anyopaque, [*c]const FSEventStreamEventFlags, [*c]const FSEventStreamEventId) callconv(.C) void;
            _ref: *const Self = undefined,
            const StreamCallback = struct {
                user_callback: *const UserCallback,
                fn callback(
                    stream: c.ConstFSEventStreamRef,
                    clientCallBackInfo: ?*anyopaque,
                    numEvents: usize,
                    eventPaths: ?*anyopaque,
                    eventFlags: [*c]const c.FSEventStreamEventFlags,
                    id: [*c]const c.FSEventStreamEventId,
                ) callconv(.C) void {
                    std.log.warn("From stream callback: numEvents: {d}", .{numEvents});
                    const info: ?*align(@alignOf(anyopaque)) Info = @ptrCast(clientCallBackInfo);

                    info.?.user_callback(null, undefined);

                    _ = eventFlags;
                    _ = eventPaths;
                    _ = stream;
                    _ = id;
                }
            };

            pub fn init(allocator: Allocator, callback: *const UserCallback, paths: []const []const u8, latency: f64, create_flags: []const StreamCreateFlags) !Self {
                var arena = ArenaAllocator.init(allocator);
                const alloc = arena.allocator();

                const cp_paths = try alloc.alloc([:0]const u8, paths.len);
                for (paths, 0..paths.len) |p, i| {
                    const cp_p: [:0]u8 = try alloc.allocSentinel(u8, p.len, 0);
                    @memcpy(cp_p, p);
                    cp_paths[i] = cp_p;
                }

                var info = try alloc.create(Info);
                info.* = Info{
                    .user_info = null,
                    .user_callback = callback,
                };
                const context = Context{ .info = info };

                return Self{
                    .arena = arena,
                    .callback = callback,
                    .context = context,
                    .paths = cp_paths,
                    .latency = latency,
                    .create_flags = StreamCreateFlags.combine(create_flags),
                };
            }

            pub fn deinit(self: Self) void {
                self.arena.deinit();
            }
            pub fn start(self: *Self, since: Event.Id, dispatch_queue: DispatchQueue) !bool {
                const alloc = self.arena.allocator();

                var ctx = self.context.toFsEventStreamContext();
                const paths = try createCFStringArray(alloc, self.paths);
                const event_id: c_ulonglong = @intCast(since.value);

                const stream = c.FSEventStreamCreate(
                    null,
                    StreamCallback.callback,
                    &ctx,
                    paths,
                    event_id,
                    self.latency,
                    self.create_flags,
                );
                const fsevents_queue = c.dispatch_queue_create(dispatch_queue.label, null);
                c.FSEventStreamSetDispatchQueue(stream, fsevents_queue);
                const started = c.FSEventStreamStart(stream);

                return started != 0;
            }
            const Context = struct {
                version: usize = 0,
                info: *Info,

                fn toFsEventStreamContext(ctx: Context) c.FSEventStreamContext {
                    std.debug.assert(ctx.version == 0);

                    return c.FSEventStreamContext{
                        .version = 0,
                        .info = ctx.info,
                        .retain = null,
                        .release = null,
                        .copyDescription = null,
                    };
                }
            };
        };
    }
};

pub const DispatchQueue = struct {
    label: [:0]const u8,
};

fn stringToCFString(str: [:0]const u8) c.CFStringRef {
    return c.CFStringCreateWithCString(null, str.ptr, c.kCFStringEncodingUTF8);
}
fn createCFStringArray(alloc: Allocator, strings: []const [:0]const u8) !c.CFArrayRef {
    const arr = try alloc.alloc(?*const anyopaque, strings.len);
    defer alloc.free(arr);

    for (strings, 0..strings.len) |str, i| {
        const s = stringToCFString(str);
        arr[i] = s;
    }

    return c.CFArrayCreate(null, arr.ptr, @intCast(strings.len), &c.kCFTypeArrayCallBacks);
}
test "fsevent" {
    // pub const Callback = *const fn (info: ?*Info, events: []Event) void;

    const a = testing.allocator;
    const Info = usize;
    const Stream = FsEvent.Stream(Info);
    const paths = [2][]const u8{ "/Users/jalal/tmp/prism", "/Users/jalal/tmp/linux" };

    const Cb = struct {
        fn callback(info: ?*Info, events: []Event) void {
            std.log.warn("from user callback", .{});
            _ = info;
            _ = events;
        }
    };
    const flags = &[_]StreamCreateFlags{.none};
    var stream = try Stream.init(a, Cb.callback, &paths, 1.0, flags);
    defer stream.deinit();

    const dispatch_q = DispatchQueue{ .label = "my dispatch q" };
    const started = try stream.start(Event.Id.since_now, dispatch_q);

    try expect(started != false);
    while (true) {}
}

test "CF utils" {
    const alloc = testing.allocator;

    const cf_str = stringToCFString("foo");
    try expect(cf_str != null);

    const arr = [2][:0]const u8{ "foo", "bar" };
    const cf_str_arr = try createCFStringArray(alloc, &arr);
    try expect(cf_str_arr != null);
}
