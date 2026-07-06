const std = @import("std");
const scalar = @import("slime_check.zig").scalar;
const simd = @import("slime_check.zig").simd;
const slimy = @import("../slimy.zig");

pub const size = @import("build_opts").size;
pub const window_size: comptime_int = 17;
pub const tested_size: comptime_int = size - window_size + 1;
pub const offset: comptime_int = @divFloor(window_size, 2);

const lanes = simd.lanes;
const Cell = @Vector(lanes, u8);

/// Minecraft despawn sphere mask using chunk-border distances.
/// dis:  shortest distance between chunk borders → must be ≤ 7.75 (~124 blocks)
/// dis2: farthest distance between chunk borders → must be ≥ 1.5 (~24 blocks)
/// This models: within 128-block despawn range, but outside 24-block no-spawn zone.
const donut_mask: [window_size][window_size]bool = blk: {
    var m: [window_size][window_size]bool = undefined;
    for (0..window_size) |dx| {
        for (0..window_size) |dz| {
            const rx = @as(i32, @intCast(dx)) - offset;
            const rz = @as(i32, @intCast(dz)) - offset;
            // Shortest distance: shrink each dimension inward by 1 if non-zero
            const sx: i32 = if (rx > 0) rx - 1 else if (rx < 0) rx + 1 else 0;
            const sz: i32 = if (rz > 0) rz - 1 else if (rz < 0) rz + 1 else 0;
            const d_min: f32 = @floatFromInt(sx * sx + sz * sz);
            // Farthest distance: expand each dimension outward by 1 if non-zero
            const lx: i32 = if (rx > 0) rx + 1 else if (rx < 0) rx - 1 else 0;
            const lz: i32 = if (rz > 0) rz + 1 else if (rz < 0) rz - 1 else 0;
            const d_max: f32 = @floatFromInt(lx * lx + lz * lz);
            m[dx][dz] = @sqrt(d_min) <= 7.5 and @sqrt(d_max) >= 1.5;
        }
    }
    break :blk m;
};

/// Contiguous horizontal runs in the donut, for prefix sum queries (20 total).
const DonutRun = struct { dx: u5, c1: u5, c2: u5 };
const donut_runs: [18]DonutRun = blk: {
    var runs: [18]DonutRun = undefined;
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
    if (n != 18) @compileError("donut_runs mismatch");
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

    // Row 0: compute base, slime check → scan → write prefix row 1
    {
        const base: i64 = simd.computeBase(params.world_seed, self.min_x);
        var carry: u8 = 0;
        for (0..size / lanes) |j| {
            const rel_z = j * lanes;
            const raw: Cell = simd.areSlimeBiasedFromBase(base, self.min_z + @as(i32, @intCast(rel_z)));
            const col = rel_z + 1;
            const v = scanCell(raw, &carry);
            @as(*[lanes]u8, @ptrCast(&self.data[1][col])).* = @bitCast(v);
        }
    }

    // Remaining rows: compute base per row (hoisted from inner cell loop)
    for (1..size) |row| {
        const prow = row + 1;
        const base: i64 = simd.computeBase(params.world_seed, self.min_x + @as(i32, @intCast(row)));
        var carry: u8 = 0;
        for (0..size / lanes) |j| {
            const rel_z = j * lanes;
            const col = rel_z + 1;
            const raw: Cell = simd.areSlimeBiasedFromBase(base, self.min_z + @as(i32, @intCast(rel_z)));
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
