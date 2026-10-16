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

# GPU: LACT-Profile Eco / Balanced / Performance (Takt, Undervolt, Power-Limit in /etc/lact/config.yaml).
# Nicht mit nvidia-smi dazwischenfunken, -rgc würde das Taktlimit des Undervolts aufheben.

apply() {
  profile=$(powerprofilesctl get)
  [ "$profile" = "$LAST" ] && return   # doppelte Meldung ignorieren
  LAST=$profile
  echo "Profil: $profile"
  case "$profile" in
    power-saver)                   # alles auf niedrigstem Takt
      set_cpu_max "$CPU_MIN"
      lact cli profile set Eco     # GPU 210 / VRAM 405 MHz fest, 100 W
      ;;
    balanced)                      # CPU auf Werksniveau, GPU Undervolt bis 262 W (75 %), Takte adaptiv
      set_cpu_max $(( CPU_STOCK * 1000 / BCLK ))
      lact cli profile set Balanced
      ;;
    performance)                   # CPU voller Boost, GPU Undervolt bis 400 W
      set_cpu_max "$CPU_MAX"
      lact cli profile set Performance
      ;;
  esac
}

nvidia-smi -pm 1 >/dev/null       # Persistence-Mode, damit Einstellungen halten
apply

gdbus monitor --system --dest org.freedesktop.UPower.PowerProfiles |
while read -r line; do
  [[ $line == *ActiveProfile* ]] && { sleep 0.5; apply; }
done
