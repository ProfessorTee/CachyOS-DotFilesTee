#!/bin/sh
# Undo RAM trim on OnePlus 8 Pro
: "${ANDROID_SERIAL:=192.168.178.58:5555}"; export ANDROID_SERIAL
cd "$(dirname "$0")"
for p in $(cat disable.txt); do adb shell pm enable "$p"; done
adb shell 'wm size reset; wm density reset; settings put global window_animation_scale 1; settings put global transition_animation_scale 1; settings put global animator_duration_scale 1; device_config delete activity_manager max_cached_processes; cmd location set-location-enabled true'
