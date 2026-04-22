//! WASM テストベンチ。
//!
//! 想定ホスト環境は「.NET の `Console.WriteLine(string)` だけが import されている」。
//! WASM 側はその一引数を `(ptr, len)` のペアで渡す。Udon 翻訳器側ではこの import を
//! `SystemConsole.__WriteLine__SystemString__SystemVoid` EXTERN にマップし、
//! linear memory モデル (`docs/spec_linear_memory.md`) から `len` バイトを読み出して
//! SystemString に詰め直してから push する想定。

const std = @import("std");

// Import 名そのものを Udon extern シグネチャとして記述し、翻訳器側で
// ハードコードなしに EXTERN 命令を生成させる (docs/spec_host_import_conversion.md)。
// Zig の raw-identifier 記法 `@"..."` で `.` や `_` を含む自由な名前が書ける。
// `extern "c"` は libc 依存を要求してしまうため freestanding では使えない。
extern "env" fn @"SystemConsole.__WriteLine__SystemString__SystemVoid"(
    ptr: [*]const u8,
    len: usize,
) void;

// もう 1 種類: `UnityEngine.Debug.Log(object)` への別ルート。
// 同じ generic pass-through を経由し、翻訳器を改変せずに 2 番目の extern を
// 利用できることを示す (docs/spec_host_import_conversion.md §"Worked Example" 末尾)。
extern "env" fn @"UnityEngineDebug.__Log__SystemString__SystemVoid"(
    ptr: [*]const u8,
    len: usize,
) void;

fn log(s: []const u8) void {
    @"SystemConsole.__WriteLine__SystemString__SystemVoid"(s.ptr, s.len);
}

var fmt_buf: [512]u8 = undefined;

fn logf(comptime format: []const u8, args: anytype) void {
    const s = std.fmt.bufPrint(&fmt_buf, format, args) catch return;
    log(s);
}

// グローバル (翻訳器の __G__ 命名規則テスト用)。
// `export` を付けて WASM global として明示的にエクスポートする。
// これがないと Zig はデータセクションに置いてしまい、__udon_meta の
// `"source": {"kind":"global","name":"counter"}` が解決できない。
export var counter: i32 = 0;
export var accum: i64 = 0;
export var update_tick: i32 = 0;

// リニアメモリで使う static buffer
var scratch: [256]u32 = [_]u32{0} ** 256;

// __udon_meta: data segment + 2 export 関数 (どちらも i32 を返す)
const udon_meta_json =
    \\{
    \\  "version": 1,
    \\  "behaviour": { "syncMode": "manual" },
    \\  "functions": {
    \\    "start":    { "source": {"kind":"export","name":"on_start"},    "label":"_start",    "export": true, "event":"Start"    },
    \\    "update":   { "source": {"kind":"export","name":"on_update"},   "label":"_update",   "export": true, "event":"Update"   },
    \\    "interact": { "source": {"kind":"export","name":"on_interact"}, "label":"_interact", "export": true, "event":"Interact" }
    \\  },
    \\  "fields": {
    \\    "counter":     { "source": {"kind":"global","name":"counter"},     "udonName":"_counter",     "type":"int",  "export": true },
    \\    "accum":       { "source": {"kind":"global","name":"accum"},       "udonName":"_accum",       "type":"int" },
    \\    "update_tick": { "source": {"kind":"global","name":"update_tick"}, "udonName":"_updateTick",  "type":"int" }
    \\  },
    \\  "options": {
    \\    "strict": false,
    \\    "memory": { "initialPages": 1, "maxPages": 16, "udonName": "_memory" }
    \\  }
    \\}
;

export fn __udon_meta_ptr() [*]const u8 {
    return udon_meta_json.ptr;
}

export fn __udon_meta_len() u32 {
    return @intCast(udon_meta_json.len);
}

