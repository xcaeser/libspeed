// Calls speed_run on this thread; layouts mirror include/speed.h.
import { dlopen, FFIType, JSCallback, ptr } from "bun:ffi";
import { dirname, join } from "node:path";
import type { Load, Options, Phase, Result, Summary } from "./index.ts";

declare const self: Worker;

const files: Record<string, string> = { darwin: "libspeed.dylib", linux: "libspeed.so", win32: "speed.dll" };
const pkg = Bun.resolveSync(`@xcaeser/speed-${process.platform}-${process.arch}/package.json`, import.meta.dir);
const lib = dlopen(join(dirname(pkg), files[process.platform]!), {
  speed_run: { args: [FFIType.ptr, FFIType.function, FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
});

const phases: Phase[] = ["latency", "download", "upload"];
const errors = [null, "rate_limited", "dns", "network", "out_of_memory"] as const;

self.onmessage = ({ data }: MessageEvent<Omit<Options, "onProgress">>) => {
  const options = new DataView(new ArrayBuffer(24));
  const host = data.host ? Buffer.from(`${data.host}\0`) : null;
  if (host) options.setBigUint64(0, BigInt(ptr(host)), true);
  options.setUint8(8, data.streams ?? 0);
  options.setUint32(12, data.durationMs ?? 0, true);
  options.setUint16(16, data.pings ?? 0, true);

  const progress = new JSCallback(
    (_context: unknown, phase: number, value: number, progress: number) =>
      postMessage({ progress: { phase: phases[phase], value, progress } }),
    { args: [FFIType.ptr, FFIType.i32, FFIType.f64, FFIType.f32], returns: FFIType.void },
  );
  const out = new Float64Array(21);
  const status = lib.symbols.speed_run(options, progress.ptr, null, out);
  progress.close();

  if (status !== 0) return postMessage({ error: errors[status] ?? "network" });
  postMessage({ result: decode(out) });
};

function decode(f: Float64Array): Result {
  const colo = new TextDecoder().decode(new Uint8Array(f.buffer, 0, 3));
  const summary = (i: number): Summary => ({ p10: f[i]!, p50: f[i + 1]!, p90: f[i + 2]! });
  const known = (x: number) => (Number.isNaN(x) ? null : x);
  const load = (i: number): Load => ({ bps: summary(i), latencyMs: summary(i + 3), retransmits: known(f[i + 6]!) });
  return {
    server: colo.startsWith("\0") ? null : colo,
    dnsMs: f[1]!,
    latencyMs: summary(2),
    jitterMs: f[5]!,
    loss: known(f[6]!),
    download: load(7),
    upload: load(14),
  };
}
