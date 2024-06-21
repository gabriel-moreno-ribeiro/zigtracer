# zigtracer

A physically based path tracer written from scratch in Zig: spheres and
triangles, a bounding volume hierarchy, diffuse, metal, glass and emissive
materials, a thin-lens camera with depth of field, multithreaded rendering,
and PNG and PPM writers that need no libraries.

```sh
zig build -Doptimize=ReleaseFast
./zig-out/bin/zigtracer --scene spheres --width 800 --height 450 --samples 200 --out spheres.png
./zig-out/bin/zigtracer --scene random  --samples 100 --out random.png
./zig-out/bin/zigtracer --scene cornell --width 400 --height 400 --samples 400 --out cornell.png
zig build test
```

Options: `--width`, `--height`, `--samples` (rays per pixel), `--depth`
(max bounces), `--threads` (default: all cores), `--seed`,
`--scene spheres|random|cornell`, `--out file.png|file.ppm`.

## How it works

- **Rays and vectors** (`vec.zig`): a small `Vec3` with the usual algebra,
  reflection and Snell refraction, and rejection-sampled random directions.
- **Geometry** (`scene.zig`): analytic ray/sphere intersection with the
  nearest-root rule and inside/outside normals, and Moeller-Trumbore
  ray/triangle intersection. Every object has an axis-aligned bounding box.
- **BVH**: objects are recursively split at the median centroid along the
  widest axis. A ray test descends only into boxes it actually crosses
  (slab test), so a scene with hundreds of spheres costs a handful of box
  tests per ray instead of hundreds of sphere tests.
- **Materials**: Lambertian scattering (cosine-weighted through a random
  unit vector on the normal), metal with fuzz, dielectric with Schlick
  reflectance and total internal reflection, and emissive surfaces for
  lights. The Cornell box is lit only by an emitter, so light bounces off
  the coloured walls onto the spheres.
- **Path tracing** (`render.zig`): each sample shoots a jittered ray
  through the pixel (and from a random point on the lens for depth of
  field), then follows it through up to `depth` bounces, multiplying the
  throughput by each attenuation and adding emission. Pixels average their
  samples; output is gamma corrected.
- **Threads**: worker threads pull rows from an atomic counter, each with
  its own seeded random generator, so renders are deterministic for a given
  seed and thread count.
- **Encoders** (`image.zig`): binary PPM, and PNG with the IHDR/IDAT/IEND
  chunks, CRC-32, and a zlib stream of stored deflate blocks plus Adler-32,
  all implemented here.

## Tests

`zig build test` covers vector algebra, Snell's law, sampling, sphere and
triangle intersections, the slab test, BVH results against brute force on
random rays, camera ray directions, a rendered image (a red emissive sphere
on black: red centre, black corner), determinism, CRC/Adler test vectors,
and that the PNG output decodes with the standard library's zlib.

## License

MIT
