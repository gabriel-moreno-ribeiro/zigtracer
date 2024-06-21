//! Camera, path tracing loop and multithreaded rendering into an image.
const std = @import("std");
const vec = @import("vec.zig");
const scene = @import("scene.zig");
const Vec3 = vec.Vec3;
const Color = vec.Color;
const Ray = vec.Ray;

pub const Camera = struct {
    origin: Vec3,
    pixel00: Vec3,
    du: Vec3,
    dv: Vec3,
    defocus_u: Vec3,
    defocus_v: Vec3,
    defocus_angle: f64,
    width: usize,
    height: usize,

    pub const Options = struct {
        look_from: Vec3,
        look_at: Vec3,
        up: Vec3 = Vec3.init(0, 1, 0),
        vfov_degrees: f64 = 40,
        width: usize,
        height: usize,
        defocus_angle: f64 = 0,
        focus_distance: f64 = 1,
    };

    pub fn init(o: Options) Camera {
        const theta = o.vfov_degrees * std.math.pi / 180.0;
        const h = @tan(theta / 2);
        const viewport_h = 2 * h * o.focus_distance;
        const aspect = @as(f64, @floatFromInt(o.width)) / @as(f64, @floatFromInt(o.height));
        const viewport_w = viewport_h * aspect;

        const w = o.look_from.sub(o.look_at).unit();
        const u = o.up.cross(w).unit();
        const v = w.cross(u);

        const viewport_u = u.scale(viewport_w);
        const viewport_v = v.neg().scale(viewport_h);
        const du = viewport_u.scale(1.0 / @as(f64, @floatFromInt(o.width)));
        const dv = viewport_v.scale(1.0 / @as(f64, @floatFromInt(o.height)));
        const upper_left = o.look_from.sub(w.scale(o.focus_distance)).sub(viewport_u.scale(0.5)).sub(viewport_v.scale(0.5));
        const defocus_radius = o.focus_distance * @tan(o.defocus_angle / 2 * std.math.pi / 180.0);
        return .{
            .origin = o.look_from,
            .pixel00 = upper_left.add(du.add(dv).scale(0.5)),
            .du = du,
            .dv = dv,
            .defocus_u = u.scale(defocus_radius),
            .defocus_v = v.scale(defocus_radius),
            .defocus_angle = o.defocus_angle,
            .width = o.width,
            .height = o.height,
        };
    }

    /// A ray through pixel (x, y), jittered inside the pixel and, with defocus, from a random lens point.
    pub fn ray(c: Camera, x: usize, y: usize, rng: std.Random) Ray {
        const jitter_x = rng.float(f64) - 0.5;
        const jitter_y = rng.float(f64) - 0.5;
        const target = c.pixel00
            .add(c.du.scale(@as(f64, @floatFromInt(x)) + jitter_x))
            .add(c.dv.scale(@as(f64, @floatFromInt(y)) + jitter_y));
        var origin = c.origin;
        if (c.defocus_angle > 0) {
            const p = Vec3.randomInUnitDisk(rng);
            origin = c.origin.add(c.defocus_u.scale(p.x)).add(c.defocus_v.scale(p.y));
        }
        return .{ .origin = origin, .dir = target.sub(origin) };
    }
};

pub const Image = struct {
    width: usize,
    height: usize,
    pixels: []Color,
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator, width: usize, height: usize) !Image {
        const pixels = try allocator.alloc(Color, width * height);
        @memset(pixels, Color.zero);
        return .{ .width = width, .height = height, .pixels = pixels, .allocator = allocator };
    }

    pub fn deinit(img: *Image) void {
        img.allocator.free(img.pixels);
    }

    pub fn get(img: Image, x: usize, y: usize) Color {
        return img.pixels[y * img.width + x];
    }

    /// Gamma corrected, clamped 8-bit channel values.
    pub fn rgb8(img: Image, x: usize, y: usize) [3]u8 {
        const c = img.get(x, y);
        return .{ toByte(c.x), toByte(c.y), toByte(c.z) };
    }

    fn toByte(v: f64) u8 {
        const g = if (v > 0) @sqrt(v) else 0; // gamma 2
        const clamped = @min(@max(g, 0.0), 0.999);
        return @intFromFloat(clamped * 256.0);
    }
};

pub const Settings = struct {
    samples: usize = 50,
    max_depth: usize = 30,
    threads: usize = 0, // 0 = all cores
    seed: u64 = 1,
    background: Background = .sky,

    pub const Background = enum { sky, black };
};

fn background(kind: Settings.Background, r: Ray) Color {
    switch (kind) {
        .black => return Color.zero,
        .sky => {
            const t = 0.5 * (r.dir.unit().y + 1.0);
            return Color.one.scale(1.0 - t).add(Color.init(0.5, 0.7, 1.0).scale(t));
        },
    }
}

/// Radiance along a ray: bounce until the ray escapes, is absorbed, or the depth runs out.
pub fn trace(world: scene.Bvh, r: Ray, depth: usize, rng: std.Random, bg: Settings.Background) Color {
    var ray = r;
    var throughput = Color.one;
    var accumulated = Color.zero;
    var bounce: usize = 0;
    while (bounce < depth) : (bounce += 1) {
        const hit = world.hit(ray, 0.001, std.math.inf(f64)) orelse {
            return accumulated.add(throughput.mul(background(bg, ray)));
        };
        accumulated = accumulated.add(throughput.mul(hit.material.emitted()));
        const s = hit.material.scatter(ray, hit, rng) orelse return accumulated;
        throughput = throughput.mul(s.attenuation);
        ray = s.ray;
    }
    return accumulated;
}

