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

RETROARCH_VERSION="${RETROARCH_VERSION:-1.22.2}"
SYSROOT="${SYSROOT:?set SYSROOT to the Nerves system staging sysroot}"
CROSS="${CROSS:?set CROSS to the toolchain prefix, e.g. aarch64-nerves-linux-gnu-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || echo 4)}"

work="${WORK:-$PWD/work}"
out="${OUT:-$PWD/out}"
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
export CFLAGS="--sysroot=$SYSROOT ${CFLAGS:-} -O2"
export CXXFLAGS="--sysroot=$SYSROOT ${CXXFLAGS:-} -O2"
export LDFLAGS="--sysroot=$SYSROOT ${LDFLAGS:-}"

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
# D-Bus, no systemd and no udev, and because every extra probe is another
# chance for configure to find a host library and link it.
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
    --disable-udev \
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
cp -a media/assets/. "$stage/share/retroarch/" 2>/dev/null || true

say "building cores"
while read -r name repo; do
    case "$name" in ''|\#*) continue ;; esac
    say "core: $name"
    coredir="$work/cores/$name"
    [ -d "$coredir" ] || git clone --depth 1 "$repo" "$coredir"
    make -C "$coredir" -f Makefile.libretro -j"$JOBS" platform=unix
    "$STRIP" -o "$stage/lib/libretro/${name}_libretro.so" "$coredir/${name}_libretro.so"
done < "${CORES:-$(dirname "$0")/cores.txt}"

say "packaging"
tarball="$out/retroarch-${RETROARCH_VERSION}-aarch64.tar.gz"
# Deterministic-ish: sorted, fixed owner. Not bit-reproducible (gzip stores a
# timestamp), but the checksum is stable for identical inputs within a run,
# and the .sha256 is what the device trusts.
tar --sort=name --owner=0 --group=0 --numeric-owner -czf "$tarball" -C "$stage" .
( cd "$out" && sha256sum "$(basename "$tarball")" > "$(basename "$tarball").sha256" )

say "done"
ls -la "$out"
cat "$tarball.sha256"
