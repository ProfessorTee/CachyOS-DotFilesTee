#!/usr/bin/env bash
# Reagiert auf KDE/PPD-Profilwechsel und setzt CPU + GPU passend

# Boost NICHT mehr anfassen: power-profiles-daemon verwaltet den Boost pro Kern selbst.
# Ein globales boost=0 blockiert dessen Profilwechsel. Einmalig wieder einschalten:
[ -w /sys/devices/system/cpu/cpufreq/boost ] && echo 1 > /sys/devices/system/cpu/cpufreq/boost

set_cpu_max() {  # $1 = kHz
  for p in /sys/devices/system/cpu/cpufreq/policy*; do echo "$1" > "$p/scaling_max_freq"; done
}

C=/sys/devices/system/cpu/cpu0/cpufreq
CPU_MIN=$(cat $C/cpuinfo_min_freq)                          # niedrigster Takt (~0,6 GHz)
CPU_MAX=$(cat $C/amd_pstate_max_freq 2>/dev/null || cat $C/cpuinfo_max_freq)  # voller Boost (~5,45 GHz)
# Ausgeglichen = Werkstakt des 9800X3D (5,2 GHz Boost) statt OC (BCLK 102,5 + PBO +200).
# Der Kernel rechnet mit 100 MHz Referenztakt, real liegt alles 2,5 % höher → Grenze durch BCLK teilen.
CPU_STOCK=5200000                                           # kHz, Werks-Boost
BCLK=1025                                                   # BCLK in 1/10 MHz (102,5 MHz)

GPU_DEF=$(nvidia-smi --query-gpu=power.default_limit --format=csv,noheader,nounits | head -1)
GPU_DEF=${GPU_DEF%.*}
GPU_MIN=$(nvidia-smi --query-gpu=power.min_limit --format=csv,noheader,nounits | head -1)
GPU_MIN=${GPU_MIN%.*}
GPU_BAL_PCT=75                                              # Ausgeglichen: Power-Limit in % vom Standard

apply() {
  profile=$(powerprofilesctl get)
  [ "$profile" = "$LAST" ] && return   # doppelte Meldung ignorieren
  LAST=$profile
  echo "Profil: $profile"
  case "$profile" in
    power-saver)                   # alles auf niedrigstem Takt
      set_cpu_max "$CPU_MIN"
      nvidia-smi -pl "$GPU_MIN"
      nvidia-smi -lgc 210,210      # GPU-Takt auf Minimum
      nvidia-smi -lmc 405,405      # VRAM-Takt auf Minimum, sonst bleibt die Karte in P0 (~95 W statt ~20 W)
      ;;
    balanced)                      # CPU auf Werksniveau, GPU bis 75 %, Takte adaptiv
      set_cpu_max $(( CPU_STOCK * 1000 / BCLK ))
      nvidia-smi -pl $(( GPU_DEF * GPU_BAL_PCT / 100 ))
      nvidia-smi -rgc
      nvidia-smi -rmc
      ;;
    performance)                   # alles bis 100 % erlaubt, nichts erzwungen
      set_cpu_max "$CPU_MAX"
      nvidia-smi -pl "$GPU_DEF"
      nvidia-smi -rgc
      nvidia-smi -rmc
      ;;
  esac
}

nvidia-smi -pm 1 >/dev/null       # Persistence-Mode, damit Einstellungen halten
apply

gdbus monitor --system --dest org.freedesktop.UPower.PowerProfiles |
while read -r line; do
  [[ $line == *ActiveProfile* ]] && { sleep 0.5; apply; }
done
