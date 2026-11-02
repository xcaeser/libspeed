// Bun SDK over libspeed. The test runs in a Worker so it never blocks the
// caller's event loop.

export type Phase = "latency" | "download" | "upload";

export interface Summary {
  p10: number;
  p50: number;
  p90: number;
}

export interface Load {
  bps: Summary;
  /** Round trip while the link is saturated. */
  latencyMs: Summary;
  /** Round trip to the router while the link is saturated; null if unknown. */
  gatewayLatencyMs: Summary | null;
}

export interface Gateway {
  /** Reached over Wi-Fi. */
  wireless: boolean;
  /** Idle round trip to the router. */
  latencyMs: Summary;
}

/** Which side of the router makes the connection feel slow. */
export interface Verdict {
  /** "local": Wi-Fi, cabling or the router. "isp": the line beyond it. */
  segment: "local" | "isp";
  /** "latency": every request; otherwise the direction that fills the queue. */
  phase: Phase;
  addedMs: number;
}

export interface Result {
  /** Edge location code, e.g. "CDG". */
  server: string | null;
  dnsMs: number;
  latencyMs: Summary;
  jitterMs: number;
  /** Fraction of ICMP echoes lost; null when the system denies ICMP. */
  loss: number | null;
  download: Load;
  upload: Load;
  /** Null when the router is unknown or ignores ICMP. */
  gateway: Gateway | null;
  /** Null when nothing noticeable slows the connection, or without a router. */
  verdict: Verdict | null;
}

export interface Progress {
  phase: Phase;
  /** Milliseconds during "latency", bits per second otherwise. */
  value: number;
  /** Completion of the phase in [0, 1]. */
  progress: number;
}

export interface Options {
  host?: string;
  streams?: number;
  /** At least 2000. */
  durationMs?: number;
  pings?: number;
  onProgress?: (progress: Progress) => void;
}

export class SpeedError extends Error {
  constructor(readonly code: "rate_limited" | "dns" | "network" | "out_of_memory" | "invalid_options") {
    super(`speed test failed: ${code}`);
  }
}

export function run({ onProgress, ...options }: Options = {}): Promise<Result> {
  const worker = new Worker(new URL("./worker.ts", import.meta.url));
  return new Promise((resolve, reject) => {
    worker.onmessage = ({ data }) => {
      if (data.progress) return onProgress?.(data.progress);
      worker.terminate();
      if (data.error) reject(new SpeedError(data.error));
      else resolve(data.result);
    };
    worker.onerror = (event) => {
      worker.terminate();
      reject(event.error ?? new Error(event.message));
    };
    worker.postMessage(options);
  });
}
