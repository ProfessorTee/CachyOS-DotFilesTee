#!/usr/bin/env python3
"""
edid_hdr_tool.py - dump, decode, patch and (carefully) apply the HDR Static
Metadata block of a display's EDID on Linux.

WHY THIS EXISTS
----------------
Some monitors report a bogus "Desired Content Max Luminance" in their EDID's
CTA-861 HDR Static Metadata Data Block (e.g. 10000 nits instead of a real
~500 nit panel). Wayland compositors (KWin included) build their HDR
tone-mapping curve from that value, so a lying EDID makes HDR content look
crushed, desaturated or grayscale even though the compositor and game are
doing nothing wrong.

This tool lets you:
  1. dump + decode the current EDID and show what your monitor is claiming (info)
  2. patch just the luminance byte(s) to the real value and fix the checksum (patch)
  3. test the patched EDID live via debugfs, without touching your bootloader (test-apply)
  4. install it persistently via the drm.edid_firmware kernel parameter (install)
  5. check what will/won't work on your system before you start (status)

IMPORTANT LIMITS - READ BEFORE USING
-------------------------------------
* This must be run AS ROOT, directly on the real machine whose monitor you
  want to fix. It reads/writes kernel interfaces under /sys, so it cannot be
  run inside a container, VM, or remote sandbox that doesn't own the real
  GPU/display.
* Proprietary NVIDIA driver + Wayland: EDID override here is known to be
  unreliable. The debugfs live-test method (test-apply) sometimes works but
  has been reported to silently disable VRR/G-Sync afterwards. The
  persistent boot-time method (install, via drm.edid_firmware) is frequently
  ignored entirely by the proprietary driver. `status` will warn you about
  this if it detects nvidia. If your GPU uses amdgpu, i915 or xe (Intel) or
  nouveau, both methods are much more reliable.
* Secure Boot with kernel lockdown active blocks the debugfs write (test-apply)
  outright. `status` checks /sys/kernel/security/lockdown and tells you.
* This edits the *luminance metadata* only (what the display claims about
  its brightness). It does not and cannot fix color gamut, EOTF/PQ curve
  bugs, or driver-side HDR bugs (e.g. the current NVIDIA 610.43.x "crushed
  blacks / wrong tonemap when HDR is on" bug some users are hitting
  independent of any EDID issue). Try `status` and the cheaper workarounds
  it prints before going through the full patch/install flow.

Typical flow:
    sudo python3 edid_hdr_tool.py status
    sudo python3 edid_hdr_tool.py info
    sudo python3 edid_hdr_tool.py patch --nits 500 --out /root/edid-fixed.bin
    sudo python3 edid_hdr_tool.py test-apply --connector DP-1 --file /root/edid-fixed.bin
    # ... check if the game/desktop looks right now, and check VRR still works ...
    sudo python3 edid_hdr_tool.py revert --connector DP-1
    # only if the live test looked good AND you accepted the nvidia caveats:
    sudo python3 edid_hdr_tool.py install --connector DP-1 --file /root/edid-fixed.bin
"""

import argparse
import fcntl
import glob
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

I2C_SLAVE = 0x0703  # ioctl constant from linux/i2c-dev.h

FIRMWARE_EDID_DIR = Path("/usr/lib/firmware/edid")
BACKUP_DIR = Path("/root/edid-hdr-tool-backups")


# --------------------------------------------------------------------------
# low-level EDID helpers
# --------------------------------------------------------------------------

def nits_to_code(nits: float) -> int:
    """CTA-861.3 coding: real_value = 50 * 2^(code/32)."""
    if nits <= 0:
        return 0
    code = round(32 * math.log2(nits / 50.0))
    return max(0, min(255, code))


def code_to_nits(code: int) -> float:
    return 50.0 * (2 ** (code / 32.0))


def find_connectors():
    """Return list of (connector_name, edid_path, status_path) for outputs
    that currently have EDID data (i.e. something is plugged in)."""
    out = []
    for status_path in sorted(glob.glob("/sys/class/drm/card*-*/status")):
        edid_path = Path(status_path).parent / "edid"
        if not edid_path.exists():
            continue
        try:
            size = edid_path.stat().st_size
        except OSError:
            continue
        if size == 0:
            continue
        name = Path(status_path).parent.name.split("-", 1)[1]
        out.append((name, edid_path, Path(status_path)))
    return out


