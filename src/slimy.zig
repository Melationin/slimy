const std = @import("std");

pub const cpu = @import("cpu.zig");
pub const gpu = @import("gpu.zig");

pub fn search(
    params: SearchParams,
    context: anytype,
    comptime resultCallback: fn (@TypeOf(context), Result) void,
    comptime progressCallback: ?fn (@TypeOf(context), completed: u64, total: u64) void,
) !void {
    switch (params.method) {
        .cpu => try cpu.search(params, context, resultCallback, progressCallback),
        .gpu => {
            if (!@import("build_consts").gpu_support) {
                return error.GpuNotSupported;
            } else {
                try gpu.search(params, context, resultCallback, progressCallback);
            }
        },
    }
}

pub const SearchParams = struct {
    world_seed: i64,
    threshold: u8,

    x0: i32,
    z0: i32,
    x1: i32,
    z1: i32,

    method: SearchMethod,

    /// If true, results are emitted during the search via a dedicated reporter thread.
    report_during_search: bool = false,

    /// Maximum number of results to buffer. Excess results are silently dropped.
    /// Default: 1M (12MB), more than enough for any practical threshold.
    max_results: usize = 1 << 20,
};

pub const SearchMethod = union(enum) {
    cpu: u8, // Thread count
    gpu: void,
};

pub const Result = struct {
    x: i32,
    z: i32,
    count: u32,

    /// "Less-than" operation for sorting purposes
    pub fn sortLessThan(_: void, a: Result, b: Result) bool {
        if (a.count != b.count) {
            return a.count > b.count;
        }

        const a_d2 = (@as(i64, a.x) * a.x) + (@as(i64, a.z) * a.z);
        const b_d2 = (@as(i64, b.x) * b.x) + (@as(i64, b.z) * b.z);
        if (a_d2 != b_d2) {
            return a_d2 < b_d2;
        }

        if (a.x != b.x) {
            return a.x < b.x;
        }
        if (a.z != b.z) {
            return a.z < b.z;
        }
        return false;
    }
};

/// A connected component of adjacent results, produced by mergeAdjacent().
/// Adjacency includes all 8 directions (Chebyshev distance = 1).
pub const MergedRegion = struct {
    /// Position with the highest count in this component
    best_x: i32,
    best_z: i32,
    best_count: u32,

    /// Number of individual results merged into this component
    size: u32,

    /// Sum of all counts (for computing average)
    sum_count: u64,

    /// Axis-aligned bounding box
    min_x: i32,
    min_z: i32,
    max_x: i32,
    max_z: i32,

    /// Descending by best_count, tiebreak by component size
    pub fn sortLessThan(_: void, a: MergedRegion, b: MergedRegion) bool {
        if (a.best_count != b.best_count) return a.best_count > b.best_count;
        if (a.size != b.size) return a.size > b.size;
        const a_d2 = (@as(i64, a.best_x) * a.best_x) + (@as(i64, a.best_z) * a.best_z);
        const b_d2 = (@as(i64, b.best_x) * b.best_x) + (@as(i64, b.best_z) * b.best_z);
        if (a_d2 != b_d2) return a_d2 < b_d2;
        return false;
    }
};

/// Disjoint-Set Union (Union-Find) with path compression and union-by-size.
pub const UnionFind = struct {
    parent: []usize,
    size: []usize,

    pub fn init(allocator: std.mem.Allocator, n: usize) !UnionFind {
        const parent = try allocator.alloc(usize, n);
        errdefer allocator.free(parent);
        const sz = try allocator.alloc(usize, n);
        for (0..n) |i| {
            parent[i] = i;
            sz[i] = 1;
        }
        return .{ .parent = parent, .size = sz };
    }

    pub fn deinit(self: *UnionFind, allocator: std.mem.Allocator) void {
        allocator.free(self.parent);
        allocator.free(self.size);
    }

    pub fn find(self: *UnionFind, x: usize) usize {
        if (self.parent[x] != x) {
            self.parent[x] = self.find(self.parent[x]);
        }
        return self.parent[x];
    }

    pub fn unite(self: *UnionFind, a: usize, b: usize) void {
        var ra = self.find(a);
        var rb = self.find(b);
        if (ra == rb) return;
        if (self.size[ra] < self.size[rb]) {
            std.mem.swap(usize, &ra, &rb);
        }
        self.parent[rb] = ra;
        self.size[ra] += self.size[rb];
    }
};

/// Pack (x, z) into a u64 for use as a hash map key.
fn packKey(x: i32, z: i32) u64 {
    const xu: u64 = @bitCast(@as(i64, x));
    const zu: u64 = @as(u32, @bitCast(z));
    return (xu << 32) | zu;
}

/// The 8-directional neighbor offsets (Chebyshev distance = 1).
const neighbor_offsets = [_][2]i32{
    .{ -1, -1 }, .{ -1, 0 }, .{ -1, 1 },
    .{ 0, -1 },  .{ 0, 1 },
    .{ 1, -1 },  .{ 1, 0 },  .{ 1, 1 },
};

