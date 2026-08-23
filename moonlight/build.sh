#!/usr/bin/env bash
#
# Cross-compile Moonlight Embedded for the Anbernic RG40XXV and emit a bundle
# that MayonnaiOS.Bundle can install.
#
# Output:
#   out/moonlight-<version>-aarch64.tar.gz
#   out/moonlight-<version>-aarch64.tar.gz.sha256
#
# Layout inside the tarball -- bin/moonlight is what the device's :programs
# config points at, through the `current` symlink the installer maintains:
#
#   bin/moonlight
#   lib/libgamestream.so.*        (rpath $ORIGIN/../lib finds these)
#   lib/libmoonlight-common.so.*
#   share/moonlight/gamecontrollerdb.txt
#   share/moonlight/moonlight.conf
#
# gzip and not xz for the same reason as the RetroArch bundle: the device has
# no tar, no xz and no gzip binary, unpacking is :erl_tar inside the BEAM, and
# :erl_tar reads gzip and not xz.
#
# The sysroot provides what the device rootfs actually ships -- openssl,
# expat, uuid, zlib, alsa, udev, libdrm, gbm, EGL, GLESv2 -- and everything
# Moonlight needs beyond that is built here as a static library and linked in:
#
#   opus      audio decoding; not in the sysroot
#   libevdev  gamepad input; not in the sysroot
#   curl      HTTPS pairing and session control; not in the sysroot
#   ffmpeg    H.264/HEVC decoding, cut down to just those two decoders;
#             software decode on the A53s, because the Cedrus VPU needs the
#             V4L2 request API and nothing in this chain speaks it yet
#   SDL2      display and input; KMSDRM video backend, because this device
#             has no X11 and no Wayland. SDL dlopens libdrm/gbm/EGL/asound at
#             runtime, and those .so files are on the device -- RetroArch
#             already links them.
#
# Static and with -fPIC throughout, because libcurl ends up inside
# libgamestream.so, which is a shared library and refuses non-PIC objects at
# link time on aarch64.
set -euo pipefail

# Resolved before anything cd's anywhere, for the same reason as in
# retroarch/build.sh: a late $(dirname "$0") after a cd resolves relative to
# the wrong directory.
here="$(cd "$(dirname "$0")" && pwd)"

MOONLIGHT_VERSION="${MOONLIGHT_VERSION:-2.7.1}"
OPUS_VERSION="${OPUS_VERSION:-1.5.2}"
EVDEV_VERSION="${EVDEV_VERSION:-1.13.3}"
CURL_VERSION="${CURL_VERSION:-8.11.1}"
FFMPEG_VERSION="${FFMPEG_VERSION:-7.1}"
SDL2_VERSION="${SDL2_VERSION:-2.30.9}"

SYSROOT="${SYSROOT:?set SYSROOT to the Nerves system staging sysroot}"
CROSS="${CROSS:?set CROSS to the toolchain prefix, e.g. aarch64-nerves-linux-gnu-}"
JOBS="${JOBS:-$(nproc 2>/dev/null || sysctl -n hw.ncpu 2>/dev/null || echo 4)}"

# The autotools --host triplet is the toolchain prefix without its trailing
# dash. aarch64-nerves-linux-gnu is a real triplet, so this works for both
# the local darwin toolchain and CI's linux one.
host_triplet="$(basename "${CROSS%-}")"

work="${WORK:-$here/work}"
out="${OUT:-$here/out}"
deps="$work/deps"
stage="$work/stage"

mkdir -p "$work" "$out" "$deps"
rm -rf "$stage"
mkdir -p "$stage"

export CC="${CROSS}gcc"
export CXX="${CROSS}g++"
export AR="${CROSS}ar"
export RANLIB="${CROSS}ranlib"
export NM="${CROSS}nm"
export STRIP="${CROSS}strip"

# Set, not appended to -- the ambient values belong to the build machine, and
# retroarch/build.sh records what a leaked Homebrew -L once did. -fPIC is not
# optional here: these static archives are absorbed into shared libraries.
export CFLAGS="--sysroot=$SYSROOT -O2 -fPIC"
export CXXFLAGS="--sysroot=$SYSROOT -O2 -fPIC"
export CPPFLAGS="--sysroot=$SYSROOT"
# -L$deps/lib because CMake's pkg_check_modules hands its callers bare -l
# names (moonlight links "${EVDEV_LIBRARIES}", which is just "evdev") and
# something has to put the directory on the link line. CMake initializes its
# linker flags from LDFLAGS at configure time, so this covers every target.
export LDFLAGS="--sysroot=$SYSROOT -L$deps/lib"

