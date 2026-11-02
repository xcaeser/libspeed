// Calls speed_run on this thread; layouts mirror include/speed.h.
import { dlopen, FFIType, JSCallback, ptr } from "bun:ffi";
import { dirname, join } from "node:path";
import type { Load, Options, Phase, Result, Summary, Verdict } from "./index.ts";

declare const self: Worker;

const files: Record<string, string> = { darwin: "libspeed.dylib", linux: "libspeed.so", win32: "speed.dll" };
const pkg = Bun.resolveSync(`@xcaeser/speed-${process.platform}-${process.arch}/package.json`, import.meta.dir);
const lib = dlopen(join(dirname(pkg), files[process.platform]!), {
  speed_run: { args: [FFIType.ptr, FFIType.function, FFIType.ptr, FFIType.ptr], returns: FFIType.i32 },
});

const phases: Phase[] = ["latency", "download", "upload"];
const errors = [null, "rate_limited", "dns", "network", "out_of_memory", "invalid_options"] as const;
const segments: (Verdict["segment"] | null)[] = [null, "local", "isp"];

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
  const out = new Uint8Array(248);
  const status = lib.symbols.speed_run(options, progress.ptr, null, out);
  progress.close();

  if (status !== 0) return postMessage({ error: errors[status] ?? "network" });
  postMessage({ result: decode(out) });
};

function decode(bytes: Uint8Array): Result {
  const view = new DataView(bytes.buffer);
  const f = (offset: number) => view.getFloat64(offset, true);
  const colo = new TextDecoder().decode(bytes.subarray(0, 3));
  const summary = (offset: number): Summary => ({ p10: f(offset), p50: f(offset + 8), p90: f(offset + 16) });
  const known = (offset: number) => (Number.isNaN(f(offset + 8)) ? null : summary(offset));
  const load = (offset: number): Load => ({ bps: summary(offset), latencyMs: summary(offset + 24), gatewayLatencyMs: known(offset + 48) });
  const gateway = known(200);
  const segment = segments[view.getInt32(232, true)];
  return {
    server: colo.startsWith("\0") ? null : colo,
    dnsMs: f(8),
    latencyMs: summary(16),
    jitterMs: f(40),
    loss: Number.isNaN(f(48)) ? null : f(48),
    download: load(56),
    upload: load(128),
    gateway: gateway && { wireless: bytes[224] === 1, latencyMs: gateway },
    verdict: segment ? { segment, phase: phases[view.getInt32(236, true)]!, addedMs: f(240) } : null,
  };
}
