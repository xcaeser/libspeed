# speed

Measure your internet connection: download, upload, latency, jitter, packet
loss, and how much latency grows while the link is busy.

```
$ speed run

  Download   1.58 Gbps  28.7 ms under load
  Upload      311 Mbps  78.8 ms under load
  Latency       8.6 ms  jitter 2.3 ms
  Loss            0.0%

  Cloudflare CDG
```

## Install

```sh
bunx @xcaeser/speed run        # or: npx @xcaeser/speed run
npm install -g @xcaeser/speed  # then: speed run
```

Or download from [Releases](https://github.com/xcaeser/libspeed/releases):

| Platform | Download |
| --- | --- |
| macOS | `speed-<version>.dmg` (Apple Silicon and Intel) |
| Debian, Ubuntu | `speed_<version>_amd64.deb`, `_arm64.deb` |
| Fedora, RHEL, openSUSE | `speed-<version>-1.x86_64.rpm`, `.aarch64.rpm` |
| Any Linux | `speed-linux-x64`, `speed-linux-arm64`, static binaries |
| Windows | `speed-win32-x64.exe`, `speed-win32-arm64.exe` |

`speed upgrade` keeps a downloaded binary current.

The macOS binary is not notarized yet. If macOS refuses to open it, run
`xattr -d com.apple.quarantine speed` once.

## Commands

| Command | |
| --- | --- |
| `speed run` | Run a test. `--json` prints p10/p50/p90 for every figure. |
| `speed upgrade` | Replace the binary with the latest release, verified by SHA-256. |
| `speed version` | Print the version. |

## JSON

`speed run --json` prints only the result, for scripts and dashboards. Rates
are in bits per second, latencies in milliseconds, and loss is a fraction
(`null` when ICMP is denied).

```sh
speed run --json | jq '.download.bps.p50 / 1e6'
```

```json
{
  "server": "CDG",
  "dns_ms": 4.14,
  "latency_ms": { "p10": 6.68, "p50": 7.88, "p90": 12.84 },
  "jitter_ms": 14.88,
  "loss": 0,
  "download": {
    "bps": { "p10": 1544177088, "p50": 1619187504, "p90": 1699716096 },
    "latency_ms": { "p10": 9.57, "p50": 29.07, "p90": 151.67 }
  },
  "upload": {
    "bps": { "p10": 301926656, "p50": 315184848, "p90": 598921184 },
    "latency_ms": { "p10": 23.48, "p50": 43.09, "p90": 60.92 }
  }
}
```

## How it measures

Tests run against the nearest [Cloudflare speed test](https://speed.cloudflare.com)
edge, and take about 10 seconds.

- **Latency and jitter**: 20 TCP handshakes to the edge, so server processing
  time never counts.
- **Packet loss**: 50 ICMP echoes over unprivileged sockets. This works without
  root on macOS, and on Linux when `net.ipv4.ping_group_range` includes your
  group. Where ICMP is denied, loss shows as `–`.
- **Download and upload**: 6 parallel HTTPS streams per direction. The first
  quarter of each phase, while TCP ramps up, is discarded. A phase ends after
  8 s, at 400 MB, or once throughput holds within 5% for a second.
- **Under load**: TCP handshakes repeated every 200 ms while the link is
  saturated. The gap from idle latency shows bufferbloat.

Cloudflare throttles an IP for about an hour after a burst of downloads over
10 MB, so requests stay below that. If you are throttled anyway, `speed` says
how long to wait.

## Library

`libspeed` is the same engine as a Zig module and a C library.

### Zig

```sh
zig fetch --save https://github.com/xcaeser/libspeed/archive/v<version>.tar.gz
```

```zig
// build.zig
const libspeed = b.dependency("libspeed", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("speed", libspeed.module("speed"));
```

```zig
const speed = @import("speed");

const result = try speed.run(io, gpa, .{});
std.debug.print("{d:.0} Mbps down\n", .{result.download.bps.p50 / 1e6});
```

### C, Go, Swift and others

Each release has `speed.h` and `libspeed-<platform>.a` for static linking, and
`libspeed-<platform>.tar.gz` with the header, static and shared libraries. See
[`speed.h`](include/speed.h) for the API: one blocking call, `speed_run`, with
an optional progress callback.

```c
speed_result r;
if (speed_run(NULL, NULL, NULL, &r) == SPEED_OK)
    printf("%.0f Mbps down\n", r.download.bps.p50 / 1e6);
```

On Windows only the DLL ships.

### TypeScript (Bun)

```ts
import { run } from "@xcaeser/speed";

const result = await run({ onProgress: (p) => console.log(p.phase, p.value) });
console.log(result.download.bps.p50 / 1e6, "Mbps down");
```

The test runs in a worker, so it never blocks the event loop.

## Build

Requires Zig 0.17 (`mise install`).

```sh
zig build test
zig build -Doptimize=ReleaseFast   # zig-out/{bin,lib,include}
bun scripts/package.ts             # every platform, into npm/dist
```

## License

[MIT](LICENSE)
