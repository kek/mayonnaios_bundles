# retroarch-rg40xxv

Builds RetroArch and libretro cores for the Anbernic RG40XXV running Nerves,
and packages them as a tarball that `ScenicRg40xxv.Bundle` installs onto the
device's writable partition.

**Nothing here has been built yet.** The configure flags come from a Buildroot
package written against RetroArch 1.22.2 and reviewed, but no binary has been
produced and none has run on hardware. Treat every claim below as a design
until a green build says otherwise.

## Why this is a separate repository

RetroArch is content, not board support.

`nerves_system_rg40xxv` is the BSP: kernel, device tree, bootloader, drivers,
base userland. An emulator does not belong in it, and putting it there would
mean a core update reflashes an operating system. The numbers make the case
better than the principle does:

    /              66.5M   66.5M      0  100%   read-only squashfs, A/B
    /root          13.7G  279.1M  13.4G    2%   f2fs, writable

The rootfs is completely full. Firmware is written whole on every update. A
~100 MB emulator does not fit in the first and disappears into the second.

Note that this could not have been solved by moving a Buildroot package
somewhere tidier: Nerves passes exactly one `BR2_EXTERNAL` tree and its Docker
build runner bind-mounts only `nerves_system_br` and the system package, so a
package in a sibling repository is invisible to the build. The answer was to
stop making it a Buildroot package.

## Output

    out/retroarch-<version>-aarch64.tar.gz
    out/retroarch-<version>-aarch64.tar.gz.sha256

Inside:

    bin/retroarch
    lib/libretro/*.so
    share/retroarch/...

The device's `:programs` config points at
`/root/bundles/retroarch/current/bin/retroarch`, where `current` is a symlink
the installer moves. Upgrades and rollbacks never change that path.

**gzip, not xz.** The device has no `tar`, no `xz` and no `gzip` binary —
checked, not assumed. Unpacking happens inside the BEAM via `:erl_tar`, which
reads gzip and not xz. The size saving is not available.

## Building

    SYSROOT=... CROSS=aarch64-nerves-linux-gnu- ./build.sh

`SYSROOT` must be the Nerves system's staging sysroot, so RetroArch links
against the exact `libgbm`, `libEGL`, `libGLESv2`, `libdrm` and `libasound`
the device runs. Locally that is:

    ~/.nerves/artifacts/nerves_system_rg40xxv-portable-0.1.0/staging

Building against a generic arm64 distribution instead would produce something
that links fine and fails on hardware, which is the slowest place to find out.

## Open questions

These are the things most likely to be wrong, listed so the first build is
read with suspicion rather than relief.

1. **Where CI gets the sysroot.** `nerves_system_rg40xxv` publishes no release
   artifacts today — its GitHub release page 404s, which is why local builds
   fall back to compiling the system. Until it publishes them, CI here has
   nothing to download and the workflow can only run with a sysroot supplied
   some other way.
2. **Toolchain provenance.** The Nerves aarch64 toolchain artifact is built
   for specific hosts. A Linux CI runner needs the `linux_x86_64` build, not
   the `darwin_arm` one used on this laptop.
3. **fontconfig.** `qb/config.libs.sh` probes for it ungated and there is no
   `--disable-fontconfig`, so the sysroot either provides it or the probe
   fails in whatever way it fails. Not yet observed.
4. **Cores build systems vary.** `cores.txt` assumes `Makefile.libretro` with
   `platform=unix`. True for many cores, not all.
5. **Assets.** `media/assets` is not vendored in the tarball — it lives in a
   separate `libretro/retroarch-assets` repository — so the RGUI menu may want
   files this bundle does not ship.
