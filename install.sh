#!/bin/sh
# Installs the latest speed release for macOS or Linux:
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

dir="${SPEED_INSTALL_DIR:-$HOME/.local/bin}"
mkdir -p "$dir"
curl -fsSL "https://github.com/xcaeser/libspeed/releases/latest/download/speed-$os-$arch" -o "$dir/speed.new"
chmod +x "$dir/speed.new"
mv "$dir/speed.new" "$dir/speed"

echo "Installed speed $("$dir/speed" version) to $dir/speed"
case ":$PATH:" in
  *":$dir:"*) ;;
  *) echo "Add $dir to your PATH to run it as speed." ;;
esac
