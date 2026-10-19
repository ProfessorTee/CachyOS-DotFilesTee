#!/usr/bin/env bash
# Re-enable everything from the Philips debloat list and the stock launcher.
# Usage: ./restore-philips.sh            (all)   |   adb -s 192.168.178.31:5555 shell pm enable <pkg>   (single app)
export ANDROID_SERIAL=${ANDROID_SERIAL:-192.168.178.31:5555}
cd "$(dirname "$0")"
adb connect "$ANDROID_SERIAL" >/dev/null
for p in $(grep -vE '^\s*(#|$)' debloat.txt | awk '{print $1}') com.google.android.tvlauncher; do
  adb shell pm enable --user 0 "$p"
done
adb shell cmd package set-home-activity --user 0 com.google.android.tvlauncher/.MainActivity
