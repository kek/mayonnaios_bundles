#!/usr/bin/env bash
#
# Cross-compile RetroArch for the Anbernic RG40XXV and emit a bundle that
# ScenicRg40xxv.Bundle can install.
#
# Output:
#   out/retroarch-<version>-aarch64.tar.gz
#   out/retroarch-<version>-aarch64.tar.gz.sha256
#
# Layout inside the tarball -- bin/retroarch is what the device's :programs
# config points at, through the `current` symlink the installer maintains:
#
#   bin/retroarch
#   lib/libretro/*.so
#   share/retroarch/...
#
# gzip and not xz on purpose. The device has no tar, no xz and no gzip binary
# at all; unpacking is :erl_tar inside the BEAM, which reads gzip and not xz.
# Checked on the device, not assumed.
#
set -euo pipefail

# Resolved before anything cd's anywhere. $0 is relative when the script is
# invoked as ./build.sh, and the core loop runs after a cd into the RetroArch
# source tree, so a late $(dirname "$0") looks for cores.txt in the wrong
# directory and reports it as missing.
here="$(cd "$(dirname "$0")" && pwd)"

RETROARCH_VERSION="${RETROARCH_VERSION:-1.22.2}"
SYSROOT="${SYSROOT:?set SYSROOT to the Nerves system staging sysroot}"
CROSS="${CROSS:?set CROSS to the toolchain prefix, e.g. aarch64-nerves-linux-gnu-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

work="${WORK:-$here/work}"
out="${OUT:-$here/out}"
stage="$work/stage"

mkdir -p "$work" "$out"
rm -rf "$stage"
mkdir -p "$stage/bin" "$stage/lib/libretro" "$stage/share/retroarch"

# The sysroot is the whole point of building here rather than against a
# generic arm64 distribution: these are the exact libgbm, libEGL, libGLESv2,
# libdrm and libasound the device runs, from the same Buildroot output. Link
# against anything else and a soname mismatch shows up as a runtime failure on
# hardware, which is the slowest possible place to find it.
export CC="${CROSS}gcc"
export CXX="${CROSS}g++"
export AR="${CROSS}ar"
export STRIP="${CROSS}strip"
export PKG_CONFIG_SYSROOT_DIR="$SYSROOT"
export PKG_CONFIG_LIBDIR="$SYSROOT/usr/lib/pkgconfig:$SYSROOT/usr/share/pkgconfig"

# Tell qb which pkg-config to use, or it will not find one at all.
#
# qb/qb.comp.sh:129 looks only for ${CROSS_COMPILE}pkgconf and
# ${CROSS_COMPILE}pkg-config -- the Buildroot-style prefixed wrapper. We do not
# have one, and --host sets CROSS_COMPILE, so an unprefixed pkg-config sitting
# in PATH is invisible to it:
#
#     Checking for pkg-config ... none
#     Warning: pkg-config not found, package checks will fail.
#
# Every "package X" check then answers no while the raw link tests answer yes,
# so configure falls back to searching host paths like /usr/include/alsa and
# dies with "Forced to build with library -lasound, but cannot locate" -- a
# message that points at the sysroot when the fault is the probe. The variable
# is honoured from the environment, so this is the whole fix.
export PKG_CONF_PATH="${PKG_CONF_PATH:-pkg-config}"

# Tell qb the TARGET operating system, because it otherwise uses the build
# machine's.
#
# qb/qb.system.sh:4-22 only derives OS from CROSS_COMPILE for mingw and djgpp;
# every other cross prefix falls through to `uname -s`. Building on macOS then
# gives OS=Darwin for an aarch64 Linux target, and Makefile.common:136 adds
#
#     MINVERFLAGS = -mmacosx-version-min=10.15 -stdlib=libc++
#
# to every compile, which the Nerves gcc rejects outright:
#
#     error: unrecognized command-line option '-mmacosx-version-min=10.15'
#
# OS is read from the environment and both guards check it, so setting it here
# stops the fallback. Harmless on a Linux builder, where it is already Linux.
export OS="${OS:-Linux}"
# Set, not appended to. The ambient values belong to the build machine and
# have no business in a cross compile: this laptop's shell exports
#
#     LDFLAGS=-L/opt/homebrew/opt/postgresql@16/lib
#     CPPFLAGS=-I/opt/homebrew/opt/postgresql@16/include
#
# from a Homebrew postgres setup, and an earlier version of this script
# inherited them -- the first successful build linked its core with a host
# library path on the command line. Nothing resolved from there so nothing
# broke, which is the bad kind of harmless: a host -I or -L that does match
# something produces an aarch64 binary with x86 headers' assumptions baked in,
# and the failure surfaces on the device.
export CFLAGS="--sysroot=$SYSROOT -O2"
export CXXFLAGS="--sysroot=$SYSROOT -O2"
export LDFLAGS="--sysroot=$SYSROOT"
export CPPFLAGS="--sysroot=$SYSROOT"

say() { printf '\n=== %s\n' "$*"; }

say "fetching RetroArch $RETROARCH_VERSION"
src="$work/RetroArch-$RETROARCH_VERSION"
if [ ! -d "$src" ]; then
    curl -fsSL "https://github.com/libretro/RetroArch/archive/refs/tags/v${RETROARCH_VERSION}.tar.gz" \
        -o "$work/retroarch.tar.gz"
    tar -xzf "$work/retroarch.tar.gz" -C "$work"
