const std = @import("std");
const builtin = @import("builtin");
const slimy = @import("slimy.zig");
const SearchBlock = @import("cpu/SearchBlock.zig");

pub fn search(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) !void {
    std.debug.assert(params.method == .cpu);
    std.debug.assert(params.method.cpu > 0);
    if (params.method.cpu == 1) {
        searchSinglethread(params, context, resultCallback, progressCallback);
    } else if (builtin.single_threaded) {
        unreachable;
    } else {
        try searchMultithread(params, context, resultCallback, progressCallback);
    }
}

pub fn searchSinglethread(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) void {
    std.debug.assert(params.method == .cpu);
    std.debug.assert(params.method.cpu == 1);
    std.debug.assert(params.x0 < params.x1);
    std.debug.assert(params.z0 < params.z1);
    const block_size = SearchBlock.tested_size;
    var completed_chunks: usize = 0;
    const width: u64 = @intCast(params.x1 - params.x0);
    const height: u64 = @intCast(params.z1 - params.z0);
    const total_chunks = width * height;

    var block: SearchBlock = undefined;
    var x = params.x0;
    while (x < params.x1) : (x += block_size) {
        var z = params.z0;
        while (z < params.z1) : (z += block_size) {
            block.min_x = x - SearchBlock.offset;
            block.min_z = z - SearchBlock.offset;
            _ = block.calculateSliminess(params, context, resultCallback);
            completed_chunks += block_size * block_size;
            (progressCallback orelse continue)(context, completed_chunks, total_chunks);
        }
    }
}

/// Shared context passed to each worker thread.
const SharedCtx = struct {
    buf: []slimy.Result,
    count: std.atomic.Value(usize),
    blocks_done: std.atomic.Value(usize) = .init(0),
    done: std.atomic.Value(bool) = .init(false),

    fn append(ctx: *SharedCtx, res: slimy.Result) void {
        const idx = ctx.count.fetchAdd(1, .monotonic);
        if (idx < ctx.buf.len) {
            ctx.buf[idx] = res;
        }
    }
};

pub fn searchMultithread(
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) !void {
    std.debug.assert(params.method == .cpu);
    std.debug.assert(params.method.cpu > 1);
    std.debug.assert(params.x0 < params.x1);
    std.debug.assert(params.z0 < params.z1);

    const thread_count = params.method.cpu;

    // Worker stack needs: data[(size+1)²] + call frames (~4KB)
    const worker_stack_size = (SearchBlock.size + 1) * (SearchBlock.size + 1) + 4096;

    const block_size = SearchBlock.tested_size;
    const blocks_x = std.math.divCeil(usize, @intCast(params.x1 - params.x0), block_size) catch unreachable;
    const blocks_z = std.math.divCeil(usize, @intCast(params.z1 - params.z0), block_size) catch unreachable;
    const total_blocks = blocks_x * blocks_z;

    // Shared result buffer with atomic index. 1M entries is more than enough
    // for any practical threshold (max would be total_blocks * 240², threshold=0).
    const result_buf = try std.heap.page_allocator.alloc(slimy.Result, 1 << 20); // 1M = ~12MB
    defer std.heap.page_allocator.free(result_buf);
    var shared: SharedCtx = .{ .buf = result_buf, .count = .init(0) };

    // Spawn progress reporter thread (polls atomic, wakes every 250ms)
    var maybe_progress_reporter: ?std.Thread = null;
    if (progressCallback) |cb| {
        const Reporter = struct {
            fn run(ctx2: @TypeOf(context), cb2: @TypeOf(cb), sh: *SharedCtx, total: usize) void {
                while (!sh.done.load(.acquire)) {
                    std.Thread.sleep(250 * std.time.ns_per_ms);
                    cb2(ctx2, sh.blocks_done.load(.acquire), total);
                }
                cb2(ctx2, total, total);
            }
        };
        maybe_progress_reporter = try .spawn(.{ .stack_size = 16 * 1024 }, Reporter.run, .{ context, cb, &shared, total_blocks });
    }

    // Spawn result reporter thread if output_during_search is enabled
    var maybe_result_reporter: ?std.Thread = null;
    if (params.report_during_search) {
        const ResultReporter = struct {
            fn run(res_ctx: @TypeOf(context), res_cb: @TypeOf(resultCallback), sh: *SharedCtx) void {
                var emitted: usize = 0;
                while (!sh.done.load(.acquire)) {
                    const n = sh.count.load(.acquire);
                    while (emitted < n) : (emitted += 1) {
                        if (emitted < sh.buf.len) {
                            res_cb(res_ctx, sh.buf[emitted]);
                        }
                    }
                    std.Thread.sleep(50 * std.time.ns_per_ms);
                }
                // Emit any remaining results
                const n = sh.count.load(.acquire);
                while (emitted < n) : (emitted += 1) {
                    if (emitted < sh.buf.len) {
                        res_cb(res_ctx, sh.buf[emitted]);
                    }
                }
            }
        };
        maybe_result_reporter = try .spawn(.{ .stack_size = 16 * 1024 }, ResultReporter.run, .{ context, resultCallback, &shared });
    }

    const threads = try std.heap.page_allocator.alloc(std.Thread, thread_count);
    defer std.heap.page_allocator.free(threads);
    for (threads, 0..) |*thread, thread_index| {
        thread.* = try .spawn(.{ .stack_size = worker_stack_size }, worker, .{
            params,
            &shared,
            thread_index,
            thread_count,
            blocks_x,
            total_blocks,
        });
        std.log.scoped(.thread).debug("spawned thread {}", .{thread_index});
    }
    std.Thread.yield() catch {};
    for (threads) |thread| {
        thread.join();
    }

    shared.done.store(true, .release);
    if (maybe_progress_reporter) |r| r.join();
    if (maybe_result_reporter) |r| r.join();

    // Emit results after join only if not already emitted by the reporter thread
    if (!params.report_during_search) {
        const n = shared.count.load(.acquire);
        for (result_buf[0..@min(n, result_buf.len)]) |res| {
            resultCallback(context, res);
        }
    }
}

fn worker(
    params: slimy.SearchParams,
    shared: *SharedCtx,
    thread_id: usize,
    thread_count: usize,
    blocks_x: usize,
    total_blocks: usize,
) !void {
    std.log.scoped(.thread).debug("thread {} entered", .{thread_id});
    const block_size = SearchBlock.tested_size;

    const start_block = total_blocks * thread_id / thread_count;
    const end_block = total_blocks * (thread_id + 1) / thread_count;

    var chunk: SearchBlock = undefined;
    for (start_block..end_block) |block_index| {
        const rel_block_x = block_index / blocks_x;
        const rel_block_z = @mod(block_index, blocks_x);
        chunk.min_x = params.x0 + @as(i32, @intCast(rel_block_x * block_size)) - SearchBlock.offset;
        chunk.min_z = params.z0 + @as(i32, @intCast(rel_block_z * block_size)) - SearchBlock.offset;
        _ = chunk.calculateSliminess(params, shared, SharedCtx.append);
        _ = shared.blocks_done.fetchAdd(1, .monotonic);
    }

    std.log.scoped(.thread).debug("thread {} finished", .{thread_id});
}
