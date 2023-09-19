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
    flags: Flags,
    id: Id,
    pub const Id = struct {
        const since_now = Id{ .value = c.kFSEventStreamEventIdSinceNow };
        value: u64,
    };
    pub const Flags = packed struct(u32) {
        must_scan_sub_dirs: bool = false,
        user_dropped: bool = false,
        kernel_dropped: bool = false,
        event_ids_wrapped: bool = false,
        history_done: bool = false,
        root_changed: bool = false,
        mount: bool = false,
        unmount: bool = false,
        item_created: bool = false,
        item_removed: bool = false,
        item_inode_meta_mod: bool = false,
        item_renamed: bool = false,
        item_modified: bool = false,
        item_finder_info_mod: bool = false,
        item_change_owner: bool = false,
        item_xattr_mod: bool = false,
        item_is_file: bool = false,
        item_is_dir: bool = false,
        item_is_symlink: bool = false,
        own_event: bool = false,
        item_is_hardlink: bool = false,
        item_is_last_hardlink: bool = false,
        item_cloned: bool = false,
        _: u9 = 0,
    };
    // TODO: change this to format
    pub fn print(e: Event, allocator: Allocator) ![]const u8 {
        var flags = std.ArrayList(u8).init(allocator);
        defer flags.deinit();

        inline for (@typeInfo(Event.Flags).Struct.fields) |field| {
            if (field.type == bool and @as(field.type, @field(e.flags, field.name))) {
                try flags.appendSlice(field.name);
                try flags.appendSlice(", ");
            }
        }
        return try std.fmt.allocPrint(allocator, "Event[{d}]: [{s}] -> {s}", .{ e.id.value, e.path, flags.items });
    }
};
pub const StreamCreateFlags = packed struct(u32) {
    use_cf_types: bool = false,
    no_defer: bool = false,
    watch_root: bool = false,
    ignore_self: bool = false,
    file_events: bool = false,
    mark_self: bool = false,
    use_extended_data: bool = false,
    full_history: bool = false,

    _: u24 = 0,
};

