# RoboPool CPU Renderer

A single-file, dependency-free CPU port of the `robopool.slang` compute shader.
Renders an underwater robotics pool scene (gate, buoy, mission bin, tiled floor,
caustics, particles, haze, vignette) and writes a PNG — the encoder (CRC32,
Adler32, stored deflate) is built in. No GPU, no libraries.

## Run

```sh
zig run -O ReleaseFast render.zig                       # defaults
zig run -O ReleaseFast render.zig -- 1920 1200 2.0 0.3  # width height time turbidity
```

Writes `robopool.png`. Requires Zig 0.16 (uses the new `std.Io` API). Trailing
args are optional and positional; junk or `0` dimensions fall back to the default.

## Parameters

Pass as positional CLI args (see above), in this order:

| Arg | Name        | Default | Meaning                          |
|-----|-------------|---------|----------------------------------|
| 1   | `width`     | 1280    | Output width in pixels           |
| 2   | `height`    | 800     | Output height in pixels          |
| 3   | `time`      | 1.5     | Animation time (caustics, water) |
| 4   | `turbidity` | 1.0     | Water murkiness                  |

## Renders

### Default — `time=1.5`, `turbidity=1.0`
![Default render](robopool.png)

### Murky — `time=6.0`, `turbidity=3.0`
![Murky render](robopool_murky.png)

### Clear — `time=3.0`, `turbidity=0.2`
![Clear render](robopool_clear.png)
