//! zigtracer - a path tracer written from scratch in Zig.
//!
//!   zigtracer [--width N] [--height N] [--samples N] [--depth N] [--threads N]
//!             [--scene cornell|spheres|random] [--seed N] [--out image.png|image.ppm]
const std = @import("std");
const vec = @import("vec.zig");
const scene = @import("scene.zig");
const render = @import("render.zig");
const image = @import("image.zig");
const Vec3 = vec.Vec3;
const Color = vec.Color;

const Args = struct {
    width: usize = 400,
    height: usize = 225,
    samples: usize = 50,
    depth: usize = 30,
    threads: usize = 0,
    seed: u64 = 1,
    scene: []const u8 = "spheres",
    out: []const u8 = "image.png",
};

fn parseArgs() !Args {
    var args = Args{};
    // the argument strings live for the whole run, so they come from the page allocator
    const argv = try std.process.argsAlloc(std.heap.page_allocator);
    var i: usize = 1;
    while (i < argv.len) : (i += 1) {
        const a = argv[i];
        const value = if (i + 1 < argv.len) argv[i + 1] else "";
        if (std.mem.eql(u8, a, "--width")) {
            args.width = try std.fmt.parseInt(usize, value, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--height")) {
            args.height = try std.fmt.parseInt(usize, value, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--samples")) {
            args.samples = try std.fmt.parseInt(usize, value, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--depth")) {
            args.depth = try std.fmt.parseInt(usize, value, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--threads")) {
            args.threads = try std.fmt.parseInt(usize, value, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--seed")) {
            args.seed = try std.fmt.parseInt(u64, value, 10);
            i += 1;
        } else if (std.mem.eql(u8, a, "--scene")) {
            args.scene = value;
            i += 1;
        } else if (std.mem.eql(u8, a, "--out")) {
            args.out = value;
            i += 1;
        } else {
            std.debug.print("unknown option {s}\n", .{a});
            return error.InvalidArgs;
        }
    }
    return args;
}

const Scene = struct {
    objects: std.ArrayList(scene.Object),
    camera: render.Camera.Options,
    background: render.Settings.Background,
};

fn lambert(r: f64, g: f64, b: f64) scene.Material {
    return .{ .lambertian = .{ .albedo = Color.init(r, g, b) } };
}

/// A few spheres showing every material, on a checker-free ground.
fn spheresScene(allocator: std.mem.Allocator, width: usize, height: usize) !Scene {
    var objects = std.ArrayList(scene.Object).init(allocator);
    try objects.append(.{ .sphere = .{ .center = Vec3.init(0, -100.5, -1), .radius = 100, .material = lambert(0.5, 0.7, 0.3) } });
    try objects.append(.{ .sphere = .{ .center = Vec3.init(0, 0, -1.2), .radius = 0.5, .material = lambert(0.1, 0.2, 0.5) } });
    try objects.append(.{ .sphere = .{ .center = Vec3.init(-1, 0, -1), .radius = 0.5, .material = .{ .dielectric = .{ .index = 1.5 } } } });
    try objects.append(.{ .sphere = .{ .center = Vec3.init(-1, 0, -1), .radius = 0.4, .material = .{ .dielectric = .{ .index = 1.0 / 1.5 } } } });
    try objects.append(.{ .sphere = .{ .center = Vec3.init(1, 0, -1), .radius = 0.5, .material = .{ .metal = .{ .albedo = Color.init(0.8, 0.6, 0.2), .fuzz = 0.05 } } } });
    // a small pyramid of triangles in front
    const apex = Vec3.init(0.4, 0.3, -0.4);
    const b0 = Vec3.init(0.2, -0.5, -0.2);
    const b1 = Vec3.init(0.6, -0.5, -0.2);
    const b2 = Vec3.init(0.4, -0.5, -0.6);
    const pink = lambert(0.9, 0.3, 0.5);
    try objects.append(.{ .triangle = .{ .a = b0, .b = b1, .c = apex, .material = pink } });
    try objects.append(.{ .triangle = .{ .a = b1, .b = b2, .c = apex, .material = pink } });
    try objects.append(.{ .triangle = .{ .a = b2, .b = b0, .c = apex, .material = pink } });
    return .{
        .objects = objects,
        .camera = .{ .look_from = Vec3.init(-2, 2, 1), .look_at = Vec3.init(0, 0, -1), .vfov_degrees = 30, .width = width, .height = height, .defocus_angle = 2, .focus_distance = 3.4 },
        .background = .sky,
    };
}

/// The classic "final scene": hundreds of random small spheres.
fn randomScene(allocator: std.mem.Allocator, width: usize, height: usize, seed: u64) !Scene {
    var prng = std.Random.DefaultPrng.init(seed);
    const rng = prng.random();
    var objects = std.ArrayList(scene.Object).init(allocator);
    try objects.append(.{ .sphere = .{ .center = Vec3.init(0, -1000, 0), .radius = 1000, .material = lambert(0.5, 0.5, 0.5) } });
    var a: i32 = -8;
    while (a < 8) : (a += 1) {
        var b: i32 = -8;
        while (b < 8) : (b += 1) {
            const center = Vec3.init(@as(f64, @floatFromInt(a)) + 0.9 * rng.float(f64), 0.2, @as(f64, @floatFromInt(b)) + 0.9 * rng.float(f64));
            if (center.sub(Vec3.init(4, 0.2, 0)).length() <= 0.9) continue;
            const choice = rng.float(f64);
            const material: scene.Material = if (choice < 0.7)
                .{ .lambertian = .{ .albedo = Vec3.random(rng).mul(Vec3.random(rng)) } }
            else if (choice < 0.9)
                .{ .metal = .{ .albedo = Vec3.randomRange(rng, 0.5, 1), .fuzz = 0.5 * rng.float(f64) } }
            else
                .{ .dielectric = .{ .index = 1.5 } };
            try objects.append(.{ .sphere = .{ .center = center, .radius = 0.2, .material = material } });
        }
    }
    try objects.append(.{ .sphere = .{ .center = Vec3.init(0, 1, 0), .radius = 1, .material = .{ .dielectric = .{ .index = 1.5 } } } });
    try objects.append(.{ .sphere = .{ .center = Vec3.init(-4, 1, 0), .radius = 1, .material = lambert(0.4, 0.2, 0.1) } });
    try objects.append(.{ .sphere = .{ .center = Vec3.init(4, 1, 0), .radius = 1, .material = .{ .metal = .{ .albedo = Color.init(0.7, 0.6, 0.5), .fuzz = 0 } } } });
    return .{
        .objects = objects,
        .camera = .{ .look_from = Vec3.init(13, 2, 3), .look_at = Vec3.zero, .vfov_degrees = 20, .width = width, .height = height, .defocus_angle = 0.6, .focus_distance = 10 },
        .background = .sky,
    };
}

/// A Cornell box built from triangles, lit only by an emissive ceiling panel.
fn cornellScene(allocator: std.mem.Allocator, width: usize, height: usize) !Scene {
    var objects = std.ArrayList(scene.Object).init(allocator);
    const white = lambert(0.73, 0.73, 0.73);
    const red = lambert(0.65, 0.05, 0.05);
    const green = lambert(0.12, 0.45, 0.15);
    const light = scene.Material{ .emissive = .{ .color = Color.init(15, 15, 15) } };
    const quad = struct {
        fn add(list: *std.ArrayList(scene.Object), p0: Vec3, p1: Vec3, p2: Vec3, p3: Vec3, m: scene.Material) !void {
            try list.append(.{ .triangle = .{ .a = p0, .b = p1, .c = p2, .material = m } });
            try list.append(.{ .triangle = .{ .a = p0, .b = p2, .c = p3, .material = m } });
        }
    };
    const s = 555.0;
    try quad.add(&objects, Vec3.init(s, 0, 0), Vec3.init(s, s, 0), Vec3.init(s, s, s), Vec3.init(s, 0, s), green); // right wall
    try quad.add(&objects, Vec3.init(0, 0, 0), Vec3.init(0, 0, s), Vec3.init(0, s, s), Vec3.init(0, s, 0), red); // left wall
    try quad.add(&objects, Vec3.init(0, 0, 0), Vec3.init(s, 0, 0), Vec3.init(s, 0, s), Vec3.init(0, 0, s), white); // floor
    try quad.add(&objects, Vec3.init(0, s, 0), Vec3.init(0, s, s), Vec3.init(s, s, s), Vec3.init(s, s, 0), white); // ceiling
    try quad.add(&objects, Vec3.init(0, 0, s), Vec3.init(s, 0, s), Vec3.init(s, s, s), Vec3.init(0, s, s), white); // back wall
    try quad.add(&objects, Vec3.init(213, s - 1, 227), Vec3.init(213, s - 1, 332), Vec3.init(343, s - 1, 332), Vec3.init(343, s - 1, 227), light);
    try objects.append(.{ .sphere = .{ .center = Vec3.init(190, 90, 190), .radius = 90, .material = .{ .dielectric = .{ .index = 1.5 } } } });
    try objects.append(.{ .sphere = .{ .center = Vec3.init(370, 120, 370), .radius = 120, .material = .{ .metal = .{ .albedo = Color.init(0.8, 0.85, 0.88), .fuzz = 0 } } } });
    return .{
        .objects = objects,
        .camera = .{ .look_from = Vec3.init(278, 278, -800), .look_at = Vec3.init(278, 278, 0), .vfov_degrees = 40, .width = width, .height = height },
        .background = .black,
    };
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const args = parseArgs() catch {
        std.debug.print("usage: zigtracer [--width N] [--height N] [--samples N] [--depth N] [--threads N] [--scene spheres|random|cornell] [--seed N] [--out file.png|file.ppm]\n", .{});
        std.process.exit(2);
    };

    var sc = if (std.mem.eql(u8, args.scene, "random"))
        try randomScene(allocator, args.width, args.height, args.seed)
    else if (std.mem.eql(u8, args.scene, "cornell"))
        try cornellScene(allocator, args.width, args.height)
    else
        try spheresScene(allocator, args.width, args.height);
    defer sc.objects.deinit();

    var world = try scene.Bvh.build(allocator, sc.objects.items);
    defer world.deinit();
    const camera = render.Camera.init(sc.camera);

    var timer = try std.time.Timer.start();
    var img = try render.render(allocator, world, camera, .{ .samples = args.samples, .max_depth = args.depth, .threads = args.threads, .seed = args.seed, .background = sc.background });
    defer img.deinit();
    const ms = timer.read() / std.time.ns_per_ms;

    const file = try std.fs.cwd().createFile(args.out, .{});
    defer file.close();
    var buffered = std.io.bufferedWriter(file.writer());
    if (std.mem.endsWith(u8, args.out, ".ppm")) {
        try image.writePpm(img, buffered.writer());
    } else {
        try image.writePng(allocator, img, buffered.writer());
    }
    try buffered.flush();
    std.debug.print("rendered {d}x{d} with {d} objects, {d} samples/pixel in {d} ms -> {s}\n", .{ args.width, args.height, sc.objects.items.len, args.samples, ms, args.out });
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("vec.zig");
    _ = @import("scene.zig");
    _ = @import("render.zig");
    _ = @import("image.zig");
}
