// Cross-compiles every platform into npm packages (npm/dist/<platform>) and
// GitHub release assets (npm/dist/release), and pins versions in npm/package.json.
import { $ } from "bun";
import { cp, mkdir, rm } from "node:fs/promises";

const targets = {
  "darwin-arm64": "aarch64-macos",
  "darwin-x64": "x86_64-macos",
  // glibc so libspeed.so loads into ordinary hosts; the CLI links no libc and stays static.
  "linux-arm64": "aarch64-linux-gnu.2.28",
  "linux-x64": "x86_64-linux-gnu.2.28",
  "win32-arm64": "aarch64-windows",
  "win32-x64": "x86_64-windows",
};

const version = (await Bun.file("build.zig.zon").text()).match(/\.version = "(.+)"/)![1]!;
const main = await Bun.file("npm/package.json").json();
main.version = version;
main.optionalDependencies = {};

await rm("npm/dist", { recursive: true, force: true });
await mkdir("npm/dist/release", { recursive: true });
for (const [platform, zig] of Object.entries(targets)) {
  const [os, cpu] = platform.split("-");
  const name = `@xcaeser/speed-${platform}`;
  const out = `npm/dist/${platform}`;
  const prefix = `zig-out/${zig}`;
  await rm(prefix, { recursive: true, force: true });
  await $`zig build -Dtarget=${zig} -Doptimize=ReleaseFast --prefix ${prefix}`;

  // `speed upgrade` looks for exactly these names.
  const exe = os === "win32" ? "speed.exe" : "speed";
  await cp(`${prefix}/bin/${exe}`, `npm/dist/release/speed-${platform}${os === "win32" ? ".exe" : ""}`);
  await $`tar -czf npm/dist/release/libspeed-${platform}.tar.gz -C ${prefix} include lib ${os === "win32" ? "bin/speed.dll" : []}`;

  const files = os === "win32"
    ? [`${prefix}/bin/speed.exe`, `${prefix}/bin/speed.dll`]
    : [`${prefix}/bin/speed`, `${prefix}/lib/libspeed.${os === "darwin" ? "dylib" : "so"}`];
  await mkdir(out, { recursive: true });
  for (const file of [...files, "LICENSE"]) await cp(file, `${out}/${file.split("/").pop()}`);

  await Bun.write(`${out}/package.json`, JSON.stringify({
    name,
    version,
    description: `speed binary and libspeed for ${platform}`,
    license: main.license,
    repository: main.repository,
    os: [os],
    cpu: [cpu],
  }, null, 2) + "\n");
  main.optionalDependencies[name] = version;
  console.log(`${name}@${version}`);
}
await Bun.write("npm/package.json", JSON.stringify(main, null, 2) + "\n");
// npm only packs these from the package's own directory.
for (const file of ["LICENSE", "README.md"]) await cp(file, `npm/${file}`);
