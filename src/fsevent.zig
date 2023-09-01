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
    flag: usize,
    id: Id,
    pub const Id = struct {
        const since_now = Id{ .value = c.kFSEventStreamEventIdSinceNow };
        value: u64,
    };
    pub const Flag = enum(u32) {
        none = c.kFSEventStreamEventFlagNone,
        must_scan_sub_dirs = c.kFSEventStreamEventFlagMustScanSubDirs,
        user_dropped = c.kFSEventStreamEventFlagUserDropped,
        kernel_dropped = c.kFSEventStreamEventFlagKernelDropped,
        event_ids_wrapped = c.kFSEventStreamEventFlagEventIdsWrapped,
        history_done = c.kFSEventStreamEventFlagHistoryDone,
        root_changed = c.kFSEventStreamEventFlagRootChanged,
        mount = c.kFSEventStreamEventFlagMount,
        unmount = c.kFSEventStreamEventFlagUnmount,
        item_created = c.kFSEventStreamEventFlagItemCreated,
        item_removed = c.kFSEventStreamEventFlagItemRemoved,
        item_inode_meta_mod = c.kFSEventStreamEventFlagItemInodeMetaMod,
        item_renamed = c.kFSEventStreamEventFlagItemRenamed,
        item_modified = c.kFSEventStreamEventFlagItemModified,
        item_finder_info_mod = c.kFSEventStreamEventFlagItemFinderInfoMod,
        item_change_owner = c.kFSEventStreamEventFlagItemChangeOwner,
        item_xattr_mod = c.kFSEventStreamEventFlagItemXattrMod,
        item_is_file = c.kFSEventStreamEventFlagItemIsFile,
        item_is_dir = c.kFSEventStreamEventFlagItemIsDir,
        item_is_symlink = c.kFSEventStreamEventFlagItemIsSymlink,
        own_event = c.kFSEventStreamEventFlagOwnEvent,
        item_is_hardlink = c.kFSEventStreamEventFlagItemIsHardlink,
        item_is_last_hardlink = c.kFSEventStreamEventFlagItemIsLastHardlink,
        item_cloned = c.kFSEventStreamEventFlagItemCloned,
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
        var result: c_uint = 0;
        for (flags) |flag| {
            result |= @intCast(@intFromEnum(flag));
        }

        return result;
    }
    test "StreamCreateFlags" {
        const flags = [_]StreamCreateFlags{ StreamCreateFlags.none, StreamCreateFlags.use_cf_types, StreamCreateFlags.no_defer };
        const exp_flags = StreamCreateFlags.combine(&flags);
        try expect(3 == exp_flags);
    }
};

pub const FsEvent = struct {
    pub fn Stream(comptime UserInfo: type) type {
        return struct {
            const Self = @This();

            // All memory will be freed. Make a copy if you need reference.
            pub const UserCallback = fn (info: ?*const UserInfo, events: []Event) void;

            const Info = struct {
                user_info: ?*const UserInfo,
                user_callback: *const UserCallback,
            };

            arena: ArenaAllocator,
            callback: *const UserCallback,
            context: Context,
            paths: []const [:0]const u8,
            latency: f64,
            create_flags: c_uint,

            _ref: *const Self = undefined,

            const StreamCallback = struct {
                fn callback(
                    stream: c.ConstFSEventStreamRef,
                    clientCallBackInfo: ?*anyopaque,
                    numEvents: usize,
                    eventPaths: ?*anyopaque,
                    eventFlags: [*c]const c.FSEventStreamEventFlags,
                    id: [*c]const c.FSEventStreamEventId,
                ) callconv(.C) void {
                    std.log.warn("From stream callback: numEvents: {d}", .{numEvents});
                    const cb_info: ?*align(@alignOf(anyopaque)) Info = @ptrCast(clientCallBackInfo);
                    const info = cb_info orelse unreachable;

                    // TODO: in case of error, allocate a buffer and log the error
                    var events_raw = std.c.malloc(@sizeOf(Event) * numEvents) orelse return;
                    var events_slice: [*]Event = @alignCast(@ptrCast(events_raw));
                    var events: []Event = undefined;
                    events.ptr = @ptrCast(events_slice);
                    events.len = numEvents;

                    for (0..numEvents) |i| {
                        events[i] = Event{ .flag = 1, .id = Event.Id{ .value = 0 }, .path = "foo" };
                    }
                    info.user_callback(info.user_info, events);
                    std.c.free(events_raw);

                    _ = eventFlags;
                    _ = eventPaths;
                    _ = stream;
                    _ = id;
                }
            };

            pub fn init(allocator: Allocator, user_info: ?*const UserInfo, callback: *const UserCallback, paths: []const []const u8, latency: f64, create_flags: []const StreamCreateFlags) !Self {
                var arena = ArenaAllocator.init(allocator);
                const alloc = arena.allocator();

                const cp_paths = try alloc.alloc([:0]const u8, paths.len);
                for (paths, 0..paths.len) |p, i| {
                    const cp_p: [:0]u8 = try alloc.allocSentinel(u8, p.len, 0);
                    @memcpy(cp_p, p);
                    cp_paths[i] = cp_p;
                }

                const cp_u_info = if (user_info) |i| blk: {
                    var s = try alloc.create(UserInfo);
                    s.* = i.*;
                    break :blk s;
                } else null;
                var info = try alloc.create(Info);
                info.* = Info{
                    .user_info = cp_u_info,
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
                info: *const Info,

                fn toFsEventStreamContext(ctx: Context) c.FSEventStreamContext {
                    std.debug.assert(ctx.version == 0);

                    return c.FSEventStreamContext{
                        .version = 0,
                        .info = @constCast(ctx.info),
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
    const a = testing.allocator;
    const MyInfo = usize;
    const my_info: MyInfo = 42;
    const Stream = FsEvent.Stream(MyInfo);
    const paths = [2][]const u8{ "/Users/jalal/tmp/prism", "/Users/jalal/tmp/linux" };

    const Cb = struct {
        fn callback(info: ?*const MyInfo, events: []Event) void {
            std.log.warn("from user callback", .{});
            std.log.warn("info {d}", .{info.?.*});
            for (events) |e| {
                std.log.warn("event {}", .{e});
            }
        }
    };
    const flags = &[_]StreamCreateFlags{.none};
    var stream = try Stream.init(a, &my_info, Cb.callback, &paths, 1.0, flags);
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
