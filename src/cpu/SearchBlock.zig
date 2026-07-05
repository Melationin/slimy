const std = @import("std");
const scalar = @import("slime_check.zig").scalar;
const simd = @import("slime_check.zig").simd;
const slimy = @import("../slimy.zig");

pub const size = 512;
pub const window_size: comptime_int = 17;
pub const tested_size: comptime_int = size - window_size + 1;
pub const offset: comptime_int = @divFloor(window_size, 2);

const lanes = simd.lanes;
const Cell = @Vector(lanes, u8);

/// Minecraft despawn sphere mask: inner radius 1 < d² ≤ outer radius 8 (17×17 donut)
const donut_mask: [window_size][window_size]bool = blk: {
    const inner = 1;
    const outer = 8;
    var m: [window_size][window_size]bool = undefined;
    for (0..window_size) |dx| {
        for (0..window_size) |dz| {
            const rx = @as(i32, @intCast(dx)) - offset;
            const rz = @as(i32, @intCast(dz)) - offset;
            const d2 = rx * rx + rz * rz;
            m[dx][dz] = inner * inner < d2 and d2 <= outer * outer;
        }
    }
    break :blk m;
};

/// Contiguous horizontal runs in the donut, for prefix sum queries (20 total).
const DonutRun = struct { dx: u5, c1: u5, c2: u5 };
const donut_runs: [20]DonutRun = blk: {
    var runs: [20]DonutRun = undefined;
    var n: usize = 0;
    for (0..window_size) |dx| {
        var in_run = false;
        var start: u5 = 0;
        for (0..window_size) |dz| {
            if (donut_mask[dx][dz] and !in_run) {
                start = @intCast(dz);
                in_run = true;
            } else if (!donut_mask[dx][dz] and in_run) {
                runs[n] = .{ .dx = @intCast(dx), .c1 = start, .c2 = @intCast(dz - 1) };
                n += 1;
                in_run = false;
            }
        }
        if (in_run) {
            runs[n] = .{ .dx = @intCast(dx), .c1 = start, .c2 = @intCast(window_size - 1) };
            n += 1;
        }
    }
    if (n != 20) @compileError("donut_runs mismatch");
    break :blk runs;
};

comptime { if (@mod(size, lanes) != 0) @compileError("size must be a multiple of lanes"); }

/// Zero-padded 2D array: row 0 & col 0 = padding. Holds the 2D prefix sum after calculateSliminess.
data: [size + 1][size + 1]u8,
min_x: i32,
min_z: i32,

/// O(log lanes) parallel prefix sum via @shuffle tree.
inline fn scanCell(v: Cell, carry: *u8) Cell {
    const zero = @as(Cell, @splat(0));
    var result = v;
    comptime var shift: comptime_int = 1;
    inline while (shift < lanes) : (shift <<= 1) {
        comptime var mask: [lanes]i32 = undefined;
        inline for (0..lanes) |i| {
            mask[i] = if (i < shift) @as(i32, -1) else @as(i32, @intCast(i - shift));
        }
        result +%= @shuffle(u8, result, zero, mask);
    }
    result +%= @as(Cell, @splat(carry.*));
    carry.* = result[lanes - 1];
    return result;
}

pub fn calculateSliminess(
    self: *@This(),
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
) usize {
    // Zero padding
    for (0..size + 1) |i| {
        self.data[0][i] = 0;
        self.data[i][0] = 0;
    }

    // Row 0: SIMD slime check → scan → write prefix row 1
    {
        var carry: u8 = 0;
        for (0..size / lanes) |j| {
            const rel_z = j * lanes;
            const raw: Cell = simd.areSlimeBiased(params.world_seed, self.min_x, self.min_z + @as(i32, @intCast(rel_z)));
            const col = rel_z + 1;
            const v = scanCell(raw, &carry);
            @as(*[lanes]u8, @ptrCast(&self.data[1][col])).* = @bitCast(v);
        }
    }

    // Remaining rows: slime check → scan → +prev → write
    for (1..size) |row| {
        const prow = row + 1;
        const abs_x: i32 = self.min_x + @as(i32, @intCast(row));
        var carry: u8 = 0;
        for (0..size / lanes) |j| {
            const rel_z = j * lanes;
            const col = rel_z + 1;
            const raw: Cell = simd.areSlimeBiased(params.world_seed, abs_x, self.min_z + @as(i32, @intCast(rel_z)));
            var v: Cell = scanCell(raw, &carry);
            const prev: Cell = @bitCast(@as(*const [lanes]u8, @ptrCast(&self.data[row][col])).*);
            v +%= prev;
            @as(*[lanes]u8, @ptrCast(&self.data[prow][col])).* = @bitCast(v);
        }
    }

    var sufficiently_slimy_chunks: usize = 0;
    for (0..tested_size) |x| {
        for (0..tested_size) |z| {
            const count = self.data[x + window_size][z + window_size] -%
                self.data[x][z + window_size] -%
                self.data[x + window_size][z] +%
                self.data[x][z];

            if (count >= params.threshold) {
                const exact = exactDonutCount(self.data, x, z);
                if (exact >= params.threshold) {
                    sufficiently_slimy_chunks += 1;
                    const real_x = @as(i32, @intCast(x + offset)) + self.min_x;
                    const real_z = @as(i32, @intCast(z + offset)) + self.min_z;
                    if (real_x >= params.x0 and real_x < params.x1 and
                        real_z >= params.z0 and real_z < params.z1)
                    {
                        resultCallback(context, .{ .x = real_x, .z = real_z, .count = exact });
                    }
                }
            }
        }
    }
    return sufficiently_slimy_chunks;
}

fn exactDonutCount(d: [size + 1][size + 1]u8, x: usize, z: usize) u8 {
    var exact: u8 = 0;
    inline for (donut_runs) |run| {
        const pr = x + run.dx + 1;
        const pc1 = z + run.c1 + 1;
        const pc2 = z + run.c2 + 1;
        const s: u8 = d[pr][pc2] -%
            d[pr][pc1 - 1] -%
            d[pr - 1][pc2] +%
            d[pr - 1][pc1 - 1];
        exact +%= s;
    }
    return exact;
}

test calculateSliminess {
    const test_seed = 0x51133;
    var results: std.ArrayList(slimy.Result) = .empty;
    defer results.deinit(std.testing.allocator);

    var chunk: @This() = .{ .data = undefined, .min_x = -offset, .min_z = -offset };
    _ = chunk.calculateSliminess(
        .{ .x0 = 0, .x1 = size, .z0 = 0, .z1 = size, .method = undefined, .threshold = 0, .world_seed = test_seed },
        &results,
        struct {
            fn cb(ctx: *std.ArrayList(slimy.Result), res: slimy.Result) void {
                ctx.append(std.testing.allocator, res) catch {};
            }
        }.cb,
    );

    try std.testing.expectEqual(tested_size * tested_size, results.items.len);
    for (results.items) |result| {
        var expected: u8 = 0;
        for (0..window_size) |dx| {
            for (0..window_size) |dz| {
                if (donut_mask[dx][dz] and scalar.isSlime(
                    test_seed,
                    result.x + @as(i32, @intCast(dx)) - offset,
                    result.z + @as(i32, @intCast(dz)) - offset,
                )) expected += 1;
            }
        }
        try std.testing.expectEqual(expected, result.count);
    }
}
