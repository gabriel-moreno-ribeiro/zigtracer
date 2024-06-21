//! Geometry (spheres, triangles), materials and a bounding volume hierarchy.
const std = @import("std");
const vec = @import("vec.zig");
const Vec3 = vec.Vec3;
const Color = vec.Color;
const Ray = vec.Ray;

pub const Material = union(enum) {
    lambertian: struct { albedo: Color },
    metal: struct { albedo: Color, fuzz: f64 },
    dielectric: struct { index: f64 },
    emissive: struct { color: Color },

    pub const Scatter = struct { attenuation: Color, ray: Ray };

    /// Returns the scattered ray, or null when the ray is absorbed.
    pub fn scatter(m: Material, r: Ray, hit: Hit, rng: std.Random) ?Scatter {
        switch (m) {
            .lambertian => |l| {
                var dir = hit.normal.add(Vec3.randomUnit(rng));
                if (dir.nearZero()) dir = hit.normal;
                return .{ .attenuation = l.albedo, .ray = .{ .origin = hit.point, .dir = dir } };
            },
            .metal => |mt| {
                const reflected = r.dir.unit().reflect(hit.normal).add(Vec3.randomUnit(rng).scale(mt.fuzz));
                if (reflected.dot(hit.normal) <= 0) return null;
                return .{ .attenuation = mt.albedo, .ray = .{ .origin = hit.point, .dir = reflected } };
            },
            .dielectric => |d| {
                const ratio = if (hit.front_face) 1.0 / d.index else d.index;
                const unit_dir = r.dir.unit();
                const cos_theta = @min(unit_dir.neg().dot(hit.normal), 1.0);
                const sin_theta = @sqrt(1.0 - cos_theta * cos_theta);
                const cannot_refract = ratio * sin_theta > 1.0;
                const dir = if (cannot_refract or reflectance(cos_theta, ratio) > rng.float(f64))
                    unit_dir.reflect(hit.normal)
                else
                    Vec3.refract(unit_dir, hit.normal, ratio);
                return .{ .attenuation = Color.one, .ray = .{ .origin = hit.point, .dir = dir } };
            },
            .emissive => return null,
        }
    }

    pub fn emitted(m: Material) Color {
        return switch (m) {
            .emissive => |e| e.color,
            else => Color.zero,
        };
    }

    /// Schlick's approximation for the Fresnel reflectance of glass.
    fn reflectance(cosine: f64, ratio: f64) f64 {
        var r0 = (1 - ratio) / (1 + ratio);
        r0 = r0 * r0;
        return r0 + (1 - r0) * std.math.pow(f64, 1 - cosine, 5);
    }
};

pub const Hit = struct {
    point: Vec3,
    normal: Vec3,
    t: f64,
    front_face: bool,
    material: Material,

    fn faceNormal(r: Ray, outward: Vec3) struct { normal: Vec3, front: bool } {
        const front = r.dir.dot(outward) < 0;
        return .{ .normal = if (front) outward else outward.neg(), .front = front };
    }
};

pub const Aabb = struct {
    min: Vec3,
    max: Vec3,

    pub fn merge(a: Aabb, b: Aabb) Aabb {
        return .{
            .min = Vec3.init(@min(a.min.x, b.min.x), @min(a.min.y, b.min.y), @min(a.min.z, b.min.z)),
            .max = Vec3.init(@max(a.max.x, b.max.x), @max(a.max.y, b.max.y), @max(a.max.z, b.max.z)),
        };
    }

    pub fn centroid(a: Aabb) Vec3 {
        return a.min.add(a.max).scale(0.5);
    }

    /// Slab test: does the ray cross the box within [t_min, t_max]?
    pub fn hit(a: Aabb, r: Ray, t_min_in: f64, t_max_in: f64) bool {
        var t_min = t_min_in;
        var t_max = t_max_in;
        var axis: usize = 0;
        while (axis < 3) : (axis += 1) {
            const inv = 1.0 / r.dir.component(axis);
            var t0 = (a.min.component(axis) - r.origin.component(axis)) * inv;
            var t1 = (a.max.component(axis) - r.origin.component(axis)) * inv;
            if (inv < 0) std.mem.swap(f64, &t0, &t1);
            t_min = @max(t0, t_min);
            t_max = @min(t1, t_max);
            if (t_max <= t_min) return false;
        }
        return true;
    }
};