def pick_connector(explicit):
    conns = find_connectors()
    if explicit:
        for name, edid_path, status_path in conns:
            if name == explicit:
                return name, edid_path
        die(f"Connector '{explicit}' not found or has no EDID. "
            f"Available: {', '.join(c[0] for c in conns) or '(none)'}")
    if len(conns) == 1:
        return conns[0][0], conns[0][1]
    if not conns:
        die("No connected outputs with EDID data found under /sys/class/drm/.")
    die("Multiple displays with EDID found, pass --connector explicitly: "
        + ", ".join(c[0] for c in conns))


def die(msg):
    print(f"ERROR: {msg}", file=sys.stderr)
    sys.exit(1)


def read_edid(path) -> bytes:
    data = Path(path).read_bytes()
    if len(data) < 128 or len(data) % 128 != 0:
        die(f"'{path}' doesn't look like a valid EDID (size={len(data)}, expected multiple of 128).")
    if data[0:8] != bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]):
        print("WARNING: EDID header magic bytes look wrong, proceeding anyway.", file=sys.stderr)
    return data


def find_hdr_block(edid: bytes):
    """Search all CTA-861 extension blocks for the HDR Static Metadata Data
    Block (extended tag 0x06). Returns dict with absolute offsets, or None."""
    n_ext = edid[126]
    for i in range(1, n_ext + 1):
        base = 128 * i
        if base + 128 > len(edid):
            break
        ext = edid[base:base + 128]
        if ext[0] != 0x02:  # not a CTA-861 extension block
            continue
        dtd_start = ext[2]
        end = dtd_start if dtd_start != 0 else 127
        pos = 4
        while pos < end:
            header = ext[pos]
            length = header & 0x1F
            tag = (header >> 5) & 0x07
            block_start = pos
            block_end = pos + 1 + length
            if block_end > end:
                break
            if tag == 7 and length >= 1 and ext[pos + 1] == 0x06:
                # HDR Static Metadata Data Block found.
                # layout inside block (offsets relative to block_start):
                # 0: header, 1: extended tag (0x06), 2: EOTF support,
                # 3: SM descriptor support, 4: max luminance (optional),
                # 5: max frame-avg luminance (optional), 6: min luminance (optional)
                avail = length - 2  # bytes after the two mandatory ones (EOTF, SM support)
                return {
                    "ext_index": i,
                    "ext_base": base,
                    "block_start": base + block_start,
                    "length": length,
                    "eotf_off": base + block_start + 2,
                    "sm_off": base + block_start + 3,
                    "max_lum_off": base + block_start + 4 if avail >= 1 else None,
                    "max_fall_off": base + block_start + 5 if avail >= 2 else None,
                    "min_lum_off": base + block_start + 6 if avail >= 3 else None,
                }
            pos = block_end
    return None


def fix_ext_checksum(edid: bytearray, ext_index: int):
    base = 128 * ext_index
    block = edid[base:base + 128]
    checksum = (0x100 - (sum(block[:127]) % 0x100)) % 0x100
    edid[base + 127] = checksum


def decode_eotf(byte):
    flags = []
    if byte & 0x01: flags.append("SDR")
    if byte & 0x02: flags.append("HDR traditional gamma")
    if byte & 0x04: flags.append("PQ / ST 2084 (HDR10)")
    if byte & 0x08: flags.append("Hybrid Log-Gamma (HLG)")
    return ", ".join(flags) if flags else "(none advertised)"


# --------------------------------------------------------------------------
# subcommands
# --------------------------------------------------------------------------