pub const FsEvent = struct {
    pub fn Stream(comptime UserInfo: type) type {
        return struct {
            const Self = @This();

            // All memory will be freed. Make a copy if you need reference.
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
            create_flags: StreamCreateFlags,

            _ref: *const Self = undefined,

            const StreamCallback = struct {
                fn callback(
                    stream: c.ConstFSEventStreamRef,
                    fs_cb_info: ?*anyopaque,
                    num_events: usize,
                    event_paths: ?*anyopaque,
                    event_flags: [*c]const c.FSEventStreamEventFlags,
                    event_ids: [*c]const c.FSEventStreamEventId,
                ) callconv(.C) void {
                    const cb_info: ?*Info = @alignCast(@ptrCast(fs_cb_info));

                    // We allocate memory and then call user callback in our callback.
                    // User callback must copy the values if it needs reference. We free all the allocated memory at the end of our callback.
                    // FIXME: Memory allocation only works via malloc (I think it's because of callconv(.C)). I tried to pass Allocator and ArenaAllocator as pointer but it didn't work either.
                    // TODO: in case of error, allocate a buffer and log the error
                    var events_raw = std.c.malloc(@sizeOf(Event) * num_events) orelse return;
                    defer std.c.free(events_raw);
                    var events_slice: [*]Event = @alignCast(@ptrCast(events_raw));
                    var events: []Event = undefined;
                    events.ptr = @ptrCast(events_slice);
                    events.len = num_events;

                    var flags_slice: [*]const c.UInt32 = @ptrCast(event_flags);
                    var flagsets: []c.UInt32 = undefined;
                    flagsets.ptr = @constCast(@ptrCast(flags_slice));
                    flagsets.len = num_events;

                    var ids_slice: [*]const c.UInt64 = @ptrCast(event_ids);
                    var ids: []c.UInt64 = undefined;
                    ids.ptr = @constCast(@ptrCast(ids_slice));
                    ids.len = num_events;

                    var paths_slice: [*][*:0]u8 = @alignCast(@ptrCast(event_paths));
                    var paths: [*][:0]u8 = @alignCast(@ptrCast(std.c.malloc(@sizeOf(?[:0]u8) * num_events) orelse return));

                    for (0..num_events) |i| {
                        const flagset: Event.Flags = @bitCast(@as(u32, @intCast(flagsets[i])));
                        const id = Event.Id{ .value = @intCast(ids[i]) };

                        paths[i].ptr = paths_slice[i];
                        var j: usize = 0;
                        while (paths_slice[i][j] != '\x00') : (j += 1) {}
                        paths[i].len = j + 1;

                        events[i] = Event{ .flags = flagset, .id = id, .path = paths[i] };
                    }

                    if (cb_info) |info| {
                        info.user_callback(info.user_info, events);
                    }

                    _ = stream;
                }
            };

            pub fn init(allocator: Allocator, user_info: ?*UserInfo, callback: *const UserCallback, paths: []const []const u8, latency: f64, create_flags: StreamCreateFlags) !Self {
                // FIXME this arena should come from init as a pointer
                var arena = ArenaAllocator.init(allocator);
                const alloc = arena.allocator();

                const _paths = try alloc.alloc([:0]const u8, paths.len);
                for (paths, 0..paths.len) |p, i| {
                    const cp_p: [:0]u8 = try alloc.allocSentinel(u8, p.len, 0);
                    @memcpy(cp_p, p);
                    _paths[i] = cp_p;
                }

                var info = try alloc.create(Info);
                info.* = Info{
                    .user_info = user_info,
                    .user_callback = callback,
                };

                const context = Context{ .info = info };

                return Self{ .arena = arena, .callback = callback, .context = context, .paths = _paths, .latency = latency, .create_flags = create_flags };
            }

            pub fn deinit(self: Self) void {
                self.arena.deinit();
            }
            pub fn start(self: *Self, since: Event.Id, dispatch_queue: DispatchQueue) !bool {
                const alloc = self.arena.allocator();

                var ctx = self.context.toFsEventStreamContext();
                const paths = try createCFStringArray(alloc, self.paths);
                const event_id: c_ulonglong = @intCast(since.value);
                const create_flags: c_uint = @bitCast(self.create_flags);

                const stream = c.FSEventStreamCreate(
                    null,
                    StreamCallback.callback,
                    &ctx,
                    paths,
                    event_id,
                    self.latency,
                    create_flags,
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
    const a = testing.allocator;

    var arena = ArenaAllocator.init(a);
    var test_fs = try TestFs.init(&arena);
    defer test_fs.deinit();

    const Stream = FsEvent.Stream(TestFs);
    const paths = try test_fs.paths();

    const Cb = struct {
        fn callback(info: ?*TestFs, events: []Event) void {
            info.?.appendEvents(events) catch {
                std.log.warn("append events to TestFs failed", .{});
            };
        }
    };
    const flags = StreamCreateFlags{ .file_events = true };
    var stream = try Stream.init(a, &test_fs, Cb.callback, paths, 1.0, flags);
    defer stream.deinit();

    const dispatch_q = DispatchQueue{ .label = "my dispatch q" };
    const started = try stream.start(Event.Id.since_now, dispatch_q);
    try expect(started == true);

    try test_fs.exec();

    const delay_ns = 2_500_000_000;
    std.time.sleep(delay_ns);
    try expect(try test_fs.checkResults(2000));

    // while (true) {}
}

test "CF utils" {
    const alloc = testing.allocator;

    const cf_str = stringToCFString("foo");
    try expect(cf_str != null);

    const arr = [2][:0]const u8{ "foo", "bar" };
    const cf_str_arr = try createCFStringArray(alloc, &arr);
    try expect(cf_str_arr != null);
}

const TestFs = struct {
    const fs = std.fs;
    const log = std.log.warn;

    arena: *ArenaAllocator,
    tmp_dir: testing.TmpDir,
    scenarios: []const Scenario,
    events_in: std.ArrayList(Event),

    var root_a_b_c: fs.File = undefined;

    const Scenario = struct {
        name: []const u8,
        exec: *const fn (name: []const u8) anyerror!void,
        expected_event: Event,
    };

    fn init(arena: *ArenaAllocator) !TestFs {
        const alloc = arena.allocator();

        var tmp_dir = testing.tmpDir(.{});
        try TestFs.makeTestFs(tmp_dir);
        return .{
            .arena = arena,
            .tmp_dir = tmp_dir,
            .scenarios = try makeScenarios(alloc, tmp_dir),
            .events_in = std.ArrayList(Event).init(alloc),
        };
    }
    fn deinit(tfs: *TestFs) void {
        tfs.tmp_dir.cleanup();
        tfs.events_in.deinit();
        tfs.arena.deinit();
    }
    const Funcs = struct {
        fn logScenario(name: []const u8) !void {
            log("running scenario: {s}", .{name});
        }
        fn doSomething(name: []const u8) !void {
            log("running scenario: {s}", .{name});
        }
    };
    fn makeScenarios(alloc: Allocator, dir: testing.TmpDir) ![]Scenario {
        const root = try dir.dir.realpathAlloc(alloc, "root");
        const a_b_c = try std.fmt.allocPrint(alloc, "{s}/a/b/c", .{root});

        var scenarios = std.ArrayList(Scenario).init(alloc);
        defer scenarios.deinit();
        try scenarios.append(.{
            .expected_event = Event{
                .flags = Event.Flags{ .item_is_file = true, .item_xattr_mod = true, .item_created = true },
                .path = a_b_c,
                .id = Event.Id{ .value = 0x0 },
            },
            .name = try std.fmt.allocPrint(alloc, "create root/a/b/c file", .{}),
            .exec = Funcs.logScenario,
        });

        return scenarios.toOwnedSlice();
    }

    fn exec(tfs: *TestFs) !void {
        log("running test scenarios...", .{});
        for (tfs.scenarios) |s| {
            try s.exec(s.name);
        }
    }
    fn appendEvents(tfs: *TestFs, events: []Event) !void {
        log("received {d} events:", .{events.len});
        const alloc = tfs.arena.allocator();
        for (events) |e| {
            const str = e.print(alloc) catch "Error has occurred when printing event value";
            log("{s}", .{str});
        }
        tfs.events_in.appendSlice(events) catch {
            log("adding events to the list failed", .{});
        };
    }
    fn checkResults(tfs: *TestFs, timeout_ms: u64) !bool {
        const alloc = tfs.arena.allocator();
        const actual_events = tfs.events_in.items;

        var unprocessed_events = try std.ArrayList(Event).initCapacity(alloc, actual_events.len);
        try unprocessed_events.appendSlice(actual_events);
        var unprocessed_scenarios = try std.ArrayList(Scenario).initCapacity(alloc, tfs.scenarios.len);
        try unprocessed_scenarios.appendSlice(tfs.scenarios);

        var matched_events = try std.ArrayList(Event).initCapacity(alloc, actual_events.len);

        log("checking expected {d} events against {d} scenarios...", .{ actual_events.len, tfs.scenarios.len });

        var timer = try std.time.Timer.start();
        const timeout = timeout_ms * 1_000_000;
        while (timer.read() < timeout) {
            if (unprocessed_events.items.len == 0) return true;
            for (unprocessed_events.items, 0..unprocessed_events.items.len) |act_event, ei| {
                for (unprocessed_scenarios.items) |scenario| {
                    if (eq_event(scenario.expected_event, act_event)) {
                        log("found match ", .{});
                        try matched_events.append(unprocessed_events.swapRemove(ei));
                    }
                }
                // try s.exec(s.name);
            }
        }

        return false;
    }
    fn eq_event(e1: Event, e2: Event) bool {
        return @as(u32, @bitCast(e1.flags)) == @as(u32, @bitCast(e2.flags)) and std.mem.eql(u8, e1.path, e2.path);
    }
    fn paths(tfs: *TestFs) ![]const []const u8 {
        const alloc = tfs.arena.allocator();
        const root = try tfs.tmp_dir.dir.realpathAlloc(alloc, "root");

        const a = try std.fmt.allocPrint(alloc, "{s}/a", .{root});
        const d = try std.fmt.allocPrint(alloc, "{s}/d", .{root});

        var ps = try alloc.alloc([]const u8, 2);
        ps[0] = a;
        ps[1] = d;

        return ps;
    }

    /// create a simple nested directory structure for testing
    /// /root
    ///   /a
    ///     /b
    ///       c
    ///   /d
    ///     e
    ///   f
    fn makeTestFs(dir: testing.TmpDir) !void {
        try dir.dir.makePath("root");
        try dir.dir.makePath("root/a/b");
        try dir.dir.makePath("root/d");
        TestFs.root_a_b_c = try dir.dir.createFile("root/a/b/c", .{});
        _ = try dir.dir.createFile("root/d/e", .{});
        _ = try dir.dir.createFile("root/f", .{});
    }
};