pub const Sphere = struct {
    center: Vec3,
    radius: f64,
    material: Material,

    pub fn hit(s: Sphere, r: Ray, t_min: f64, t_max: f64) ?Hit {
        const oc = s.center.sub(r.origin);
        const a = r.dir.lengthSquared();
        const h = r.dir.dot(oc);
        const c = oc.lengthSquared() - s.radius * s.radius;
        const disc = h * h - a * c;
        if (disc < 0) return null;
        const sqrt_d = @sqrt(disc);
        var root = (h - sqrt_d) / a;
        if (root <= t_min or root >= t_max) {
            root = (h + sqrt_d) / a;
            if (root <= t_min or root >= t_max) return null;
        }
        const point = r.at(root);
        const outward = point.sub(s.center).scale(1.0 / s.radius);
        const fn_ = Hit.faceNormal(r, outward);
        return .{ .point = point, .normal = fn_.normal, .t = root, .front_face = fn_.front, .material = s.material };
    }

    pub fn bounds(s: Sphere) Aabb {
        const rv = Vec3.init(s.radius, s.radius, s.radius);
        return .{ .min = s.center.sub(rv), .max = s.center.add(rv) };
    }
};

pub const Triangle = struct {
    a: Vec3,
    b: Vec3,
    c: Vec3,
    material: Material,

    /// Moeller-Trumbore ray/triangle intersection.
    pub fn hit(t: Triangle, r: Ray, t_min: f64, t_max: f64) ?Hit {
        const e1 = t.b.sub(t.a);
        const e2 = t.c.sub(t.a);
        const p = r.dir.cross(e2);
        const det = e1.dot(p);
        if (@abs(det) < 1e-12) return null;
        const inv = 1.0 / det;
        const s = r.origin.sub(t.a);
        const u = s.dot(p) * inv;
        if (u < 0 or u > 1) return null;
        const q = s.cross(e1);
        const v = r.dir.dot(q) * inv;
        if (v < 0 or u + v > 1) return null;
        const dist = e2.dot(q) * inv;
        if (dist <= t_min or dist >= t_max) return null;
        const outward = e1.cross(e2).unit();
        const fn_ = Hit.faceNormal(r, outward);
        return .{ .point = r.at(dist), .normal = fn_.normal, .t = dist, .front_face = fn_.front, .material = t.material };
    }

    pub fn bounds(t: Triangle) Aabb {
        const pad = 1e-6;
        return .{
            .min = Vec3.init(@min(@min(t.a.x, t.b.x), t.c.x) - pad, @min(@min(t.a.y, t.b.y), t.c.y) - pad, @min(@min(t.a.z, t.b.z), t.c.z) - pad),
            .max = Vec3.init(@max(@max(t.a.x, t.b.x), t.c.x) + pad, @max(@max(t.a.y, t.b.y), t.c.y) + pad, @max(@max(t.a.z, t.b.z), t.c.z) + pad),
        };
    }
};

pub const Object = union(enum) {
    sphere: Sphere,
    triangle: Triangle,

    pub fn hit(o: Object, r: Ray, t_min: f64, t_max: f64) ?Hit {
        return switch (o) {
            .sphere => |s| s.hit(r, t_min, t_max),
            .triangle => |t| t.hit(r, t_min, t_max),
        };
    }

    pub fn bounds(o: Object) Aabb {
        return switch (o) {
            .sphere => |s| s.bounds(),
            .triangle => |t| t.bounds(),
        };
    }
};