def cmd_status(args):
    print("== EDID/HDR override viability check ==\n")

    # secure boot / lockdown
    lockdown_path = Path("/sys/kernel/security/lockdown")
    if lockdown_path.exists():
        val = lockdown_path.read_text().strip()
        active = val.split("[", 1)[-1].split("]", 1)[0] if "[" in val else val
        print(f"Kernel lockdown: {val}")
        if active not in ("none", ""):
            print("  -> Lockdown is ACTIVE. debugfs EDID override (test-apply) will "
                  "very likely be REFUSED. Only the persistent drm.edid_firmware "
                  "route (install) has a chance of working, and even that can be "
                  "blocked depending on your Secure Boot setup.")
        else:
            print("  -> Lockdown inactive, debugfs override should be permitted by the kernel.")
    else:
        print("No /sys/kernel/security/lockdown - can't determine lockdown state on this kernel.")

    # GPU driver detection
    print()
    lsmod = subprocess.run(["lsmod"], capture_output=True, text=True).stdout
    is_nvidia_proprietary = "nvidia_drm" in lsmod and "nvidia" in lsmod
    is_nouveau = "nouveau" in lsmod
    is_amdgpu = "amdgpu" in lsmod
    is_i915 = "i915" in lsmod or "xe" in lsmod
    if is_nvidia_proprietary:
        print("GPU driver: NVIDIA proprietary driver detected.")
        print("  -> KNOWN TO BE UNRELIABLE for EDID override on Wayland:")
        print("     - drm.edid_firmware (persistent, kernel cmdline) is frequently")
        print("       ignored entirely by this driver at boot.")
        print("     - debugfs edid_override (live test) sometimes works, but has")
        print("       been reported to disable VRR/G-Sync afterwards.")
        print("     - There is also a currently open NVIDIA driver bug (610.43.x)")
        print("       causing system-wide 'crushed blacks / wrong tonemap' when HDR")
        print("       is on, independent of any EDID issue. Before doing surgery on")
        print("       your EDID, it is worth first trying, per-game as Steam launch")
        print("       options: unset PROTON_ENABLE_HDR / DXVK_HDR / ENABLE_HDR_WSI")
        print("       and instead route through gamescope: `gamescope --hdr-enabled -- %command%`")
        print("       to see if that alone fixes the grayscale look - it's a lot")
        print("       cheaper than patching EDID firmware and reflects a real bug")
        print("       other RTX users are currently hitting.")
    elif is_nouveau:
        print("GPU driver: nouveau (open) detected - standard DRM EDID override path applies, should work.")
    elif is_amdgpu:
        print("GPU driver: amdgpu detected - standard DRM EDID override path applies, should work.")
    elif is_i915:
        print("GPU driver: Intel i915/xe detected - standard DRM EDID override path applies, should work.")
    else:
        print("GPU driver: could not confidently detect (check `lsmod` yourself).")

    # bootloader detection (only relevant for `install`)
    print()
    if Path("/etc/sdboot-manage.conf").exists():
        print("Bootloader: CachyOS systemd-boot (sdboot-manage) detected.")
        print("  -> `install` will tell you to edit /etc/sdboot-manage.conf and run `sudo sdboot-manage gen`.")
    elif Path("/etc/default/grub").exists():
        print("Bootloader: GRUB detected.")
        print("  -> `install` will tell you to edit /etc/default/grub and run `sudo grub-mkconfig -o /boot/grub/grub.cfg`.")
    elif list(Path("/boot/loader/entries").glob("*.conf")) if Path("/boot/loader/entries").exists() else False:
        print("Bootloader: plain systemd-boot (loader entries) detected.")
        print("  -> `install` will tell you to add the parameter to your /boot/loader/entries/*.conf files directly.")
    elif Path("/boot/limine.conf").exists() or Path("/etc/limine-entry-tool.conf").exists():
        print("Bootloader: Limine detected.")
        print("  -> `install` will tell you where to add the kernel parameter for Limine.")
    else:
        print("Bootloader: could not detect automatically - `install` will just print the raw parameter you need to add.")

    print("\nConnected displays with EDID:")
    for name, edid_path, _ in find_connectors():
        print(f"  {name}  ({edid_path})")


def cmd_info(args):
    connector, edid_path = pick_connector(args.connector) if not args.file else (None, args.file)
    if args.file:
        print(f"Reading EDID from file: {args.file}")
    else:
        print(f"Connector: {connector}  ({edid_path})")
    edid = read_edid(edid_path)

    hdr = find_hdr_block(edid)
    if not hdr:
        print("\nNo HDR Static Metadata Data Block found in this EDID.")
        print("This display either doesn't advertise HDR support at all, or your")
        print("kernel/driver doesn't expose a full EDID via sysfs (some proprietary")
        print("drivers report a truncated/synthetic EDID here).")
        return

    eotf = edid[hdr["eotf_off"]]
    print(f"\nHDR Static Metadata Data Block found in extension block #{hdr['ext_index']}:")
    print(f"  EOTFs supported: {decode_eotf(eotf)}")
    if hdr["max_lum_off"] is not None:
        code = edid[hdr["max_lum_off"]]
        print(f"  Desired Content Max Luminance:            code {code:3d} -> {code_to_nits(code):8.1f} nits")
    else:
        print("  Desired Content Max Luminance:            (not present in this block)")
    if hdr["max_fall_off"] is not None:
        code = edid[hdr["max_fall_off"]]
        print(f"  Desired Content Max Frame-avg Luminance:  code {code:3d} -> {code_to_nits(code):8.1f} nits")
    if hdr["min_lum_off"] is not None:
        code = edid[hdr["min_lum_off"]]
        # min luminance formula per CTA-861.3 uses max_luminance too; keep it simple/approximate here
        print(f"  Desired Content Min Luminance:            code {code:3d} (raw, see CTA-861.3 formula)")

    if hdr["max_lum_off"] is not None and code_to_nits(edid[hdr["max_lum_off"]]) > 2000:
        print("\n  -> This is suspiciously high for a real desktop panel. If your monitor's")
        print("     real peak brightness is much lower (per your specs/measurements), this")
        print("     is very likely the bogus placeholder value causing washed-out/grayscale HDR.")


