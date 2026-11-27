#!/bin/sh
set -eu

prefix=${XDG_DATA_HOME:-"$HOME/.local/share"}/wasdon/sdk
bindir=${WASDON_BIN_DIR:-"$HOME/.local/bin"}
version=${WASDON_VERSION:-latest}
link=yes
while [ "$#" -gt 0 ]; do
    case "$1" in
        --prefix) prefix=$2; link=no; shift 2 ;;
        --version) version=$2; shift 2 ;;
        *) echo "Usage: install.sh [--prefix directory] [--version vX.Y.Z]" >&2; exit 2 ;;
    esac
done
case "$(uname -s)-$(uname -m)" in
    Darwin-arm64) platform=macos-arm64 ;;
    Darwin-x86_64) platform=macos-x64 ;;
    Linux-x86_64) platform=linux-x64 ;;
    *) echo "Unsupported platform: $(uname -sm)" >&2; exit 1 ;;
esac
releases=https://github.com/anosatsuk124/wasdon-zig/releases
case "$version" in
    latest) base=$releases/latest/download ;;
    v[0-9]*) base=$releases/download/$version ;;
    *) echo "Expected a version tag such as v0.1.0" >&2; exit 2 ;;
esac
base=${WASDON_RELEASE_BASE:-$base}
archive=wasdon-$platform.tar.gz
mkdir -p "$(dirname "$prefix")"
work=$(mktemp -d "$(dirname "$prefix")/.wasdon-install.XXXXXX")
guard=$prefix.install-lock
locked=no
new_link=no
committed=no
cleanup() {
    if [ -d "$work/previous" ] && [ ! -e "$prefix" ]; then
        mv "$work/previous" "$prefix" || return 1
    fi
    if [ "$new_link" = yes ] && [ "$committed" = no ]; then unlink "$bindir/wasdon"; fi
    if [ "$locked" = yes ]; then rmdir "$guard"; fi
    rm -rf "$work"
}
trap cleanup 0
trap 'exit 1' HUP INT TERM
curl -fsSL "$base/$archive" -o "$work/$archive"
curl -fsSL "$base/$archive.sha256" -o "$work/digest"
expected=$(awk 'NR == 1 {print $1}' "$work/digest")
if command -v sha256sum >/dev/null 2>&1; then
    actual=$(sha256sum "$work/$archive" | awk '{print $1}')
else
    actual=$(shasum -a 256 "$work/$archive" | awk '{print $1}')
fi
[ "$actual" = "$expected" ] || { echo "SHA-256 mismatch for $archive" >&2; exit 1; }
mkdir "$work/sdk"
tar -xzf "$work/$archive" -C "$work/sdk"
"$work/sdk/bin/wasdon" language list --json >/dev/null
touch "$work/sdk/.wasdon-install"
mkdir "$guard" || { echo "Another installation holds $guard" >&2; exit 1; }
locked=yes
if [ -e "$prefix" ]; then
    [ -f "$prefix/.wasdon-install" ] || { echo "Destination already exists: $prefix" >&2; exit 1; }
fi
if [ "$link" = yes ]; then
    mkdir -p "$bindir"
    if [ -L "$bindir/wasdon" ] && [ "$(readlink "$bindir/wasdon")" = "$prefix/bin/wasdon" ]; then
        :
    elif [ -e "$bindir/wasdon" ] || [ -L "$bindir/wasdon" ]; then
        echo "An existing command occupies $bindir/wasdon. Choose WASDON_BIN_DIR or --prefix." >&2
        exit 1
    else
        ln -s "$prefix/bin/wasdon" "$bindir/wasdon"
        new_link=yes
    fi
fi
if [ -e "$prefix" ]; then mv "$prefix" "$work/previous"; fi
mv "$work/sdk" "$prefix"
committed=yes
if [ "$link" = yes ]; then
    echo "Installed $bindir/wasdon. Include $bindir in PATH."
else
    echo "Installed $prefix/bin/wasdon"
fi