/// Bounding volume hierarchy: objects are split on the widest axis of their
/// centroids until leaves hold a few objects. Ray queries skip whole
/// subtrees whose boxes are missed.
pub const Bvh = struct {
    const Node = struct {
        box: Aabb,
        left: u32, // child index, or first object index for leaves
        right: u32, // child index, or object count for leaves
        leaf: bool,
    };

    nodes: std.ArrayList(Node),
    objects: []Object,

    pub fn build(allocator: std.mem.Allocator, objects: []Object) !Bvh {
        var bvh = Bvh{ .nodes = std.ArrayList(Node).init(allocator), .objects = objects };
        if (objects.len > 0) _ = try bvh.buildNode(0, objects.len);
        return bvh;
    }

    pub fn deinit(b: *Bvh) void {
        b.nodes.deinit();
    }

    fn buildNode(b: *Bvh, start: usize, end: usize) !u32 {
        var box = b.objects[start].bounds();
        var i = start + 1;
        while (i < end) : (i += 1) box = box.merge(b.objects[i].bounds());
        const index: u32 = @intCast(b.nodes.items.len);
        try b.nodes.append(.{ .box = box, .left = @intCast(start), .right = @intCast(end - start), .leaf = true });
        if (end - start <= 2) return index;

        // split along the widest axis at the median centroid
        const extent = box.max.sub(box.min);
        const axis: usize = if (extent.x >= extent.y and extent.x >= extent.z) 0 else if (extent.y >= extent.z) 1 else 2;
        const slice = b.objects[start..end];
        std.mem.sort(Object, slice, axis, struct {
            fn lessThan(ax: usize, lhs: Object, rhs: Object) bool {
                return lhs.bounds().centroid().component(ax) < rhs.bounds().centroid().component(ax);
            }
        }.lessThan);
        const mid = start + (end - start) / 2;
        const left = try b.buildNode(start, mid);
        const right = try b.buildNode(mid, end);
        b.nodes.items[index] = .{ .box = box, .left = left, .right = right, .leaf = false };
        return index;
    }

    pub fn hit(b: Bvh, r: Ray, t_min: f64, t_max: f64) ?Hit {
        if (b.nodes.items.len == 0) return null;
        return b.hitNode(0, r, t_min, t_max);
    }

    fn hitNode(b: Bvh, index: u32, r: Ray, t_min: f64, t_max_in: f64) ?Hit {
        const node = b.nodes.items[index];
        if (!node.box.hit(r, t_min, t_max_in)) return null;
        var closest: ?Hit = null;
        var t_max = t_max_in;
        if (node.leaf) {
            var i: usize = node.left;
            while (i < node.left + node.right) : (i += 1) {
                if (b.objects[i].hit(r, t_min, t_max)) |h| {
                    closest = h;
                    t_max = h.t;
                }
            }
            return closest;
        }
        if (b.hitNode(node.left, r, t_min, t_max)) |h| {
            closest = h;
            t_max = h.t;
        }
        if (b.hitNode(node.right, r, t_min, t_max)) |h| {
            closest = h;
        }
        return closest;
    }
};

/// Brute force reference used by the tests to validate the BVH.
pub fn hitAll(objects: []const Object, r: Ray, t_min: f64, t_max_in: f64) ?Hit {
    var closest: ?Hit = null;
    var t_max = t_max_in;
    for (objects) |o| {
        if (o.hit(r, t_min, t_max)) |h| {
            closest = h;
            t_max = h.t;
        }
    }
    return closest;
}

const red = Material{ .lambertian = .{ .albedo = Color.init(1, 0, 0) } };