def cmd_patch(args):
    if args.file:
        edid_path = args.file
        connector = None
    else:
        connector, edid_path = pick_connector(args.connector)

    edid = bytearray(read_edid(edid_path))
    hdr = find_hdr_block(bytes(edid))
    if not hdr or hdr["max_lum_off"] is None:
        die("No patchable 'Desired Content Max Luminance' field found in this EDID's "
            "HDR Static Metadata block. Nothing to patch.")

    old_code = edid[hdr["max_lum_off"]]
    old_nits = code_to_nits(old_code)
    new_code = nits_to_code(args.nits)
    new_nits = code_to_nits(new_code)

    print(f"Max luminance: {old_nits:.1f} nits (code {old_code}) -> {new_nits:.1f} nits (code {new_code})")
    edid[hdr["max_lum_off"]] = new_code

    if args.also_frame_avg and hdr["max_fall_off"] is not None:
        edid[hdr["max_fall_off"]] = new_code
        print(f"Also set max frame-average luminance to the same code ({new_code}).")

    fix_ext_checksum(edid, hdr["ext_index"])

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(bytes(edid))
    print(f"\nPatched EDID written to: {out_path}")

    # keep a backup of the original alongside, so revert/comparison is easy
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    ts = time.strftime("%Y%m%d-%H%M%S")
    orig_backup = BACKUP_DIR / f"{(connector or 'file')}-original-{ts}.bin"
    try:
        shutil.copy2(edid_path, orig_backup)
        print(f"Original backed up to: {orig_backup}")
    except Exception as e:
        print(f"(could not back up original: {e})", file=sys.stderr)


def cmd_dump_i2c(args):
    """Read the EDID directly off the I2C/DDC bus, bypassing /sys/class/drm
    entirely. Needed on setups (e.g. the proprietary NVIDIA driver) where the
    kernel's per-connector `edid` sysfs attribute is empty or missing even
    though the monitor is connected and working fine. Find the right --bus
    number with `ddcutil detect` (look for "I2C bus: /dev/i2c-N").
    Requires the i2c-dev kernel module: `sudo modprobe i2c-dev`.
    """
    require_root()
    bus_path = f"/dev/i2c-{args.bus}"
    if not Path(bus_path).exists():
        die(f"{bus_path} doesn't exist. Run `sudo modprobe i2c-dev` first, "
            f"and confirm the bus number with `ddcutil detect`.")

    fd = os.open(bus_path, os.O_RDWR)
    try:
        fcntl.ioctl(fd, I2C_SLAVE, args.addr)
        # EDID EEPROMs (at 0x50) need their internal read pointer reset to 0
        # with a 1-byte write before a sequential read will start at offset 0.
        os.write(fd, bytes([0x00]))
        data = os.read(fd, args.length)
    except OSError as e:
        die(f"I2C read failed on {bus_path} @ 0x{args.addr:02x}: {e}\n"
            f"(x37 not responding is normal and unrelated - that's the separate "
            f"DDC/CI monitor-control address, EDID lives at 0x50.)")
    finally:
        os.close(fd)

    if len(data) < args.length:
        die(f"Only got {len(data)} of {args.length} requested bytes back.")

    out_path = Path(args.out)
    out_path.parent.mkdir(parents=True, exist_ok=True)
    out_path.write_bytes(data)
    print(f"Read {len(data)} bytes from {bus_path} (addr 0x{args.addr:02x}) -> {out_path}")

    if data[0:8] != bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]):
        print("WARNING: this doesn't start with the standard EDID header "
              "(00 FF FF FF FF FF FF 00) - the read may have picked up garbage. "
              "Double check --bus/--addr and try again.")
    else:
        print("Header magic bytes look correct - this is a real EDID dump.")
        print(f"Run: python3 {sys.argv[0]} info --file {out_path}")


def require_root():
    if os.geteuid() != 0:
        die("This command needs root (sudo).")