/// Merge adjacent results using Union-Find.
///
/// Two results at (x₁, z₁) and (x₂, z₂) are adjacent if
/// max(|x₁−x₂|, |z₁−z₂|) = 1 (Chebyshev distance, 8-directional).
///
/// The caller owns the returned slice and must free it with `allocator`.
pub fn mergeAdjacent(allocator: std.mem.Allocator, results: []Result) ![]MergedRegion {
    if (results.len == 0) return &[0]MergedRegion{};

    const n = results.len;

    // --- Pass 1: DSU on adjacent pairs ---
    var uf = try UnionFind.init(allocator, n);
    defer uf.deinit(allocator);

    // Build hash map: (x,z) -> result index
    var map = std.AutoHashMap(u64, usize).init(allocator);
    defer map.deinit();
    try map.ensureTotalCapacity(@intCast(n));

    for (results, 0..) |res, i| {
        map.putAssumeCapacity(packKey(res.x, res.z), i);
    }

    // For each result, check 8 neighbors; if a neighbor exists, union them.
    for (results, 0..) |res, i| {
        for (neighbor_offsets) |off| {
            const key = packKey(res.x + off[0], res.z + off[1]);
            if (map.get(key)) |j| {
                uf.unite(i, j);
            }
        }
    }

    // --- Pass 2: collect components ---
    var comp_map = std.AutoHashMap(usize, usize).init(allocator); // root -> region index
    defer comp_map.deinit();
    try comp_map.ensureTotalCapacity(@intCast(n));

    var regions: std.ArrayList(MergedRegion) = .empty;
    errdefer regions.deinit(allocator);

    for (0..n) |i| {
        const root = uf.find(i);
        const entry = try comp_map.getOrPut(root);
        if (entry.found_existing) {
            const ci = entry.value_ptr.*;
            var r = &regions.items[ci];
            if (results[i].count > r.best_count) {
                r.best_x = results[i].x;
                r.best_z = results[i].z;
                r.best_count = results[i].count;
            }
            r.size += 1;
            r.sum_count += results[i].count;
            r.min_x = @min(r.min_x, results[i].x);
            r.min_z = @min(r.min_z, results[i].z);
            r.max_x = @max(r.max_x, results[i].x);
            r.max_z = @max(r.max_z, results[i].z);
        } else {
            entry.value_ptr.* = regions.items.len;
            try regions.append(allocator, .{
                .best_x = results[i].x,
                .best_z = results[i].z,
                .best_count = results[i].count,
                .size = 1,
                .sum_count = results[i].count,
                .min_x = results[i].x,
                .min_z = results[i].z,
                .max_x = results[i].x,
                .max_z = results[i].z,
            });
        }
    }

    const merged = try regions.toOwnedSlice(allocator);
    std.sort.block(MergedRegion, merged, {}, MergedRegion.sortLessThan);
    return merged;
}

test {
    _ = cpu;
    if (@import("build_consts").gpu_support) _ = gpu;
}

test "mergeAdjacent: single result" {
    var results = [_]Result{
        .{ .x = 0, .z = 0, .count = 10 },
    };
    const merged = try mergeAdjacent(std.testing.allocator, &results);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(1, merged.len);
    try std.testing.expectEqual(@as(i32, 0), merged[0].best_x);
    try std.testing.expectEqual(@as(u32, 1), merged[0].size);
}

test "mergeAdjacent: disjoint results" {
    var results = [_]Result{
        .{ .x = 0, .z = 0, .count = 10 },
        .{ .x = 10, .z = 10, .count = 20 },
        .{ .x = -5, .z = 5, .count = 5 },
    };
    const merged = try mergeAdjacent(std.testing.allocator, &results);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(3, merged.len);
}

test "mergeAdjacent: 8-directional adjacency" {
    // A 2x2 block — all 4 are pairwise adjacent (including diagonal)
    var results = [_]Result{
        .{ .x = 0, .z = 0, .count = 5 },
        .{ .x = 0, .z = 1, .count = 10 },
        .{ .x = 1, .z = 0, .count = 15 },
        .{ .x = 1, .z = 1, .count = 20 },
    };
    const merged = try mergeAdjacent(std.testing.allocator, &results);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(1, merged.len);
    try std.testing.expectEqual(@as(i32, 1), merged[0].best_x);
    try std.testing.expectEqual(@as(i32, 1), merged[0].best_z);
    try std.testing.expectEqual(@as(u32, 20), merged[0].best_count);
    try std.testing.expectEqual(@as(u32, 4), merged[0].size);
    try std.testing.expectEqual(@as(i32, 0), merged[0].min_x);
    try std.testing.expectEqual(@as(i32, 0), merged[0].min_z);
    try std.testing.expectEqual(@as(i32, 1), merged[0].max_x);
    try std.testing.expectEqual(@as(i32, 1), merged[0].max_z);
}

test "mergeAdjacent: two separate clusters" {
    // Cluster A: 2 positions near origin
    // Cluster B: 3 positions far away
    var results = [_]Result{
        .{ .x = 0, .z = 0, .count = 5 },
        .{ .x = 0, .z = 1, .count = 8 },
        .{ .x = 50, .z = 50, .count = 12 },
        .{ .x = 50, .z = 51, .count = 15 },
        .{ .x = 51, .z = 50, .count = 7 },
    };
    const merged = try mergeAdjacent(std.testing.allocator, &results);
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(2, merged.len);
    // Best region should be first (count 15)
    try std.testing.expectEqual(@as(u32, 15), merged[0].best_count);
    try std.testing.expectEqual(@as(u32, 3), merged[0].size);
}

test "mergeAdjacent: empty" {
    const merged = try mergeAdjacent(std.testing.allocator, &[0]Result{});
    defer std.testing.allocator.free(merged);
    try std.testing.expectEqual(0, merged.len);
}
