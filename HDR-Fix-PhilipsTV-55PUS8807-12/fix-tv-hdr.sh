#!/usr/bin/env bash
# One-click HDR EDID fix for the Philips TV (HDMI-A-1) connected to this machine.
#
# This TV's EDID reports a bogus ~8000 nit HDR peak-luminance value instead of
# its real ~500 nits, which makes KWin/Wayland's HDR tone-mapping curve go
# wrong (washed out / grayscale look). This re-reads the TV's live EDID over
# I2C, patches just that value to 500 nits, installs it under
# /usr/lib/firmware/edid/, and wires up the drm.edid_firmware kernel parameter
# for whichever bootloader is present (GRUB or CachyOS's sdboot-manage),
# rebuilding the initramfs/boot config as needed.
#
# Safe to re-run any time (e.g. after a GPU driver or TV firmware update) -
# it always re-reads the live EDID and skips anything already in place.
# Every config file it touches gets a timestamped .bak copy first.
#
# NOTE: as of the driver version this was set up with (615.71.09), the
# proprietary NVIDIA driver has been observed to ignore this kernel parameter
# at boot anyway - the actual fix in use is routing HDR through gamescope
# (`gamescope --hdr-enabled -- %command%` as a Steam launch option). This
# script exists so the EDID is already correct for the day NVIDIA fixes that,
# or if you switch to amdgpu/Intel/nouveau, where this reliably works.
#
# Usage: ./fix-tv-hdr.sh          (applies it, reboot afterwards)
#        ./fix-tv-hdr.sh --no-rebuild   (writes config, skips grub-mkconfig/mkinitcpio)
set -euo pipefail
DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec sudo python3 "$DIR/edid_hdr_tool.py" auto-fix \
    --bus 3 \
    --connector HDMI-A-1 \
    --nits 500 \
    "$@"
