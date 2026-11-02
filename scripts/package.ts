// Cross-compiles every platform into npm packages (npm/dist/<platform>) and
// GitHub release assets (npm/dist/release): raw binaries, static libraries,
// SDK tarballs, a macOS .dmg, and Linux .deb/.rpm. Runs on macOS, which the
// .dmg needs. Pins versions in npm/package.json.
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
const release = "npm/dist/release";
const main = await Bun.file("npm/package.json").json();
main.version = version;
main.optionalDependencies = {};

await rm("npm/dist", { recursive: true, force: true });
await mkdir(release, { recursive: true });
await cp("include/speed.h", `${release}/speed.h`);
for (const [platform, zig] of Object.entries(targets)) {
  const [os, cpu] = platform.split("-");
  const name = `@xcaeser/speed-${platform}`;
  const out = `npm/dist/${platform}`;
  const prefix = `zig-out/${zig}`;
  await rm(prefix, { recursive: true, force: true });
  await $`zig build -Dtarget=${zig} -Doptimize=ReleaseFast --prefix ${prefix}`;

  // `speed upgrade` looks for exactly these names.
  const exe = os === "win32" ? "speed.exe" : "speed";
  await cp(`${prefix}/bin/${exe}`, `${release}/speed-${platform}${os === "win32" ? ".exe" : ""}`);
  // Shared libraries keep their names inside the tarball: the dylib's install
  // name and the .so's soname are what loaders look for.
  await $`tar -czf ${release}/libspeed-${platform}.tar.gz -C ${prefix} include lib ${os === "win32" ? "bin/speed.dll" : []}`;
  if (os !== "win32") await cp(`${prefix}/lib/libspeed.a`, `${release}/libspeed-${platform}.a`);
  if (os === "linux") await linuxPackages(`${prefix}/bin/speed`, cpu!);

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
await dmg();

/// One universal binary for both Mac architectures.
async function dmg() {
  const stage = "zig-out/dmg";
  await rm(stage, { recursive: true, force: true });
  await mkdir(stage, { recursive: true });
  await $`lipo -create zig-out/aarch64-macos/bin/speed zig-out/x86_64-macos/bin/speed -output ${stage}/speed`;
  // lipo drops each slice's ad-hoc signature, and Apple Silicon kills unsigned code.
  await $`codesign --force --sign - ${stage}/speed`;
  for (const file of ["LICENSE", "README.md"]) await cp(file, `${stage}/${file}`);
  await $`hdiutil create -quiet -ov -volname ${`speed ${version}`} -srcfolder ${stage} -format UDZO ${release}/speed-${version}.dmg`;
}

async function linuxPackages(binary: string, cpu: string) {
  const config = `zig-out/nfpm-${cpu}.yaml`;
  await Bun.write(config, `name: speed
arch: ${cpu === "x64" ? "amd64" : "arm64"}
platform: linux
version: ${version}
maintainer: xcaeser
description: ${JSON.stringify(main.description)}
homepage: https://github.com/xcaeser/libspeed
license: MIT
contents:
  - src: ${binary}
    dst: /usr/bin/speed
    file_info:
      mode: 0755
  - src: LICENSE
    dst: /usr/share/doc/speed/copyright
`);
  for (const packager of ["deb", "rpm"]) await $`nfpm package --config ${config} --packager ${packager} --target ${release}/`.quiet();
}
