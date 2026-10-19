#!/bin/sh
# Re-enable disabled Quest packages. Uninstalled apps: reinstall from Meta Store
# (or `adb shell cmd package install-existing <pkg>` if the APK is still on the device).
: "${ANDROID_SERIAL:=340YC10G9T0T3L}"; export ANDROID_SERIAL
cd "$(dirname "$0")"
for p in $(cat disable.txt); do adb shell pm enable "$p"; done
for p in $(cat uninstall.txt); do adb shell cmd package install-existing "$p"; done
