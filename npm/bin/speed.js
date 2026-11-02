#!/usr/bin/env node
// Runs the prebuilt binary from the platform package npm installed alongside.
import { spawnSync } from "node:child_process";
import { createRequire } from "node:module";
import { dirname, join } from "node:path";

const platform = `${process.platform}-${process.arch}`;
let dir;
try {
  dir = dirname(createRequire(import.meta.url).resolve(`@xcaeser/speed-${platform}/package.json`));
} catch {
  console.error(`speed: no prebuilt binary for ${platform}`);
  process.exit(1);
}

const exe = join(dir, process.platform === "win32" ? "speed.exe" : "speed");
const child = spawnSync(exe, process.argv.slice(2), { stdio: "inherit" });
if (child.error) throw child.error;
if (child.signal) process.kill(process.pid, child.signal);
process.exit(child.status ?? 1);