# pkg-config sees two worlds: the static deps built here, and the sysroot.
#
# The usual cross tool for the second is PKG_CONFIG_SYSROOT_DIR, and it is
# exactly wrong for this build: it prepends the sysroot to *every* path in
# every .pc file, including the ones under $deps, which do not live in the
# sysroot. So instead the sysroot's .pc files are copied out and rewritten to
# carry absolute host paths, and no prefixing happens at all. The compiler
# already has --sysroot, so the rewritten -I/-L paths resolve to the same
# files either way; the .pc files just stop lying about where they are.
pcroot="$work/pcroot"
rm -rf "$pcroot"
mkdir -p "$pcroot"
for d in "$SYSROOT/usr/lib/pkgconfig" "$SYSROOT/usr/share/pkgconfig"; do
    [ -d "$d" ] || continue
    for f in "$d"/*.pc; do
        sed -e "s|=/usr|=$SYSROOT/usr|" \
            -e "s|-I/usr|-I$SYSROOT/usr|g" \
            -e "s|-L/usr|-L$SYSROOT/usr|g" \
            "$f" > "$pcroot/$(basename "$f")"
    done
done
export PKG_CONFIG_LIBDIR="$deps/lib/pkgconfig:$pcroot"
unset PKG_CONFIG_PATH PKG_CONFIG_SYSROOT_DIR 2>/dev/null || true

# --static makes every pkg-config query include Libs.private, which is where
# a static libcurl declares -lssl -lcrypto -lz and a static SDL declares
# -lpthread -ldl. CMake ≥ 3.22 splits arguments out of $PKG_CONFIG, and
# autoconf has always done so. Without this, every consumer of a static .pc
# underlinks and the failure surfaces at the final link -- or worse, at
# runtime on the device.
export PKG_CONFIG="$(command -v pkg-config) --static"

say() { printf '\n=== %s\n' "$*"; }

# --retry-all-errors because a connection that never opens is not a "transient
# error" to curl's plain --retry, and freedesktop.org has already produced
# exactly that failure once in two simultaneous CI runs.
dl() { curl -fsSL --retry 5 --retry-delay 10 --retry-all-errors --connect-timeout 30 "$1" -o "$2"; }

fetch() {
    # fetch <url> <unpacked-dir-name>
    local url="$1" dir="$2" tarball
    tarball="$work/$(basename "$url")"
    if [ ! -d "$work/$dir" ]; then
        say "fetching $dir"
        [ -f "$tarball" ] || dl "$url" "$tarball"
        tar -xf "$tarball" -C "$work"
    fi
}

# Skip a dep whose install artifact is already in $deps -- a rebuild after a
# late failure should not recompile ffmpeg to get back to where it died.
have() { [ -f "$deps/$1" ]; }

say "opus $OPUS_VERSION"
if ! have lib/libopus.a; then
    fetch "https://downloads.xiph.org/releases/opus/opus-$OPUS_VERSION.tar.gz" "opus-$OPUS_VERSION"
    (
        cd "$work/opus-$OPUS_VERSION"
        ./configure --host="$host_triplet" --prefix="$deps" \
            --disable-shared --enable-static --disable-doc --disable-extra-programs
        make -j"$JOBS"
        make install
    )
fi

say "libevdev $EVDEV_VERSION"
if ! have lib/libevdev.a; then
    # The tarball is vendored in vendor/ rather than fetched, because
    # freedesktop.org has now refused two CI runs in one afternoon -- first a
    # connect timeout that plain retries would have covered, then four solid
    # minutes of them that no retry policy covers. It is 460 KB and a given
    # version never changes; the source mirrors tried instead (Buildroot's,
    # LibreELEC's, Gentoo's) were down or 404 the same afternoon. fetch()
    # finds the copy and skips the download; the URL stays as documentation
    # and as the fallback for a version bump, which is also the moment to
    # replace the vendored copy.
    [ -f "$work/libevdev-$EVDEV_VERSION.tar.xz" ] || \
        cp "$here/vendor/libevdev-$EVDEV_VERSION.tar.xz" "$work/" 2>/dev/null || true
    fetch "https://www.freedesktop.org/software/libevdev/libevdev-$EVDEV_VERSION.tar.xz" "libevdev-$EVDEV_VERSION"
    (
        cd "$work/libevdev-$EVDEV_VERSION"
        ./configure --host="$host_triplet" --prefix="$deps" \
            --disable-shared --enable-static
        make -j"$JOBS"
        make install
    )
fi

say "curl $CURL_VERSION"
if ! have lib/libcurl.a; then
    fetch "https://curl.se/download/curl-$CURL_VERSION.tar.gz" "curl-$CURL_VERSION"
    (
        cd "$work/curl-$CURL_VERSION"
        # HTTPS against the sysroot's openssl and nothing else. GameStream
        # hosts present self-signed certificates and libgamestream pins them
        # rather than walking a CA chain, so no CA bundle is baked in -- there
        # is no /etc/ssl on the device for the default probe to find anyway,
        # and letting it probe finds the build machine's.
        ./configure --host="$host_triplet" --prefix="$deps" \
            --disable-shared --enable-static \
            --with-openssl --without-ca-bundle --without-ca-path \
            --without-libpsl --without-brotli --without-zstd \
            --without-nghttp2 --without-libidn2 --without-librtmp \
            --disable-ldap --disable-ldaps --disable-rtsp --disable-ftp \
            --disable-file --disable-dict --disable-telnet --disable-tftp \
            --disable-pop3 --disable-imap --disable-smb --disable-smtp \
            --disable-gopher --disable-mqtt --disable-manual --disable-docs \
            --disable-ntlm
        make -j"$JOBS"
        make install
    )
fi

say "ffmpeg $FFMPEG_VERSION"
if ! have lib/libavcodec.a; then
    fetch "https://ffmpeg.org/releases/ffmpeg-$FFMPEG_VERSION.tar.xz" "ffmpeg-$FFMPEG_VERSION"
    (
        cd "$work/ffmpeg-$FFMPEG_VERSION"
        # Moonlight's ffmpeg.c wants avcodec_find_decoder_by_name("h264") and
        # ("hevc") plus libavutil, and nothing else. Everything else ffmpeg
        # can be is disabled, which turns a half-hour build of a hundred
        # megabytes into a few minutes of the two decoders this device
        # actually plays. --disable-autodetect keeps configure from probing
        # the build machine for libraries the target does not have.
        ./configure \
            --prefix="$deps" \
            --enable-cross-compile --target-os=linux --arch=aarch64 \
            --cc="$CC" --ar="$AR" --ranlib="$RANLIB" --nm="$NM" --strip="$STRIP" \
            --sysroot="$SYSROOT" \
            --pkg-config=pkg-config --pkg-config-flags=--static \
            --enable-static --disable-shared --enable-pic \
            --disable-autodetect --disable-debug \
            --disable-programs --disable-doc \
            --disable-avdevice --disable-avformat --disable-avfilter \
            --disable-swscale --disable-swresample --disable-network \
            --disable-everything \
            --enable-decoder=h264 --enable-decoder=hevc \
            --enable-parser=h264 --enable-parser=hevc
        make -j"$JOBS"
        make install
    )
fi

say "SDL2 $SDL2_VERSION"
if ! have lib/libSDL2.a; then
    fetch "https://github.com/libsdl-org/SDL/releases/download/release-$SDL2_VERSION/SDL2-$SDL2_VERSION.tar.gz" "SDL2-$SDL2_VERSION"
    (
        # KMSDRM is the whole reason SDL is here: it is the only SDL video
        # backend this device can drive, X11 and Wayland being absent. SDL
        # opens libdrm, gbm, EGL, GLESv2 and asound with dlopen at runtime
        # rather than linking them, which is fine here and only here because
        # the device rootfs ships every one of those sonames -- RetroArch
        # links the same set.
        cmake -S "$work/SDL2-$SDL2_VERSION" -B "$work/SDL2-build" \
            -DCMAKE_SYSTEM_NAME=Linux \
            -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
            -DCMAKE_C_COMPILER="$CC" \
            -DCMAKE_SYSROOT="$SYSROOT" \
            -DCMAKE_FIND_ROOT_PATH="$deps;$SYSROOT" \
            -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
            -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
            -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
            -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
            -DCMAKE_BUILD_TYPE=Release \
            -DCMAKE_INSTALL_PREFIX="$deps" \
            -DSDL_SHARED=OFF -DSDL_STATIC=ON -DSDL_TEST=OFF \
            -DSDL_KMSDRM=ON \
            -DSDL_X11=OFF -DSDL_WAYLAND=OFF \
            -DSDL_OPENGL=OFF -DSDL_OPENGLES=ON -DSDL_VULKAN=OFF \
            -DSDL_ALSA=ON -DSDL_PULSEAUDIO=OFF -DSDL_PIPEWIRE=OFF \
            -DSDL_JACK=OFF -DSDL_SNDIO=OFF \
            -DSDL_DBUS=OFF -DSDL_IBUS=OFF
        cmake --build "$work/SDL2-build" -j"$JOBS"
        cmake --install "$work/SDL2-build"
    )
fi

say "moonlight-embedded $MOONLIGHT_VERSION"
# The release tarball rather than the git tag, because the tag needs four
# submodules cloned and the tarball ships them. Not fetch(): this tarball has
# no top-level directory -- .github/ sits at its root -- so it gets a
# directory made for it rather than being allowed to spill into work/.
src="$work/moonlight-embedded-$MOONLIGHT_VERSION"
if [ ! -d "$src" ]; then
    say "fetching moonlight-embedded-$MOONLIGHT_VERSION"
    tarball="$work/moonlight-embedded-$MOONLIGHT_VERSION.tar.xz"
    [ -f "$tarball" ] || dl \
        "https://github.com/moonlight-stream/moonlight-embedded/releases/download/v$MOONLIGHT_VERSION/moonlight-embedded-$MOONLIGHT_VERSION.tar.xz" \
        "$tarball"
    mkdir "$src"
    tar -xf "$tarball" -C "$src"
fi

# Two things upstream assumes that this device refutes: that Avahi exists
# (there is no D-Bus and no avahi-daemon, so autodiscovery is stubbed out and
# the launcher supplies the host address), and that libcurl is shared (ours
# is static, so it is queried through pkg-config where its transitive
# dependencies are recorded). See the patch header for both.
if ! grep -q "Autodiscovery is Avahi" "$src/libgamestream/discover.c"; then
    say "patching"
    patch -d "$src" -p1 < "$here/patches/no-avahi-static-curl.patch"
fi

rm -rf "$work/moonlight-build"
# $ORIGIN and not an absolute rpath: bin/moonlight must find its two shared
# libraries in ../lib wherever the bundle lands, and the installer moves a
# `current` symlink across versioned directories.
cmake -S "$src" -B "$work/moonlight-build" \
    -DCMAKE_SYSTEM_NAME=Linux \
    -DCMAKE_SYSTEM_PROCESSOR=aarch64 \
    -DCMAKE_C_COMPILER="$CC" \
    -DCMAKE_SYSROOT="$SYSROOT" \
    -DCMAKE_FIND_ROOT_PATH="$deps;$SYSROOT" \
    -DCMAKE_FIND_ROOT_PATH_MODE_PROGRAM=NEVER \
    -DCMAKE_FIND_ROOT_PATH_MODE_LIBRARY=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_INCLUDE=ONLY \
    -DCMAKE_FIND_ROOT_PATH_MODE_PACKAGE=ONLY \
    -DCMAKE_BUILD_TYPE=Release \
    -DCMAKE_INSTALL_PREFIX=/ \
    -DCMAKE_INSTALL_RPATH='$ORIGIN/../lib:$ORIGIN' \
    -DCMAKE_BUILD_WITH_INSTALL_RPATH=ON \
    -DENABLE_SDL=ON -DENABLE_FFMPEG=ON \
    -DENABLE_X11=OFF -DENABLE_CEC=OFF -DENABLE_PULSE=OFF
cmake --build "$work/moonlight-build" -j"$JOBS"
DESTDIR="$stage" cmake --install "$work/moonlight-build"

say "staging"
# GNUInstallDirs treats "/" as a special prefix and quietly inserts usr/ in
# front of bin, lib and share (while sysconfdir stays /etc). The bundle wants
# them at the root, like the RetroArch bundle has them.
if [ -d "$stage/usr" ]; then
    mv "$stage/usr/"* "$stage/"
    rmdir "$stage/usr"
fi
# Upstream installs an /etc/moonlight.conf and a man page; the device reads
# neither. The bundle's own config goes to share/moonlight, mirroring where
# the RetroArch bundle keeps its retroarch.cfg, and the launcher will pass it
# explicitly.
rm -rf "$stage/etc" "$stage/share/man"
cp "$here/moonlight.conf" "$stage/share/moonlight/moonlight.conf"

"$STRIP" "$stage/bin/moonlight"
# Only the real files; the .so.4 names next to them are symlinks and strip
# would flatten a symlink into a copy.
find "$stage/lib" -name '*.so.*' -type f -exec "$STRIP" --strip-unneeded {} \;

# Identical to retroarch/build.sh's pack, for the identical reason: GNU tar's
# --sort and --numeric-owner make two builds byte-comparable, BSD tar has
# neither, and the device unpacks both the same.
pack() {
    # pack <tarball> <dir>
    if command -v gtar >/dev/null 2>&1; then
        gtar --sort=name --owner=0 --group=0 --numeric-owner -czf "$1" -C "$2" .
    elif tar --version 2>/dev/null | grep -q GNU; then
        tar --sort=name --owner=0 --group=0 --numeric-owner -czf "$1" -C "$2" .
    else
        tar -czf "$1" -C "$2" .
    fi

    (
        cd "$(dirname "$1")"
        base="$(basename "$1")"
        if command -v sha256sum >/dev/null 2>&1; then
            sha256sum "$base" > "$base.sha256"
        else
            shasum -a 256 "$base" > "$base.sha256"
        fi
    )
}

say "packaging"
pack "$out/moonlight-${MOONLIGHT_VERSION}-aarch64.tar.gz" "$stage"

say "done"
ls -la "$out"
for f in "$out"/*.sha256; do cat "$f"; done
