//! Shared helpers for the example programs: logging without `std.fmt`
//! (which would dominate the size of these small modules) and the
//! translator's `wasdon` intrinsics.

extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(ptr: [*]const u8, len: usize) void;

pub fn log(s: []const u8) void {
    @"UnityEngineDebug.__Log__SystemString__SystemVoid"(s.ptr, s.len);
}

/// `byte[]` interop (`docs/spec_host_import_conversion.md`): handles are
/// opaque object references, valid only as extern arguments.
pub const bytes = struct {
    extern "wasdon" fn bytes_new(ptr: [*]const u8, len: usize) i32;
    extern "wasdon" fn bytes_len(handle: i32) i32;
    extern "wasdon" fn bytes_read(handle: i32, offset: i32, ptr: [*]u8, len: usize) void;

    pub fn new(data: []const u8) i32 {
        return bytes_new(data.ptr, data.len);
    }
    pub fn len(handle: i32) usize {
        return @intCast(bytes_len(handle));
    }
    pub fn read(handle: i32, offset: usize, out: []u8) void {
        bytes_read(handle, @intCast(offset), out.ptr, out.len);
    }
};

/// One log line assembled in a fixed buffer.
pub const Line = struct {
    buf: [160]u8 = undefined,
    len: usize = 0,

    pub fn char(self: *Line, c: u8) *Line {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
        return self;
    }

    pub fn str(self: *Line, s: []const u8) *Line {
        for (s) |c| _ = self.char(c);
        return self;
    }

    pub fn int(self: *Line, value: i64) *Line {
        var digits: [20]u8 = undefined;
        var n: usize = 0;
        var v: u64 = if (value < 0) @intCast(-value) else @intCast(value);
        while (true) {
            digits[n] = @intCast('0' + v % 10);
            n += 1;
            v /= 10;
            if (v == 0) break;
        }
        if (value < 0) _ = self.char('-');
        while (n > 0) {
            n -= 1;
            _ = self.char(digits[n]);
        }
        return self;
    }

    pub fn hex(self: *Line, value: u32) *Line {
        var shift: u6 = 32;
        while (shift > 0) {
            shift -= 4;
            _ = self.char("0123456789abcdef"[@intCast((value >> @intCast(shift)) & 0xF)]);
        }
        return self;
    }

    pub fn flush(self: *Line) void {
        log(self.buf[0..self.len]);
        self.len = 0;
    }
};

/// FNV-1a, for summarising buffers in logs.
pub fn hash(data: []const u8) u32 {
    var h: u32 = 0x811C9DC5;
    for (data) |b| h = (h ^ b) *% 0x01000193;
    return h;
}