def debugfs_paths_for(connector):
    """Return ALL matching debugfs edid_override paths for this connector.
    Multiple can legitimately exist (primary node, render node, PCI-address
    alias) and point at genuinely different underlying debugfs entries -
    some drivers (NVIDIA especially) only honour the override on one of
    them, so we write/clear all of them rather than guessing which."""
    matches = glob.glob(f"/sys/kernel/debug/dri/*/{connector}/edid_override")
    if not matches:
        die(f"No debugfs edid_override file found for connector '{connector}'. "
            f"Is debugfs mounted (/sys/kernel/debug)? Try: sudo mount -t debugfs none /sys/kernel/debug\n"
            f"Looked for: /sys/kernel/debug/dri/*/{connector}/edid_override")
    return matches


def force_reprobe(connector):
    """Best-effort: try the debugfs 'force' knob (off then on) on every
    matching node. Not all drivers implement this file; failures are
    reported but not fatal, since a physical replug remains the fallback."""
    force_paths = glob.glob(f"/sys/kernel/debug/dri/*/{connector}/force")
    if not force_paths:
        print("(no debugfs 'force' file found on this driver - skipping automatic reprobe)")
        return False
    ok_any = False
    for fp in force_paths:
        try:
            Path(fp).write_text("off")
            time.sleep(0.3)
            Path(fp).write_text("on")
            print(f"Forced reprobe via {fp}")
            ok_any = True
        except OSError as e:
            print(f"(couldn't force-reprobe via {fp}: {e})")
    return ok_any


def cmd_test_apply(args):
    require_root()
    lockdown_path = Path("/sys/kernel/security/lockdown")
    if lockdown_path.exists():
        val = lockdown_path.read_text().strip()
        if not val.startswith("[none]"):
            print("WARNING: kernel lockdown looks active - this write will likely fail "
                  "with 'Operation not permitted'. Run `status` for details.", file=sys.stderr)

    dbg_paths = debugfs_paths_for(args.connector)
    data = Path(args.file).read_bytes()
    wrote_any = False
    for dbg_path in dbg_paths:
        try:
            Path(dbg_path).write_bytes(data)
            print(f"Wrote {len(data)} bytes to {dbg_path}")
            wrote_any = True
        except OSError as e:
            print(f"(failed to write {dbg_path}: {e})")
    if not wrote_any:
        die("Could not write the override to any of the matched debugfs paths.")

    print(f"\nWrote to all {len(dbg_paths)} matched node(s) for '{args.connector}' (not just the first),")
    print("since it's driver-dependent which one is actually consulted.")

    print("\nForcing a reprobe automatically now:")
    forced = force_reprobe(args.connector)
    if not forced:
        print("Automatic reprobe wasn't possible on this driver.")
    print("\nEither way, ALSO physically unplug and replug the display cable -")
    print("this remains the most reliable trigger in practice, especially on NVIDIA.")
    print("\nThen check `kscreen-doctor -o` or System Settings to confirm the new")
    print("values are being used, and re-test the game.")
    print("\nNOTE for NVIDIA users: this has been reported to disable VRR/G-Sync")
    print("until reboot. Check that separately if you rely on it.")
    print("\nThis override does NOT survive reboot by itself - that's the point,")
    print("it's your safe way to test before touching the bootloader. Use `revert`")
    print("to clear it early, or just reboot.")


def cmd_revert(args):
    require_root()
    dbg_paths = debugfs_paths_for(args.connector)
    for dbg_path in dbg_paths:
        try:
            # writing zero bytes resets the override on recent kernels
            Path(dbg_path).write_bytes(b"")
            print(f"Cleared override at {dbg_path}")
        except OSError as e:
            print(f"(failed to clear {dbg_path}: {e})")
    force_reprobe(args.connector)
    print("Replug the cable (or reboot) to make sure the real EDID is re-read.")


