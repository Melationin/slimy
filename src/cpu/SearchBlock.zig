const std = @import("std");
const scalar = @import("slime_check.zig").scalar;
const simd = @import("slime_check.zig").simd;
const slimy = @import("../slimy.zig");

pub const size = 512;
pub const window_size: comptime_int = 17;
pub const tested_size: comptime_int = size - window_size + 1;
pub const offset: comptime_int = @divFloor(window_size, 2);

const lanes = simd.lanes;
pub const Cell = @Vector(lanes, u8);

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

/// Contiguous horizontal runs in the donut mask, for prefix sum queries.
/// Rows 7/8/9 have two runs (gap at center); all others have one. Total: 20 runs.
const DonutRun = struct { dx: u5, c1: u5, c2: u5 };
const donut_runs_len: comptime_int = 20;
const donut_runs: [donut_runs_len]DonutRun = blk: {
    var runs: [donut_runs_len]DonutRun = undefined;
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
    if (n != donut_runs_len) @compileError("donut_runs_len mismatch");
    break :blk runs;
};

const cells_per_row = size / lanes;
comptime { if (@mod(size, lanes) != 0) @compileError("size must be a multiple of lanes"); }

data: [size * cells_per_row]Cell,
min_x: i32,
min_z: i32,

/// Initialize chunks with scalar code
pub fn initScalar(world_seed: i64, min_x: i32, min_z: i32) @This() {
    var chunk: @This() = .{
        .data = undefined,
        .min_x = min_x - offset,
        .min_z = min_z - offset,
    };
    for (0..size) |rel_x| {
        for (0..cells_per_row) |j| {
            const rel_z = j * lanes;
            var cell: Cell = undefined;
            inline for (0..lanes) |z_offset| {
                cell[z_offset] = @intFromBool(scalar.isSlime(
                    world_seed,
                    min_x - offset + @as(i32, @intCast(rel_x)),
                    min_z - offset + @as(i32, @intCast(rel_z + z_offset)),
                ));
            }
            chunk.data[rel_x * cells_per_row + j] = cell;
        }
    }
    return chunk;
}

/// Initialize chunks with simd routine
pub fn initSimd(world_seed: i64, min_x: i32, min_z: i32) @This() {
    var chunk: @This() = .{
        .data = undefined,
        .min_x = min_x - offset,
        .min_z = min_z - offset,
    };
    for (0..size) |rel_x| {
        for (0..cells_per_row) |j| {
            const rel_z = j * lanes;
            const abs_x: i32 = min_x - offset + @as(i32, @intCast(rel_x));
            const abs_z: i32 = min_z - offset + @as(i32, @intCast(rel_z));
            chunk.data[rel_x * cells_per_row + j] = simd.areSlimeBiased(world_seed, abs_x, abs_z);
        }
    }
    return chunk;
}

/// Parallel prefix sum of one Cell via @shuffle tree: O(log lanes) instead of O(lanes).
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