const Job = struct {
    world: scene.Bvh,
    camera: Camera,
    settings: Settings,
    image: *Image,
    next_row: *std.atomic.Value(usize),
    thread_index: usize,
};

fn worker(job: Job) void {
    var prng = std.Random.DefaultPrng.init(job.settings.seed +% job.thread_index * 7919);
    const rng = prng.random();
    while (true) {
        const y = job.next_row.fetchAdd(1, .monotonic);
        if (y >= job.image.height) return;
        var x: usize = 0;
        while (x < job.image.width) : (x += 1) {
            var sum = Color.zero;
            var s: usize = 0;
            while (s < job.settings.samples) : (s += 1) {
                const r = job.camera.ray(x, y, rng);
                sum = sum.add(trace(job.world, r, job.settings.max_depth, rng, job.settings.background));
            }
            job.image.pixels[y * job.image.width + x] = sum.scale(1.0 / @as(f64, @floatFromInt(job.settings.samples)));
        }
    }
}

/// Renders the scene into a new image, splitting rows across threads.
pub fn render(allocator: std.mem.Allocator, world: scene.Bvh, camera: Camera, settings: Settings) !Image {
    var image = try Image.init(allocator, camera.width, camera.height);
    errdefer image.deinit();
    var next_row = std.atomic.Value(usize).init(0);
    const count = if (settings.threads == 0) @max(1, std.Thread.getCpuCount() catch 1) else settings.threads;
    const threads = try allocator.alloc(std.Thread, count);
    defer allocator.free(threads);
    var spawned: usize = 0;
    while (spawned < count) : (spawned += 1) {
        threads[spawned] = try std.Thread.spawn(.{}, worker, .{Job{
            .world = world,
            .camera = camera,
            .settings = settings,
            .image = &image,
            .next_row = &next_row,
            .thread_index = spawned,
        }});
    }
    for (threads) |t| t.join();
    return image;
}

test "camera rays pass through the viewport" {
    const cam = Camera.init(.{ .look_from = Vec3.zero, .look_at = Vec3.init(0, 0, -1), .vfov_degrees = 90, .width = 100, .height = 50 });
    var prng = std.Random.DefaultPrng.init(1);
    const rng = prng.random();
    const center = cam.ray(50, 25, rng);
    try std.testing.expect(center.dir.unit().approxEq(Vec3.init(0, 0, -1), 0.03));
    const left = cam.ray(0, 25, rng);
    try std.testing.expect(left.dir.x < -1.5); // 90 degree fov at 2:1 aspect: viewport is 4 wide
    const top = cam.ray(50, 0, rng);
    try std.testing.expect(top.dir.y > 0.9);
}

test "rendering a red sphere on black puts red in the centre and black in the corner" {
    const allocator = std.testing.allocator;
    var objects = [_]scene.Object{
        .{ .sphere = .{ .center = Vec3.init(0, 0, -3), .radius = 1, .material = .{ .emissive = .{ .color = Color.init(1, 0, 0) } } } },
    };
    var world = try scene.Bvh.build(allocator, &objects);
    defer world.deinit();
    const cam = Camera.init(.{ .look_from = Vec3.zero, .look_at = Vec3.init(0, 0, -1), .vfov_degrees = 60, .width = 40, .height = 30 });
    var image = try render(allocator, world, cam, .{ .samples = 4, .max_depth = 5, .threads = 2, .background = .black });
    defer image.deinit();
    const centre = image.rgb8(20, 15);
    const corner = image.rgb8(0, 0);
    try std.testing.expect(centre[0] > 200 and centre[1] == 0 and centre[2] == 0);
    try std.testing.expect(corner[0] == 0 and corner[1] == 0 and corner[2] == 0);
}

test "same seed gives the same image" {
    const allocator = std.testing.allocator;
    var objects = [_]scene.Object{
        .{ .sphere = .{ .center = Vec3.init(0, 0, -3), .radius = 1, .material = .{ .lambertian = .{ .albedo = Color.init(0.5, 0.5, 0.5) } } } },
        .{ .sphere = .{ .center = Vec3.init(0, -101, -3), .radius = 100, .material = .{ .metal = .{ .albedo = Color.init(0.8, 0.8, 0.8), .fuzz = 0.1 } } } },
    };
    var world = try scene.Bvh.build(allocator, &objects);
    defer world.deinit();
    const cam = Camera.init(.{ .look_from = Vec3.zero, .look_at = Vec3.init(0, 0, -1), .width = 16, .height = 12 });
    var a = try render(allocator, world, cam, .{ .samples = 3, .threads = 1, .seed = 9 });
    defer a.deinit();
    var b = try render(allocator, world, cam, .{ .samples = 3, .threads = 1, .seed = 9 });
    defer b.deinit();
    for (a.pixels, b.pixels) |pa, pb| try std.testing.expect(pa.approxEq(pb, 1e-12));
    // and a lit scene is not black
    var bright: usize = 0;
    for (a.pixels) |p| {
        if (p.length() > 0.1) bright += 1;
    }
    try std.testing.expect(bright > 100);
}
