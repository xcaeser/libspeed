# speed

Measure your internet connection: download, upload, latency, jitter, packet
loss, how much latency grows while the link is busy, and whether your Wi-Fi or
your ISP is to blame. One engine, four ways to use it:

1. [CLI](#cli): the `speed` binary for macOS, Linux and Windows
2. [C library](#c-library): `libspeed.a` and `speed.h`, for C, Go, Swift and anything with a C FFI
3. [Zig package](#zig-package): the `speed` module
4. [SDKs](#sdks): TypeScript for Bun

## CLI

```
$ speed run

  Download   1.58 Gbps  28.7 ms under load
  Upload      311 Mbps  78.8 ms under load
  Latency       8.6 ms  jitter 2.3 ms
  Loss            0.0%
  Wi-Fi         4.3 ms  52.1 ms under load

  Your Wi-Fi adds 48 ms while uploading; calls and games feel it.
  Ethernet avoids it.

  Orange S.A. · Cloudflare CDG
```

A rate 20% or more off the usual shows "usually …" next to it, compared with
your last 20 runs on the same network, kept in `history.jsonl` (macOS
`~/Library/Application Support/speed/`, Linux `$XDG_STATE_HOME/speed/` or
`~/.local/state/speed/`, Windows `%LOCALAPPDATA%\speed\`).

The verdict appears only when something adds a noticeable delay. The `Wi-Fi`
row (`Router` on a wired connection) is the round trip to your router.

### Install

```sh
curl -fsSL https://raw.githubusercontent.com/xcaeser/libspeed/main/install.sh | sh
mise use -g github:xcaeser/libspeed
bunx @xcaeser/speed run        # or: npx @xcaeser/speed run
npm install -g @xcaeser/speed  # then: speed run
```

Or download from [Releases](https://github.com/xcaeser/libspeed/releases):

| Platform | Download |
| --- | --- |
| macOS | `speed-darwin-arm64`, `speed-darwin-x64` |
| Debian, Ubuntu | `speed_<version>_amd64.deb`, `_arm64.deb` |
| Fedora, RHEL, openSUSE | `speed-<version>-1.x86_64.rpm`, `.aarch64.rpm` |
| Any Linux | `speed-linux-x64`, `speed-linux-arm64`, static binaries |
| Windows | `speed-win32-x64.exe`, `speed-win32-arm64.exe` |

`speed upgrade` keeps a downloaded binary current. If macOS refuses to open a
downloaded binary, run `xattr -d com.apple.quarantine speed` once.

### Commands

| Command | |
| --- | --- |
| `speed run`, `r` | Run a test. `--explain` says what each figure means; `--json` prints p10/p50/p90 for every figure. |
| `speed upgrade`, `up` | Replace the binary with the latest release, verified by SHA-256. |
| `speed version`, `v` | Print the version. |

### JSON

`speed run --json` prints only the result, for scripts and dashboards. Rates
are in bits per second, latencies in milliseconds, and loss is a fraction
(`null` when ICMP is denied). `gateway` is `null` when the router is unknown or
ignores ICMP; `isp` is `null` when unknown; `verdict` is `null` when nothing
noticeable slows the connection.

```sh
speed run --json | jq '.download.bps.p50 / 1e6'
```

```json
{
  "server": "CDG",
  "isp": { "name": "Orange S.A.", "asn": 3215 },
  "dns_ms": 4.14,
  "latency_ms": { "p10": 6.68, "p50": 7.88, "p90": 12.84 },
  "jitter_ms": 14.88,
  "loss": 0,
  "download": {
    "bps": { "p10": 1544177088, "p50": 1619187504, "p90": 1699716096 },
    "latency_ms": { "p10": 9.57, "p50": 29.07, "p90": 151.67 },
    "gateway_latency_ms": { "p10": 7.08, "p50": 20.17, "p90": 31.44 }
  },
  "upload": {
    "bps": { "p10": 301926656, "p50": 315184848, "p90": 598921184 },
    "latency_ms": { "p10": 23.48, "p50": 43.09, "p90": 60.92 },
    "gateway_latency_ms": { "p10": 4.91, "p50": 8.87, "p90": 15.25 }
  },
  "gateway": {
    "wireless": true,
    "latency_ms": { "p10": 2.9, "p50": 3.74, "p90": 5.0 }
  },
  "verdict": { "segment": "isp", "phase": "upload", "added_ms": 30.08 }
}
```

## C library

Each release has `speed.h` and `libspeed-<platform>.a` for static linking, and
`libspeed-<platform>.tar.gz` with the header, static and shared libraries, and the CLI. See
[`speed.h`](include/speed.h) for the API: one blocking call, `speed_run`, with
an optional progress callback.

```c
speed_result r;
if (speed_run(NULL, NULL, NULL, &r) == SPEED_OK)
    printf("%.0f Mbps down\n", r.download.bps.p50 / 1e6);
```

On Windows only the DLL ships.

## Zig package

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

## SDKs

### TypeScript (Bun)

```ts
import { run } from "@xcaeser/speed";

const result = await run({ onProgress: (p) => console.log(p.phase, p.value) });
console.log(result.download.bps.p50 / 1e6, "Mbps down");
```

The test runs in a worker, so it never blocks the event loop.

Go and Swift link the [C library](#c-library) directly.

## How it measures

Tests run against the nearest [Cloudflare speed test](https://speed.cloudflare.com)
edge, and take about 10 seconds.

- **Latency and jitter**: 20 TCP handshakes to the edge, so server processing
  time never counts.
- **Packet loss**: 50 ICMP echoes, without root or administrator rights: over
  unprivileged sockets on macOS, and on Linux when `net.ipv4.ping_group_range`
  includes your group; through the IP Helper API on Windows. Where ICMP is
  denied, loss shows as `–`.
- **Download and upload**: 6 parallel HTTPS streams per direction. The first
  quarter of each phase, while TCP ramps up, is discarded. A phase ends after
  8 s, at 400 MB, or once throughput holds within 5% for a second.
- **Under load**: TCP handshakes repeated every 200 ms while the link is
  saturated. The gap from idle latency shows bufferbloat.
- **Wi-Fi or ISP**: ICMP echoes to the IPv4 default gateway, idle and every
  200 ms under load. They cross your Wi-Fi or LAN but not your ISP's line, so
  the delay added to them is local and the rest of the delay to the edge is the
  ISP's. A verdict needs +30 ms under load, or 10 ms idle to the router.
  IPv6-only networks, and Windows behind a VPN, get no verdict. A busy router
  answers echoes slower, which counts as local.

Cloudflare throttles an IP for about an hour after a burst of downloads over
10 MB, so requests stay below that. If you are throttled anyway, `speed` says
how long to wait.

## Build

Requires Zig 0.17, and nfpm for `zig build release` (`mise install`).

```sh
zig build test
zig build -Doptimize=ReleaseSmall   # zig-out/{bin,lib,include}
zig build release                  # every platform, into zig-out/{release,npm}
```

## License

[MIT](LICENSE)