// ==== test_arithmetic: 整数算術と比較 ====
fn test_arithmetic() void {
    log("== arithmetic ==");
    logf("1 + 2 = {d}", .{1 + 2});
    logf("100 * 200 = {d}", .{100 * 200});
    logf("-50 / 7 = {d}", .{@divTrunc(@as(i32, -50), 7)});
    logf("17 % 5 = {d}", .{@mod(@as(i32, 17), 5)});
    logf("1 << 10 = {d}", .{@as(i32, 1) << 10});
    logf("0x7F00 | 0x00FF = 0x{x}", .{@as(u32, 0x7F00) | 0x00FF});
    logf("0xABCD ^ 0x00FF = 0x{x}", .{@as(u32, 0xABCD) ^ 0x00FF});
}

// ==== test_control_flow: if / while / switch (br_table) ====
fn test_control_flow() void {
    log("== control_flow ==");

    var i: i32 = 0;
    while (i < 5) : (i += 1) logf("i = {d}", .{i});

    const x: i32 = 7;
    if (x > 5) log("x > 5") else log("x <= 5");

    const tag: i32 = 2;
    switch (tag) {
        0 => log("tag=0"),
        1 => log("tag=1"),
        2 => log("tag=2"),
        3 => log("tag=3"),
        else => log("tag=other"),
    }

    var sum: i32 = 0;
    var j: i32 = 1;
    while (j <= 10) : (j += 1) {
        if (@mod(j, 2) == 0) continue;
        sum += j;
    }
    logf("sum of odd 1..10 = {d}", .{sum}); // 25
}

// ==== test_globals: グローバル変数の読み書き ====
fn test_globals() void {
    log("== globals ==");
    counter = 0;
    var i: i32 = 0;
    while (i < 4) : (i += 1) counter += i;
    logf("counter = {d}", .{counter}); // 6

    accum = 0;
    var k: i64 = 1;
    while (k <= 5) : (k += 1) accum += k;
    logf("accum = {d}", .{accum}); // 15
}

// ==== test_recursion: factorial / fibonacci ====
fn factorial(n: i32) i32 {
    if (n <= 1) return 1;
    return n * factorial(n - 1);
}

fn fib(n: i32) i32 {
    if (n < 2) return n;
    return fib(n - 1) + fib(n - 2);
}

fn test_recursion() void {
    log("== recursion ==");
    logf("factorial(5) = {d}", .{factorial(5)}); // 120
    logf("fib(10) = {d}", .{fib(10)}); // 55
}

// ==== test_memory: linear memory への i32 / 部分バイトアクセスと memory.grow ====
fn test_memory() void {
    log("== memory ==");

    scratch[0] = 0xDEADBEEF;
    scratch[1] = 42;
    logf("scratch[0] = 0x{x}", .{scratch[0]}); // DEADBEEF
    logf("scratch[1] = {d}", .{scratch[1]}); // 42

    const bytes: [*]u8 = @ptrCast(&scratch[0]);
    bytes[8] = 0x11;
    bytes[9] = 0x22;
    bytes[10] = 0x33;
    bytes[11] = 0x44;
    logf("scratch[2] (LE byte assemble) = 0x{x}", .{scratch[2]}); // 44332211

    const before: i32 = @intCast(@wasmMemorySize(0));
    const grew: i32 = @wasmMemoryGrow(0, 1);
    const after: i32 = @intCast(@wasmMemorySize(0));
    logf("memory.size before = {d} pages", .{before});
    logf("memory.grow returned = {d}", .{grew});
    logf("memory.size after  = {d} pages", .{after});
}

// ==== test_indirect_call: function pointer 経由 (call_indirect) ====
fn double_it(x: i32) i32 {
    return x * 2;
}

fn negate_it(x: i32) i32 {
    return -x;
}

fn add_one(x: i32) i32 {
    return x + 1;
}

const FnPtr = *const fn (i32) i32;
const ops = [_]FnPtr{ &double_it, &negate_it, &add_one };

fn test_indirect_call() void {
    log("== call_indirect ==");
    logf("double_it(21) = {d}", .{ops[0](21)}); // 42
    logf("negate_it(7) = {d}", .{ops[1](7)}); // -7
    logf("add_one(99) = {d}", .{ops[2](99)}); // 100
}

// ==== test_struct: 構造体のフィールドアクセス / by-value 渡し / by-pointer 渡し ====
// 翻訳器から見ると構造体は linear memory 上のオフセットアクセスに展開される。
// 各フィールドの i32.load/store offset=N が期待通り生成されるか確認するためのフィクスチャ。
const Point = struct {
    x: i32,
    y: i32,
};