def cmd_install(args):
    require_root()
    FIRMWARE_EDID_DIR.mkdir(parents=True, exist_ok=True)
    dest_name = args.name or f"{args.connector}-fixed.bin"
    dest = FIRMWARE_EDID_DIR / dest_name
    shutil.copy2(args.file, dest)
    print(f"Copied patched EDID to {dest}")

    param = f"drm.edid_firmware={args.connector}:edid/{dest_name}"
    print(f"\nKernel parameter to add: {param}\n")

    # mkinitcpio: make sure the firmware file is embedded so it's available
    # early enough for the driver's firmware request.
    mkinitcpio_conf = Path("/etc/mkinitcpio.conf")
    if mkinitcpio_conf.exists():
        text = mkinitcpio_conf.read_text()
        rel = str(dest)
        if rel not in text:
            print(f"NOTE: add {rel} to the FILES=() array in /etc/mkinitcpio.conf,")
            print("      then run: sudo mkinitcpio -P")
        else:
            print(f"{rel} already referenced in /etc/mkinitcpio.conf - good, just re-run:")
            print("      sudo mkinitcpio -P")
    else:
        print("No /etc/mkinitcpio.conf found - if you're not on an Arch-based initramfs,")
        print("make sure your initramfs actually embeds the firmware file, or that it's")
        print("available in the real root filesystem early enough for the driver's")
        print("firmware request (varies by distro).")

    print()
    if Path("/etc/sdboot-manage.conf").exists():
        print("Detected CachyOS systemd-boot (sdboot-manage). Steps:")
        print(f"  1. Edit /etc/sdboot-manage.conf, add to LINUX_OPTIONS=\"...\":  {param}")
        print("  2. sudo sdboot-manage gen")
    elif Path("/etc/default/grub").exists():
        print("Detected GRUB. Steps:")
        print(f"  1. Edit /etc/default/grub, append to GRUB_CMDLINE_LINUX_DEFAULT:  {param}")
        print("  2. sudo grub-mkconfig -o /boot/grub/grub.cfg")
    elif Path("/boot/loader/entries").exists():
        print("Detected plain systemd-boot loader entries. Steps:")
        print(f"  1. Add `{param}` to the 'options' line in each /boot/loader/entries/*.conf you boot with.")
    else:
        print("Could not detect your bootloader automatically.")
        print(f"Add this to your kernel command line however your bootloader manages that: {param}")

    print("\nAfter updating the bootloader config and initramfs, reboot, then re-run")
    print("`info` (without --file) to confirm the kernel picked up the new EDID.")
    print("\nReminder: on the proprietary NVIDIA driver this step is frequently")
    print("ignored at boot even when everything above is done correctly. If it")
    print("doesn't take effect, that's a known limitation, not a mistake in these steps.")


def backup_file(path: Path) -> Path:
    backup = path.with_name(path.name + f".bak-{time.strftime('%Y%m%d-%H%M%S')}")
    shutil.copy2(path, backup)
    print(f"Backed up {path} -> {backup}")
    return backup


def ensure_grub_param(grub_file: Path, param: str):
    text = grub_file.read_text()
    if param in text:
        print(f"'{param}' already present in {grub_file}, leaving it alone.")
        return
    backup_file(grub_file)
    m = re.search(r'^GRUB_CMDLINE_LINUX_DEFAULT="([^"]*)"', text, re.MULTILINE)
    if m:
        new_value = (m.group(1) + " " + param).strip()
        text = text[:m.start(1)] + new_value + text[m.end(1):]
    else:
        text = text.rstrip("\n") + f'\nGRUB_CMDLINE_LINUX_DEFAULT="{param}"\n'
    grub_file.write_text(text)
    print(f"Added '{param}' to GRUB_CMDLINE_LINUX_DEFAULT in {grub_file}")


def ensure_sdboot_param(conf_file: Path, param: str):
    text = conf_file.read_text()
    if param in text:
        print(f"'{param}' already present in {conf_file}, leaving it alone.")
        return
    backup_file(conf_file)
    m = re.search(r'^LINUX_OPTIONS="([^"]*)"', text, re.MULTILINE)
    if m:
        new_value = (m.group(1) + " " + param).strip()
        text = text[:m.start(1)] + new_value + text[m.end(1):]
    else:
        text = text.rstrip("\n") + f'\nLINUX_OPTIONS="{param}"\n'
    conf_file.write_text(text)
    print(f"Added '{param}' to LINUX_OPTIONS in {conf_file}")


def ensure_mkinitcpio_file(conf_file: Path, file_to_add: str):
    text = conf_file.read_text()
    if file_to_add in text:
        print(f"'{file_to_add}' already referenced in {conf_file}, leaving it alone.")
        return
    backup_file(conf_file)
    m = re.search(r'^FILES=\(([^)]*)\)', text, re.MULTILINE)
    if m:
        current = m.group(1).strip()
        new_inner = (current + f' "{file_to_add}"').strip() if current else f'"{file_to_add}"'
        text = text[:m.start(1)] + new_inner + text[m.end(1):]
    else:
        text = text.rstrip("\n") + f'\nFILES=("{file_to_add}")\n'
    conf_file.write_text(text)
    print(f"Added {file_to_add} to FILES=() in {conf_file}")