test "ray hits a sphere at the nearest root with an outward normal" {
    const s = Sphere{ .center = Vec3.init(0, 0, -5), .radius = 1, .material = red };
    const r = Ray{ .origin = Vec3.zero, .dir = Vec3.init(0, 0, -1) };
    const h = s.hit(r, 0.001, std.math.inf(f64)) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 4), h.t, 1e-12);
    try std.testing.expect(h.normal.approxEq(Vec3.init(0, 0, 1), 1e-12));
    try std.testing.expect(h.front_face);
    // from inside the sphere the normal is flipped to face the ray
    const inside = Ray{ .origin = Vec3.init(0, 0, -5), .dir = Vec3.init(0, 0, -1) };
    const h2 = s.hit(inside, 0.001, std.math.inf(f64)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(!h2.front_face);
    try std.testing.expect(h2.normal.approxEq(Vec3.init(0, 0, 1), 1e-12));
    // a miss
    try std.testing.expect(s.hit(.{ .origin = Vec3.zero, .dir = Vec3.init(0, 1, 0) }, 0.001, 1e9) == null);
}

test "ray hits a triangle inside its edges only" {
    const t = Triangle{ .a = Vec3.init(-1, -1, -3), .b = Vec3.init(1, -1, -3), .c = Vec3.init(0, 1, -3), .material = red };
    const inside = Ray{ .origin = Vec3.zero, .dir = Vec3.init(0, 0, -1) };
    const h = t.hit(inside, 0.001, 1e9) orelse return error.TestUnexpectedResult;
    try std.testing.expectApproxEqAbs(@as(f64, 3), h.t, 1e-12);
    try std.testing.expect(h.normal.approxEq(Vec3.init(0, 0, 1), 1e-12));
    const outside = Ray{ .origin = Vec3.init(2, 2, 0), .dir = Vec3.init(0, 0, -1) };
    try std.testing.expect(t.hit(outside, 0.001, 1e9) == null);
    const parallel = Ray{ .origin = Vec3.zero, .dir = Vec3.init(1, 0, 0) };
    try std.testing.expect(t.hit(parallel, 0.001, 1e9) == null);
}

test "aabb slab test" {
    const box = Aabb{ .min = Vec3.init(-1, -1, -1), .max = Vec3.init(1, 1, 1) };
    try std.testing.expect(box.hit(.{ .origin = Vec3.init(0, 0, 5), .dir = Vec3.init(0, 0, -1) }, 0, 100));
    try std.testing.expect(!box.hit(.{ .origin = Vec3.init(3, 0, 5), .dir = Vec3.init(0, 0, -1) }, 0, 100));
    try std.testing.expect(!box.hit(.{ .origin = Vec3.init(0, 0, 5), .dir = Vec3.init(0, 0, 1) }, 0, 100));
}

test "bvh agrees with brute force on random rays" {
    var prng = std.Random.DefaultPrng.init(42);
    const rng = prng.random();
    const allocator = std.testing.allocator;
    var objects = std.ArrayList(Object).init(allocator);
    defer objects.deinit();
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const c = Vec3.randomRange(rng, -10, 10);
        if (i % 3 == 0) {
            try objects.append(.{ .triangle = .{ .a = c, .b = c.add(Vec3.randomRange(rng, -2, 2)), .c = c.add(Vec3.randomRange(rng, -2, 2)), .material = red } });
        } else {
            try objects.append(.{ .sphere = .{ .center = c, .radius = 0.3 + rng.float(f64), .material = red } });
        }
    }
    var bvh = try Bvh.build(allocator, objects.items);
    defer bvh.deinit();
    var hits: usize = 0;
    var k: usize = 0;
    while (k < 500) : (k += 1) {
        const r = Ray{ .origin = Vec3.randomRange(rng, -12, 12), .dir = Vec3.randomUnit(rng) };
        const a = hitAll(objects.items, r, 0.001, 1e9);
        const b = bvh.hit(r, 0.001, 1e9);
        try std.testing.expectEqual(a == null, b == null);
        if (a) |ha| {
            hits += 1;
            try std.testing.expectApproxEqAbs(ha.t, b.?.t, 1e-9);
        }
    }
    try std.testing.expect(hits > 50);
}
