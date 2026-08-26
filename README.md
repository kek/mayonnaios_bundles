# mayonnaios_bundles

Cross-built native apps for [MayonnaiOS](https://github.com/kek/mayonnaios) on
the Anbernic RG40XXV, packaged as tarballs that `MayonnaiOS.Bundle` installs
onto the device's writable partition and verifies by SHA-256.

    retroarch/    RetroArch + libretro cores    retroarch/build.sh
    moonlight/    Moonlight Embedded            moonlight/build.sh

## Why this is a separate repository

Apps are content, not board support.

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

## The shape of a bundle

    bin/<app>          what the device's :programs config points at, through
                       the `current` symlink the installer maintains
    lib/               anything bin/<app> needs beyond the rootfs
    share/<app>/       configs, autoconfigs, controller mappings

**Every build links against the Nerves system's staging sysroot** — the exact
`libgbm`, `libEGL`, `libGLESv2`, `libdrm`, `libasound`, `libssl` the device
runs, from the same Buildroot output. Building against a generic arm64
distribution instead produces something that links fine and fails on
hardware, which is the slowest place to find out.

**gzip, not xz.** The device has no `tar`, no `xz` and no `gzip` binary —
checked, not assumed. Unpacking happens inside the BEAM via `:erl_tar`, which
reads gzip and not xz.

## Building

    SYSROOT=... CROSS=aarch64-nerves-linux-gnu- ./retroarch/build.sh
    SYSROOT=... CROSS=aarch64-nerves-linux-gnu- ./moonlight/build.sh

`SYSROOT` is the Nerves system staging sysroot; locally that is

    ~/.nerves/artifacts/nerves_system_rg40xxv-portable-*/staging

CI builds each app on its own workflow — `retroarch/**` changes build
RetroArch, `moonlight/**` changes build Moonlight — and attaches tarballs to
the release when a tag is pushed: `v*` or `retroarch-v*` for RetroArch,
`moonlight-v*` for Moonlight.

## RetroArch

`retroarch/build.sh` builds RetroArch (KMS/EGL/GLES2, ALSA, udev input, RGUI
menu, no X11/Wayland/D-Bus/systemd because the device has none) and every
core in `retroarch/cores.txt`, then packages the bundle plus each core again
on its own — the per-core tarballs are what `MayonnaiOS.Cores` fetches when
someone picks a core from the upload page, and downloading a 40 MB bundle to
add a 3 MB core would be the wrong trade on a handheld's WiFi.

Seven releases of this have run on hardware. The lessons that cost the most
are written where they were learned: udev is not optional (`build.sh`), the
joypad autoconfig's numbers are key-bit indices rather than evdev codes
(`autoconfig/gpio-keys-gamepad.cfg`), and the bundle's `retroarch.cfg` must
not name directories at all (`.github/workflows/retroarch.yml`).

Known limits: `cores.txt` assumes `Makefile.libretro` with `platform=unix`,
which is true for many cores and not all; and RGUI's optional assets are not
vendored, so the menu is plain.

## Moonlight

`moonlight/build.sh` builds [Moonlight
Embedded](https://github.com/moonlight-stream/moonlight-embedded) 2.7.1 as an
SDL-on-KMSDRM client: the device has no X11 and none of the vendor decode
paths Moonlight knows (Pi, Amlogic, Rockchip, i.MX), so video is SDL over the
same KMS/GBM/GLES2 stack RetroArch drives, and decoding is ffmpeg in
software.

The sysroot has openssl, expat, uuid, zlib, alsa and udev; everything else is
built static and folded in — opus, libevdev, libcurl, an ffmpeg cut down to
exactly the H.264 and HEVC decoders, and SDL2 with only the KMSDRM backend.
One patch against upstream, in `moonlight/patches/` with its reasoning
inline: autodiscovery is stubbed out because Avahi needs a D-Bus the device
does not have, and libcurl is found through pkg-config so its static
transitive dependencies actually make it onto the link line.

The libevdev tarball is vendored in `moonlight/vendor/` rather than fetched:
freedesktop.org failed two CI runs in one afternoon, and 460 KB of tarball
that never changes is cheaper than a flaky download. Everything else comes
from hosts that have not earned that treatment yet.

**Not yet run on hardware.** Treat these as designs until the device says
otherwise:

1. **Software decode budget.** Four Cortex-A53s decoding 720p30 H.264 is
   plausible and unproven. `moonlight/moonlight.conf` starts there and says
   what to lower first. The Cedrus VPU could decode this in hardware some
   day, but that is the V4L2 request API, and neither this ffmpeg nor
   Moonlight's SDL path speaks it.
2. **The pad under SDL.** RetroArch reads the gamepad through udev with a
   shipped autoconfig; Moonlight reads it through SDL's game controller API,
   which needs a mapping line for `gpio-keys-gamepad` in
   `gamecontrollerdb.txt`. The GUID SDL derives on the device is not known
   until SDL runs on the device, so the first session may be display-only
   until that line is captured (`moonlight map` exists for exactly this).
3. **Mode setting on a 640x480 panel.** SDL asks for a fullscreen window at
   the stream resolution; KMSDRM has one mode to offer. The expectation is a
   640x480 surface with the GPU scaling the decoded frame, but that is an
   expectation.
4. **Pairing UX.** `moonlight pair <host>` prints a PIN that must be typed
   into the host. That is a two-device ceremony the launcher does not stage
   yet; until it does, pairing happens once over SSH.