def cmd_auto_fix(args):
    """Do the whole thing in one go, for a display already validated with
    `dump-i2c` + `info` + `patch`: re-read the live EDID over I2C, patch the
    HDR max-luminance field, install it under /usr/lib/firmware/edid/, and
    actually edit (with backups, idempotently) whichever bootloader config
    is present - GRUB or CachyOS's sdboot-manage - then rebuild.

    This is meant to be safe to re-run any time (e.g. after the TV or a GPU
    driver update resets something): it always re-reads the current live
    EDID rather than trusting an old saved file, and skips any step that's
    already been done.
    """
    require_root()
    print(f"== Auto-fixing HDR EDID for connector {args.connector} (I2C bus {args.bus}) ==\n")

    with tempfile.TemporaryDirectory(prefix="edid-autofix-") as tmp:
        raw_path = Path(tmp) / "raw.bin"
        fixed_path = Path(tmp) / "fixed.bin"

        # 1. dump fresh from the display over I2C
        fd = os.open(f"/dev/i2c-{args.bus}", os.O_RDWR)
        try:
            fcntl.ioctl(fd, I2C_SLAVE, args.addr)
            os.write(fd, bytes([0x00]))
            data = os.read(fd, args.length)
        finally:
            os.close(fd)
        if len(data) < args.length or data[0:8] != bytes([0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0x00]):
            die(f"EDID read from /dev/i2c-{args.bus} @ 0x{args.addr:02x} looks wrong "
                f"({len(data)} bytes, bad header). Is the TV on and this still the right bus? "
                f"Re-check with `ddcutil detect`.")
        raw_path.write_bytes(data)
        print(f"Read {len(data)} fresh bytes from /dev/i2c-{args.bus}.")

        # 2. patch
        edid = bytearray(data)
        hdr = find_hdr_block(bytes(edid))
        if not hdr or hdr["max_lum_off"] is None:
            die("No patchable HDR luminance field found in this EDID - "
                "is this really the same display we tested before?")
        old_nits = code_to_nits(edid[hdr["max_lum_off"]])
        new_code = nits_to_code(args.nits)
        edid[hdr["max_lum_off"]] = new_code
        fix_ext_checksum(edid, hdr["ext_index"])
        fixed_path.write_bytes(bytes(edid))
        print(f"Patched max luminance: {old_nits:.0f} nits -> {code_to_nits(new_code):.0f} nits")

        # 3. install the firmware file
        FIRMWARE_EDID_DIR.mkdir(parents=True, exist_ok=True)
        dest = FIRMWARE_EDID_DIR / args.name
        if dest.exists() and dest.read_bytes() == fixed_path.read_bytes():
            print(f"{dest} already up to date.")
        else:
            shutil.copy2(fixed_path, dest)
            print(f"Installed firmware file: {dest}")

    param = f"drm.edid_firmware={args.connector}:edid/{args.name}"
    need_rebuild = False

    # 4. bootloader config
    if Path("/etc/sdboot-manage.conf").exists():
        before = Path("/etc/sdboot-manage.conf").read_text()
        ensure_sdboot_param(Path("/etc/sdboot-manage.conf"), param)
        need_rebuild = need_rebuild or (param not in before)
        bootloader = "sdboot-manage"
    elif Path("/etc/default/grub").exists():
        before = Path("/etc/default/grub").read_text()
        ensure_grub_param(Path("/etc/default/grub"), param)
        need_rebuild = need_rebuild or (param not in before)
        bootloader = "grub"
    else:
        print(f"\nCould not find a known bootloader config - add this to your kernel "
              f"cmdline manually: {param}")
        bootloader = None

    # 5. mkinitcpio FILES=()
    mkinitcpio_conf = Path("/etc/mkinitcpio.conf")
    initramfs_changed = False
    if mkinitcpio_conf.exists():
        before = mkinitcpio_conf.read_text()
        ensure_mkinitcpio_file(mkinitcpio_conf, str(dest))
        initramfs_changed = str(dest) not in before

    if args.no_rebuild:
        print("\n--no-rebuild set - run these yourself, then reboot:")
        if bootloader == "sdboot-manage":
            print("  sudo sdboot-manage gen")
        elif bootloader == "grub":
            print("  sudo grub-mkconfig -o /boot/grub/grub.cfg")
        if initramfs_changed:
            print("  sudo mkinitcpio -P")
        return

    if bootloader == "sdboot-manage" and (need_rebuild or True):
        print("\nRunning: sudo sdboot-manage gen")
        subprocess.run(["sdboot-manage", "gen"], check=True)
    elif bootloader == "grub":
        print("\nRunning: sudo grub-mkconfig -o /boot/grub/grub.cfg")
        subprocess.run(["grub-mkconfig", "-o", "/boot/grub/grub.cfg"], check=True)

    if initramfs_changed:
        print("Running: sudo mkinitcpio -P")
        subprocess.run(["mkinitcpio", "-P"], check=True)

    print("\nDone. REBOOT for the corrected EDID to actually take effect.")
    print("After rebooting, `sudo python3 edid_hdr_tool.py info` should show ~%.0f nits "
          "if the kernel picked it up (still known to be unreliable on the proprietary "
          "NVIDIA driver - if it's still wrong, that's the driver ignoring it, not this script)."
          % args.nits)


