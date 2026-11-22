//! Minimal Windows console helpers: UTF-8 output mode, VT (ANSI) processing
//! and a real "is stdout a console" check. No-ops elsewhere.
//!
//! Windows has no `isatty(3)`; isatty-like behavior requires GetConsoleMode
//! to succeed on the stdout handle. Console code page is switched to UTF-8
//! and virtual terminal processing is enabled so ANSI escape sequences and
//! non-ASCII output render correctly on Windows 10+.

const std = @import("std");

const STD_OUTPUT_HANDLE: u32 = 0xFFFFFFF5; // (DWORD)-11
const ENABLE_VIRTUAL_TERMINAL_PROCESSING: u32 = 0x0004;
const CP_UTF8: u32 = 65001;
const INVALID_HANDLE: usize = std.math.maxInt(usize);

extern "kernel32" fn GetStdHandle(nStdHandle: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetConsoleMode(hConsole: *anyopaque, lpMode: *u32) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleMode(hConsole: *anyopaque, dwMode: u32) callconv(.winapi) c_int;
extern "kernel32" fn SetConsoleOutputCP(wCodePageID: u32) callconv(.winapi) c_int;

const is_windows = @import("builtin").os.tag == .windows;

fn stdoutHandle() ?*anyopaque {
    const h = GetStdHandle(STD_OUTPUT_HANDLE) orelse return null;
    if (@intFromPtr(h) == INVALID_HANDLE) return null;
    return h;
}

pub fn stdoutIsTty() bool {
    if (!is_windows) return std.c.isatty(1) != 0;
    const h = stdoutHandle() orelse return false;
    var mode: u32 = 0;
    return GetConsoleMode(h, &mode) != 0;
}

/// Enable UTF-8 output and ANSI escape sequence processing. No-op elsewhere.
pub fn enableVirtualTerminal() void {
    if (!is_windows) return;
    const h = stdoutHandle() orelse return;
    var mode: u32 = 0;
    if (GetConsoleMode(h, &mode) == 0) return;
    _ = SetConsoleOutputCP(CP_UTF8);
    _ = SetConsoleMode(h, mode | ENABLE_VIRTUAL_TERMINAL_PROCESSING);
}