fi

say "configuring"
cd "$src"

# --host is not here to find a compiler; CC is already set and qb uses it
# directly. It is here because qb/config.libs.sh only skips adding the BUILD
# machine's /usr/lib64 and /opt/local/lib to the link line when CROSS_COMPILE
# is set, and nothing sets CROSS_COMPILE except --host.
#
# The disable list is long because this device has no X11, no Wayland, no
# D-Bus and no systemd, and because every extra probe is another chance for
# configure to find a host library and link it.
#
# udev is the exception, and it is not optional. Built with --disable-udev
# this binary rendered a frame on the Mali-G31 and exited:
#
#     [Video] Graphics driver did not initialize an input driver.
#     [ERROR] [Video] Cannot initialize input driver. Exiting...
#
# On Linux, udev is RetroArch's evdev path. The alternatives are linuxraw,
# which reads console keycodes and cannot see gamepad BTN_* events, and sdl,
# which needs SDL. There is no plain evdev driver, and the target kernel has
# no joydev so /dev/input/js* does not exist. The system ships eudev from
# v0.2.0 for this reason alone.
./configure \
    --prefix=/ \
    --host=aarch64-linux-gnu \
    --enable-threads \
    --enable-dynamic \
    --enable-zlib \
    --disable-builtinzlib \
    --enable-alsa \
    --enable-freetype \
    --enable-kms \
    --enable-egl \
    --enable-opengles \
    --enable-menu \
    --enable-rgui \
    --disable-materialui \
    --disable-ozone \
    --disable-xmb \
    --disable-opengl \
    --disable-opengles3 \
    --disable-vulkan \
    --disable-slang \
    --disable-glslang \
    --disable-spirv_cross \
    --disable-x11 \
    --disable-wayland \
    --disable-qt \
    --disable-sdl \
    --disable-sdl2 \
    --disable-oss \
    --disable-pulse \
    --disable-pipewire \
    --enable-udev \
    --disable-dbus \
    --disable-systemd \
    --disable-libusb \
    --disable-ffmpeg \
    --disable-mpv \
    --disable-v4l2 \
    --disable-cdrom \
    --disable-microphone \
    --disable-overlay \
    --disable-networking \
    --disable-ssl \
    --disable-cheevos \
    --disable-discord \
    --disable-translate \
    --disable-accessibility \
    --disable-online_updater \
    --disable-update_cores \
    --disable-update_core_info \
    --disable-update_assets \
    --disable-langextra \
    --disable-parport \
    --disable-crtswitchres

say "building"
make -j"$JOBS"

say "staging"
"$STRIP" -o "$stage/bin/retroarch" retroarch

# media/assets is not in the source tarball -- it is a separate repository the
# libretro buildbot clones -- so this copies nothing on a clean tree. Left in
# because it costs nothing and works if assets are ever vendored, but the menu
# this bundle ships is RGUI, which needs none of them.
cp -a media/assets/. "$stage/share/retroarch/assets/" 2>/dev/null || true

# The joypad autoconfig, without which RetroArch finds the pad and refuses to
# use it: "[Autoconf] gpio-keys-gamepad (1/1) not configured". Its numbers are
# button indices derived from the device's key bits, not evdev codes; the file
# explains where each one comes from.
mkdir -p "$stage/share/retroarch/autoconfig"
cp "$here/autoconfig/gpio-keys-gamepad.cfg" "$stage/share/retroarch/autoconfig/"

# Directory paths for this bundle, layered at launch with --appendconfig so
# that the player's own settings stay in /root/.config and survive an upgrade.
cp "$here/retroarch.cfg" "$stage/share/retroarch/retroarch.cfg"

say "building cores"
while read -r name repo; do
    case "$name" in ''|\#*) continue ;; esac
    say "core: $name"
    coredir="$work/cores/$name"
    [ -d "$coredir" ] || git clone --depth 1 "$repo" "$coredir"
    make -C "$coredir" -f Makefile.libretro -j"$JOBS" platform=unix
    "$STRIP" -o "$stage/lib/libretro/${name}_libretro.so" "$coredir/${name}_libretro.so"
done < "${CORES:-$here/cores.txt}"

say "packaging"
tarball="$out/retroarch-${RETROARCH_VERSION}-aarch64.tar.gz"

# GNU tar if there is one, because --sort and --numeric-owner make the archive
# reproducible-ish; BSD tar on macOS has neither and fails on the flags rather
# than ignoring them. The bundle is identical either way -- ordering and owner
# ids only affect whether two builds produce the same bytes, not what the
# device unpacks -- so a macOS builder is allowed, just less deterministic.
if command -v gtar >/dev/null 2>&1; then
    gtar --sort=name --owner=0 --group=0 --numeric-owner -czf "$tarball" -C "$stage" .
elif tar --version 2>/dev/null | grep -q GNU; then
    tar --sort=name --owner=0 --group=0 --numeric-owner -czf "$tarball" -C "$stage" .
else
    tar -czf "$tarball" -C "$stage" .
fi

# sha256sum is GNU coreutils; macOS ships shasum. Same digest either way, and
# the format matches so the .sha256 file is interchangeable.
(
    cd "$out"
    base="$(basename "$tarball")"
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$base" > "$base.sha256"
    else
        shasum -a 256 "$base" > "$base.sha256"
    fi
)

say "done"
ls -la "$out"
cat "$tarball.sha256"
