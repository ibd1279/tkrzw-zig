const std = @import("std");
const lib_common = @import("lib_common.zig");
pub const Status = lib_common.Status;

pub const RecordAction = union(enum) {
    noop,
    remove,
    set: []const u8,
};

pub const UpdateLogger = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        writeSet: *const fn (ctx: *anyopaque, key: []const u8, value: []const u8) Status,
        writeRemove: *const fn (ctx: *anyopaque, key: []const u8) Status,
        writeClear: *const fn (ctx: *anyopaque) Status,
        synchronize: ?*const fn (ctx: *anyopaque, hard: bool) Status = null,
    };

    pub fn writeSet(self: UpdateLogger, key: []const u8, value: []const u8) Status {
        return self.vtable.writeSet(self.ctx, key, value);
    }

    pub fn writeRemove(self: UpdateLogger, key: []const u8) Status {
        return self.vtable.writeRemove(self.ctx, key);
    }

    pub fn writeClear(self: UpdateLogger) Status {
        return self.vtable.writeClear(self.ctx);
    }

    pub fn synchronize(self: UpdateLogger, hard: bool) Status {
        if (self.vtable.synchronize) |f| return f(self.ctx, hard);
        return Status.init(.SUCCESS);
    }
};

pub const CompareExpected = union(enum) {
    absent,
    any,
    exact: []const u8,
};

pub const CompareDesired = union(enum) {
    remove,
    noop,
    set: []const u8,
};
