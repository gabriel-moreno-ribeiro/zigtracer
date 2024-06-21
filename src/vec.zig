//! 3D vectors, colours and rays.
const std = @import("std");

pub const Vec3 = struct {
    x: f64,
    y: f64,
    z: f64,

    pub const zero = Vec3{ .x = 0, .y = 0, .z = 0 };
    pub const one = Vec3{ .x = 1, .y = 1, .z = 1 };

    pub fn init(x: f64, y: f64, z: f64) Vec3 {
        return .{ .x = x, .y = y, .z = z };
    }

    pub fn add(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x + b.x, .y = a.y + b.y, .z = a.z + b.z };
    }
    pub fn sub(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x - b.x, .y = a.y - b.y, .z = a.z - b.z };
    }
    pub fn mul(a: Vec3, b: Vec3) Vec3 {
        return .{ .x = a.x * b.x, .y = a.y * b.y, .z = a.z * b.z };
    }
    pub fn scale(a: Vec3, s: f64) Vec3 {
        return .{ .x = a.x * s, .y = a.y * s, .z = a.z * s };
    }
    pub fn neg(a: Vec3) Vec3 {
        return .{ .x = -a.x, .y = -a.y, .z = -a.z };
    }
    pub fn dot(a: Vec3, b: Vec3) f64 {
        return a.x * b.x + a.y * b.y + a.z * b.z;
    }
    pub fn cross(a: Vec3, b: Vec3) Vec3 {
        return .{
            .x = a.y * b.z - a.z * b.y,
            .y = a.z * b.x - a.x * b.z,
            .z = a.x * b.y - a.y * b.x,
        };
    }
    pub fn lengthSquared(a: Vec3) f64 {
        return a.dot(a);
    }
    pub fn length(a: Vec3) f64 {
        return @sqrt(a.lengthSquared());
    }
    pub fn unit(a: Vec3) Vec3 {
        return a.scale(1.0 / a.length());
    }
    pub fn nearZero(a: Vec3) bool {
        const eps = 1e-8;
        return @abs(a.x) < eps and @abs(a.y) < eps and @abs(a.z) < eps;
    }
    pub fn reflect(v: Vec3, n: Vec3) Vec3 {
        return v.sub(n.scale(2 * v.dot(n)));
    }
    /// Snell's law; `ratio` is eta_in / eta_out. `uv` must be a unit vector.
    pub fn refract(uv: Vec3, n: Vec3, ratio: f64) Vec3 {
        const cos_theta = @min(uv.neg().dot(n), 1.0);
        const perp = uv.add(n.scale(cos_theta)).scale(ratio);
        const parallel = n.scale(-@sqrt(@abs(1.0 - perp.lengthSquared())));
        return perp.add(parallel);
    }
    pub fn component(a: Vec3, axis: usize) f64 {
        return switch (axis) {
            0 => a.x,
            1 => a.y,
            else => a.z,
        };
    }
    pub fn approxEq(a: Vec3, b: Vec3, tol: f64) bool {
        return @abs(a.x - b.x) < tol and @abs(a.y - b.y) < tol and @abs(a.z - b.z) < tol;
    }

    pub fn random(rng: std.Random) Vec3 {
        return .{ .x = rng.float(f64), .y = rng.float(f64), .z = rng.float(f64) };
    }
    pub fn randomRange(rng: std.Random, lo: f64, hi: f64) Vec3 {
        return .{
            .x = lo + (hi - lo) * rng.float(f64),
            .y = lo + (hi - lo) * rng.float(f64),
            .z = lo + (hi - lo) * rng.float(f64),
        };
    }
    /// Uniformly distributed point on the unit sphere (rejection sampling).
    pub fn randomUnit(rng: std.Random) Vec3 {
        while (true) {
            const p = randomRange(rng, -1, 1);
            const l = p.lengthSquared();
            if (l > 1e-160 and l <= 1) return p.scale(1.0 / @sqrt(l));
        }
    }
    pub fn randomInUnitDisk(rng: std.Random) Vec3 {
        while (true) {
            const p = Vec3.init(-1 + 2 * rng.float(f64), -1 + 2 * rng.float(f64), 0);
            if (p.lengthSquared() < 1) return p;
        }
    }
};

pub const Color = Vec3;

pub const Ray = struct {
    origin: Vec3,
    dir: Vec3,

    pub fn at(r: Ray, t: f64) Vec3 {
        return r.origin.add(r.dir.scale(t));
    }
};

test "vector arithmetic" {
    const a = Vec3.init(1, 2, 3);
    const b = Vec3.init(4, 5, 6);
    try std.testing.expect(a.add(b).approxEq(Vec3.init(5, 7, 9), 1e-12));
    try std.testing.expectEqual(@as(f64, 32), a.dot(b));
    try std.testing.expect(a.cross(b).approxEq(Vec3.init(-3, 6, -3), 1e-12));
    try std.testing.expectApproxEqAbs(@as(f64, 1), Vec3.init(3, 4, 0).unit().length(), 1e-12);
    try std.testing.expect(Vec3.init(1, -1, 0).reflect(Vec3.init(0, 1, 0)).approxEq(Vec3.init(1, 1, 0), 1e-12));
}

test "refraction follows snell's law" {
    // entering glass (n = 1.5) at 45 degrees: sin(theta_t) = sin(45)/1.5
    const in = Vec3.init(1, -1, 0).unit();
    const n = Vec3.init(0, 1, 0);
    const out = Vec3.refract(in, n, 1.0 / 1.5);
    const sin_t = @abs(out.x) / out.length();
    try std.testing.expectApproxEqAbs(@sin(std.math.pi / 4.0) / 1.5, sin_t, 1e-9);
    try std.testing.expect(out.y < 0);
}

test "random unit vectors have unit length" {
    var prng = std.Random.DefaultPrng.init(7);
    const rng = prng.random();
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        try std.testing.expectApproxEqAbs(@as(f64, 1), Vec3.randomUnit(rng).length(), 1e-9);
        try std.testing.expect(Vec3.randomInUnitDisk(rng).lengthSquared() < 1);
    }
}
