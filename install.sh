#!/bin/sh
# Installs the latest speed release for macOS or Linux, verified against the
# SHA-256 digest GitHub computed on upload:
#   curl -fsSL https://raw.githubusercontent.com/xcaeser/libspeed/main/install.sh | sh
# SPEED_INSTALL_DIR overrides the default ~/.local/bin.
set -eu

case "$(uname -s)" in
  Darwin) os=darwin ;;
  Linux) os=linux ;;
  *) echo "speed has no build for $(uname -s) here. Try: npm install -g @xcaeser/speed" >&2; exit 1 ;;
esac
case "$(uname -m)" in
  arm64 | aarch64) arch=arm64 ;;
  x86_64 | amd64) arch=x64 ;;
  *) echo "speed has no build for $(uname -m)." >&2; exit 1 ;;
esac
asset="speed-$os-$arch"

# The release JSON, whitespace stripped so one asset's fields sit on one line.
release=$(curl -fsSL -H 'accept: application/vnd.github+json' \
  https://api.github.com/repos/xcaeser/libspeed/releases/latest | tr -d ' \n')
tag=$(printf '%s' "$release" | grep -o '"tag_name":"[^"]*"' | cut -d'"' -f4)
# The first digest after this asset's name is its own.
expected=$(printf '%s' "$release" | sed "s/.*\"name\":\"$asset\"//" | grep -o '"digest":"sha256:[0-9a-f]*"' | head -1 | cut -d: -f3 | tr -d '"')
if [ -z "$tag" ] || [ ${#expected} -ne 64 ]; then
  echo "speed: could not read the release of $asset from GitHub." >&2; exit 1
fi

dir="${SPEED_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$dir"
curl -fsSL "https://github.com/xcaeser/libspeed/releases/download/$tag/$asset" -o "$dir/speed.new"
if command -v sha256sum > /dev/null; then
  actual=$(sha256sum "$dir/speed.new" | cut -d' ' -f1)
else
  actual=$(shasum -a 256 "$dir/speed.new" | cut -d' ' -f1)
fi
if [ "$actual" != "$expected" ]; then
  rm -f "$dir/speed.new"
  echo "speed: the download does not match its SHA-256 digest." >&2; exit 1
fi
chmod +x "$dir/speed.new"
mv "$dir/speed.new" "$dir/speed"

echo "Installed speed $("$dir/speed" version) to $dir/speed"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add $dir to your PATH to run it as speed." ;;
esac
