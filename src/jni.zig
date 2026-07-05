const std = @import("std");
const jni = @import("jni");
const slimy = @import("slimy.zig");

var result_count: std.atomic.Value(usize) = .init(0);

fn appendResult(ctx: *[]u8, res: slimy.Result) void {
    const idx = result_count.fetchAdd(1, .monotonic);
    const pos = idx * 12; // 3 ints × 4 bytes
    if (pos + 12 <= ctx.len) {
        const p: [*]u8 = ctx.ptr;
        @as(*align(1) i32, @ptrCast(p + pos)).* = res.x;
        @as(*align(1) i32, @ptrCast(p + pos + 4)).* = res.z;
        @as(*align(1) i32, @ptrCast(p + pos + 8)).* = @bitCast(res.count);
    }
}

pub fn search(
    env: *jni.cEnv,
    _: jni.jclass,
    world_seed: jni.jlong,
    x0: jni.jint,
    z0: jni.jint,
    x1: jni.jint,
    z1: jni.jint,
    threshold: jni.jint,
    max_results: jni.jint,
    thread_count: jni.jint,
) callconv(.c) jni.jintArray {
    const jenv = jni.JNIEnv.warp(env);

    const mr: usize = @intCast(@max(1, max_results));
    const buf_size = mr * 12;
    const buf = std.heap.page_allocator.alloc(u8, buf_size) catch return null;
    defer std.heap.page_allocator.free(buf);

    var ctx: []u8 = buf;
    result_count.store(0, .release);

    slimy.cpu.search(.{
        .world_seed = world_seed,
        .threshold = @intCast(threshold),
        .x0 = x0,
        .z0 = z0,
        .x1 = x1,
        .z1 = z1,
        .method = .{ .cpu = @intCast(@max(1, thread_count)) },
        .max_results = mr,
    }, &ctx, appendResult, null) catch {};

    const n = @min(result_count.load(.acquire), mr);

    // Sort results (matches CLI behavior)
    const results: [*]slimy.Result = @ptrCast(@alignCast(buf.ptr));
    std.sort.block(slimy.Result, results[0..n], {}, slimy.Result.sortLessThan);

    // Write sorted results as flat int array
    const total_ints: jni.jsize = @intCast(n * 3);
    if (n > 0) {
        var out: [*]jni.jint = @ptrCast(@alignCast(buf.ptr));
        for (0..n) |i| {
            const r = results[i];
            out[i * 3] = r.x;
            out[i * 3 + 1] = r.z;
            out[i * 3 + 2] = @bitCast(r.count);
        }
    }

    const arr = jenv.newPrimitiveArray(jni.jint, total_ints) orelse return null;
    if (total_ints > 0) {
        jenv.setArrayRegion(jni.jint, arr, 0, total_ints, @ptrCast(@alignCast(buf.ptr)));
    }
    return arr;
}

comptime {
    jni.exportJNI("SlimyJNI", @This());
}