/// For every chunk within the searched area defined by this `SearchBlock`,
/// counts slime chunks in a 17×17 window centered at each position
/// and reports those meeting the given threshold.
/// Uses zero-padded 2D prefix sums: single unified formula, zero branches.
pub fn calculateSliminess(
    self: *@This(),
    params: slimy.SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), slimy.Result) void,
) usize {
    // Scalar prefix for O(1) queries
    var prefix: [size + 1][size + 1]u8 = undefined;

    for (0..size + 1) |i| {
        prefix[0][i] = 0;
        prefix[i][0] = 0;
    }

    // Row 0 → prefix row 1: horizontal SIMD scan only (no previous row)
    {
        var carry: u8 = 0;
        for (0..cells_per_row) |j| {
            const col = j * lanes;
            const v = scanCell(self.data[j], &carry);
            inline for (0..lanes) |i| prefix[1][col + 1 + i] = v[i];
        }
    }

    // Remaining rows: horizontal scan + vertical vector add
    for (1..size) |row| {
        const prow = row + 1;
        var carry: u8 = 0;
        for (0..cells_per_row) |j| {
            const col = j * lanes;
            var v: Cell = scanCell(self.data[row * cells_per_row + j], &carry);
            var prev: Cell = undefined;
            inline for (0..lanes) |i| prev[i] = prefix[row][col + 1 + i];
            v +%= prev;
            inline for (0..lanes) |i| prefix[prow][col + 1 + i] = v[i];
        }
    }

    var sufficiently_slimy_chunks: usize = 0;
    for (0..tested_size) |x| {
        for (0..tested_size) |z| {
            const count = prefix[x + window_size][z + window_size] -%
                prefix[x][z + window_size] -%
                prefix[x + window_size][z] +%
                prefix[x][z];

            if (count >= params.threshold) {
                const exact = exactDonutCount(&prefix, x, z);
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

fn exactDonutCount(prefix: *const [size + 1][size + 1]u8, x: usize, z: usize) u8 {
    var exact: u8 = 0;
    inline for (donut_runs) |run| {
        const pr = x + run.dx + 1;
        const pc1 = z + run.c1 + 1;
        const pc2 = z + run.c2 + 1;
        const s: u8 = prefix[pr][pc2] -%
            prefix[pr][pc1 - 1] -%
            prefix[pr - 1][pc2] +%
            prefix[pr - 1][pc1 - 1];
        exact +%= s;
    }
    return exact;
}

pub fn calculateSliminessForLocation(world_seed: i64, x: i32, z: i32) u8 {
    var count: u8 = 0;
    for (0..window_size) |dx| {
        for (0..window_size) |dz| {
            if (donut_mask[dx][dz] and scalar.isSlime(
                world_seed,
                x + @as(i32, @intCast(dx)) - offset,
                z + @as(i32, @intCast(dz)) - offset,
            )) {
                count += 1;
            }
        }
    }
    return count;
}

pub fn format(self: @This(), writer: *std.Io.Writer) !void {
    const width, const height = .{ 32, 32 };
    for (0..width) |x| {
        for (0..height) |z| {
            const cell = self.data[z * cells_per_row + x / lanes];
            const bit = x % lanes;
            try writer.print("{c} ", .{@as(u8, if (cell[bit] == 1) 'o' else '.')});
        }
        try writer.print("\n", .{});
    }
}

test initScalar {
    const test_seed = @import("test_data.zig").test_seed;
    const chunk = initScalar(test_seed, offset, offset);

    const block = @import("test_data.zig").block;
    for (block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            const cell = chunk.data[x * cells_per_row + z / lanes];
            const bit = z % lanes;
            try std.testing.expectEqual(c == 'O', cell[bit] == 1);
        }
    }
}

test initSimd {
    const test_seed = @import("test_data.zig").test_seed;
    const chunk = initSimd(test_seed, offset, offset);

    const block = @import("test_data.zig").block;
    for (block, 0..) |row, z| {
        for (row, 0..) |c, x| {
            const cell = chunk.data[x * cells_per_row + z / lanes];
            const bit = z % lanes;
            try std.testing.expectEqual(c == 'O', cell[bit] == 1);
        }
    }
}

test "initSimd and initScalar parity" {
    try std.testing.expectEqualSlices(
        Cell,
        &initScalar(0x51133, 0xbeef, -0x51133135).data,
        &initSimd(0x51133, 0xbeef, -0x51133135).data,
    );
}

test format {
    if (true) return error.SkipZigTest;

    const chunk = initScalar(0x51133, offset, offset);
    std.debug.print("{f}", .{chunk});
}

test calculateSliminess {
    const test_seed = 0x51133;
    var results: std.ArrayList(slimy.Result) = .empty;
    defer results.deinit(std.testing.allocator);
    var chunk = initSimd(test_seed, 0, 0);

    const Context = struct {
        allocator: std.mem.Allocator,
        results: *std.ArrayList(slimy.Result),
        fn reportResult(context: @This(), result: slimy.Result) void {
            context.results.append(context.allocator, result) catch {};
        }
    };

    _ = chunk.calculateSliminess(
        .{ .x0 = 0, .x1 = size, .z0 = 0, .z1 = size, .method = undefined, .threshold = 0, .world_seed = test_seed },
        @as(Context, .{ .allocator = std.testing.allocator, .results = &results }),
        Context.reportResult,
    );

    try std.testing.expectEqual(tested_size * tested_size, results.items.len);
    for (results.items) |result| {
        try std.testing.expectEqual(calculateSliminessForLocation(test_seed, result.x, result.z), result.count);
    }
}