const Rect = struct {
    tl: Point,
    br: Point,
    tag: i32,
};

fn point_area(p: Point) i32 {
    // by-value: wasm ABI 上は { x, y } が 2 つの i32 param に展開される。
    return p.x * p.y;
}

fn point_translate(p: *Point, dx: i32, dy: i32) void {
    // by-pointer: linear memory の offset=0 / offset=4 への store にコンパイルされる。
    p.x += dx;
    p.y += dy;
}

fn rect_width(r: *const Rect) i32 {
    return r.br.x - r.tl.x;
}

var g_rect: Rect = .{
    .tl = .{ .x = 1, .y = 2 },
    .br = .{ .x = 11, .y = 22 },
    .tag = 0x1234,
};

fn test_struct() void {
    log("== struct ==");

    // (1) by-value の単純な field access
    const p: Point = .{ .x = 6, .y = 7 };
    logf("point_area({{6,7}}) = {d}", .{point_area(p)}); // 42

    // (2) by-pointer の read-modify-write (linear memory offset store)
    var q: Point = .{ .x = 10, .y = 20 };
    point_translate(&q, 3, 4);
    logf("q after translate = ({d}, {d})", .{ q.x, q.y }); // (13, 24)

    // (3) ネストした構造体 + 読み取り専用ポインタ
    logf("rect_width(g_rect) = {d}", .{rect_width(&g_rect)}); // 10
    logf("g_rect.tag = 0x{x}", .{g_rect.tag}); // 1234

    // (4) struct の in-place 更新 (const default value がメモリにコピーされることの確認)
    g_rect.tag += 1;
    logf("g_rect.tag after inc = 0x{x}", .{g_rect.tag}); // 1235

    // (5) 配列内 struct のインデックスアクセス (複数要素のオフセット計算)
    var points: [3]Point = .{
        .{ .x = 1, .y = 1 },
        .{ .x = 2, .y = 4 },
        .{ .x = 3, .y = 9 },
    };
    var sum: i32 = 0;
    var i: usize = 0;
    while (i < points.len) : (i += 1) sum += point_area(points[i]);
    logf("sum of areas = {d}", .{sum}); // 1 + 8 + 27 = 36

    // (6) ポインタ経由で配列要素の構造体を書き換える
    point_translate(&points[1], 100, 200);
    logf("points[1] after translate = ({d}, {d})", .{ points[1].x, points[1].y }); // (102, 204)
}

// ==== test_64bit_and_float: i64 / f64 演算 ====
fn test_64bit_and_float() void {
    log("== 64bit_and_float ==");
    const a: i64 = 0x1_0000_0000;
    const b: i64 = 5;
    const r = a + b;
    logf("(0x100000000 + 5) hi32 = {d}", .{@as(i32, @intCast(r >> 32))}); // 1
    logf("(0x100000000 + 5) lo32 = {d}", .{@as(i32, @intCast(r & 0xFFFFFFFF))}); // 5

    const x: f64 = 3.14;
    const y: f64 = 2.0;
    const m = x * y; // 6.28
    logf("3.14 * 2.0 = {d}", .{m});
    logf("floor(m * 100) = {d}", .{@as(i32, @intFromFloat(@floor(m * 100.0)))}); // 628
}

// ==== exports: Udon イベントにマップされる ====
export fn on_start() void {
    log("=== on_start ===");
    test_arithmetic();
    test_control_flow();
    test_globals();
    test_recursion();
    test_memory();
    test_indirect_call();
    test_struct();
    test_64bit_and_float();
    log("=== on_start done ===");
}

export fn on_update() void {
    update_tick += 1;
}

export fn on_interact() void {
    counter += 1;
    logf("interact! counter = {d}", .{counter});
    // Generic pass-through 経由の 2 個目の extern を呼び出して、翻訳器が
    // 同じルートで異なるシグネチャを扱えることを確認する。
    const msg = "interact!";
    @"UnityEngineDebug.__Log__SystemString__SystemVoid"(msg.ptr, msg.len);
}
