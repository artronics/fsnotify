const std = @import("std");
const testing = std.testing;
const expect = testing.expect;

pub const Handle = struct {
    id: usize,
};

pub const Monitor = struct {
    path: []const u8,
};

pub const Event = union(enum) {
    FileCreated: void,
};

pub const EventCallback = fn (handle: Handle, event: Event) void;

test "fsnotify" {}
