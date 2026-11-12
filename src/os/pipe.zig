const std = @import("std");
const builtin = @import("builtin");
const windows = @import("windows.zig");
const posix = std.posix;
const compat_fd = @import("../lib/compat/fd.zig");

/// pipe() that works on Windows and POSIX. For POSIX systems, this sets
/// CLOEXEC on the file descriptors.
pub fn pipe() ![2]posix.fd_t {
    switch (builtin.target.os.tag) {
        else => return compat_fd.pipe2(.{ .CLOEXEC = true }),
        .windows => {
            var read: windows.HANDLE = undefined;
            var write: windows.HANDLE = undefined;
            if (windows.exp.kernel32.CreatePipe(&read, &write, null, 0) == windows.FALSE) {
                return windows.unexpectedError(windows.GetLastError());
            }

            return .{ read, write };
        },
    }
}

/// Close a handle returned by `pipe`.
///
/// On Windows these are kernel HANDLEs, not POSIX file descriptors, so the
/// libc `close` that `std.posix.system.close` resolves to there is the
/// wrong call (and not even exported by the UCRT under that name).
pub const closePipe = if (builtin.target.os.tag == .windows)
    closePipeWindows
else
    closePipePosix;

fn closePipeWindows(fd: posix.fd_t) void {
    _ = windows.exp.kernel32.CloseHandle(fd);
}

fn closePipePosix(fd: posix.fd_t) void {
    compat_fd.close(fd);
}

/// Write all of `data` to a pipe handle returned by `pipe`.
pub const writePipe = if (builtin.target.os.tag == .windows)
    writePipeWindows
else
    writePipePosix;

fn writePipeWindows(fd: posix.fd_t, data: []const u8) !void {
    var written: windows.DWORD = 0;
    if (windows.exp.kernel32.WriteFile(
        fd,
        @ptrCast(@constCast(data.ptr)),
        @intCast(data.len),
        &written,
        null,
    ) == windows.FALSE) {
        return windows.unexpectedError(windows.GetLastError());
    }
}

fn writePipePosix(fd: posix.fd_t, data: []const u8) !void {
    var written: usize = 0;
    while (written < data.len) {
        written += try posix.write(fd, data[written..]);
    }
}