def main():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = p.add_subparsers(dest="cmd", required=True)

    sp = sub.add_parser("status", help="Check lockdown/GPU driver/bootloader before you start.")
    sp.set_defaults(func=cmd_status)

    sp = sub.add_parser("dump-i2c", help="Read raw EDID bytes directly off the I2C/DDC bus "
                                          "(use when /sys/class/drm's edid file is empty, e.g. NVIDIA).")
    sp.add_argument("--bus", type=int, required=True, help="I2C bus number, e.g. 3 for /dev/i2c-3 (see `ddcutil detect`).")
    sp.add_argument("--addr", type=lambda x: int(x, 0), default=0x50, help="I2C slave address (default 0x50, standard for EDID).")
    sp.add_argument("--length", type=int, default=256, help="Bytes to read - 128 or 256 (default 256).")
    sp.add_argument("--out", required=True)
    sp.set_defaults(func=cmd_dump_i2c)

    sp = sub.add_parser("info", help="Decode the current HDR luminance metadata.")
    sp.add_argument("--connector", help="e.g. DP-1, HDMI-A-1. Auto-picked if only one display is connected.")
    sp.add_argument("--file", help="Decode an EDID .bin file instead of reading live from sysfs.")
    sp.set_defaults(func=cmd_info)

    sp = sub.add_parser("patch", help="Write a patched EDID with corrected max luminance.")
    sp.add_argument("--connector", help="Source connector to read the current EDID from.")
    sp.add_argument("--file", help="Read EDID from this file instead of a live connector.")
    sp.add_argument("--nits", type=float, required=True, help="Real peak brightness of your panel, e.g. 500.")
    sp.add_argument("--also-frame-avg", action="store_true",
                     help="Also set max frame-average luminance to the same value (usually fine).")
    sp.add_argument("--out", required=True, help="Where to write the patched EDID binary.")
    sp.set_defaults(func=cmd_patch)

    sp = sub.add_parser("test-apply", help="Apply a patched EDID live via debugfs (no reboot, doesn't persist).")
    sp.add_argument("--connector", required=True)
    sp.add_argument("--file", required=True)
    sp.set_defaults(func=cmd_test_apply)

    sp = sub.add_parser("revert", help="Clear a live debugfs override.")
    sp.add_argument("--connector", required=True)
    sp.set_defaults(func=cmd_revert)

    sp = sub.add_parser("install", help="Install a patched EDID persistently (kernel cmdline + firmware file).")
    sp.add_argument("--connector", required=True)
    sp.add_argument("--file", required=True)
    sp.add_argument("--name", help="Filename to use under /usr/lib/firmware/edid/ (default: <connector>-fixed.bin)")
    sp.set_defaults(func=cmd_install)

    sp = sub.add_parser("auto-fix", help="One-shot: dump-i2c + patch + install, actually editing "
                                          "GRUB/sdboot-manage + mkinitcpio and rebuilding. Re-runnable/idempotent.")
    sp.add_argument("--bus", type=int, required=True, help="I2C bus number (see `ddcutil detect`).")
    sp.add_argument("--addr", type=lambda x: int(x, 0), default=0x50)
    sp.add_argument("--length", type=int, default=256)
    sp.add_argument("--connector", required=True, help="e.g. HDMI-A-1")
    sp.add_argument("--nits", type=float, required=True, help="Real peak brightness of the panel, e.g. 500.")
    sp.add_argument("--name", default=None, help="Firmware filename (default: <connector>-fixed.bin)")
    sp.add_argument("--no-rebuild", action="store_true",
                     help="Write the config changes but don't actually run grub-mkconfig/sdboot-manage/mkinitcpio.")
    sp.set_defaults(func=cmd_auto_fix)

    args = p.parse_args()
    if getattr(args, "cmd", None) == "auto-fix" and args.name is None:
        args.name = f"{args.connector}-fixed.bin"
    args.func(args)


if __name__ == "__main__":
    main()
