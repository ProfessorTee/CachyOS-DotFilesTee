# Philips 55PUS8909 – Debloat + Apple-TV-Launcher

Stand: 2026-10-19. Gemacht mit [cleanyourtv](https://github.com/Gathin23/cleanyourtv)
(lokal geklont nach `~/Projekte/cleanyourtv`).

- TV: Philips 55PUS8909 Ambilight, Android TV 11, Plattform `PH1M_EA_9970A`, Hersteller TPV
- ADB über LAN: `192.168.178.31:5555`. Am TV reicht „USB-Debugging“ in den Entwickleroptionen.
- Achtung: Die Quest 3S hängt manchmal auch an adb. Darum immer `export ANDROID_SERIAL=192.168.178.31:5555` setzen.

## Dateien

| Datei | Zweck |
|---|---|
| `debloat.txt` | Liste der deaktivierten Pakete (`pm disable-user`, nichts deinstalliert) |
| `restore.sh` | Aktiviert alles wieder und setzt den Google-Launcher als Home |
| `config.xml` | Launcher-Konfiguration (Dock: Netflix, YouTube, Prime, Disney+) |

## Wiederherstellen / Neu aufsetzen

```bash
export ANDROID_SERIAL=192.168.178.31:5555
adb connect $ANDROID_SERIAL            # am TV „Immer zulassen“ bestätigen

# Einzelne App zurückholen
adb shell pm enable --user 0 <paket>

# Alles rückgängig
./restore.sh

# Debloat erneut anwenden (z. B. nach Werksreset)
for p in $(grep -vE '^\s*(#|$)' debloat.txt | awk '{print $1}'); do adb shell pm disable-user --user 0 $p; done

# Launcher neu bauen + installieren
git clone https://github.com/Gathin23/cleanyourtv ~/Projekte/cleanyourtv
cp config.xml ~/Projekte/cleanyourtv/launcher/app/src/main/res/values/config.xml
cd ~/Projekte/cleanyourtv/launcher
echo "sdk.dir=$HOME/Android/Sdk" > local.properties    # SDK: cmdline-tools + platforms;android-34 + build-tools;34.0.0
./gradlew assembleRelease
adb install -r app/build/outputs/apk/release/app-release.apk
adb shell pm disable-user --user 0 com.google.android.tvlauncher
adb shell cmd package set-home-activity --user 0 com.gathin.tvhome/.MainActivity
```

## Stolperfallen

- **`org.droidtv.eum` NICHT deaktivieren.** Das Quellen-Menü der Source-Taste (`org.droidtv.channels`)
  bindet seinen Service. Ohne ihn öffnet sich ein leeres Panel und schließt sich sofort wieder.
- Screenshots: `adb exec-out screencap` liefert leere Dateien. So geht es:
  `adb shell screencap -p /sdcard/s.png && adb pull /sdcard/s.png`.
- Am USB-Port des TVs hängt ein Lüfter. Manche TVs schalten bei aktivem USB-Debugging den Port-Strom ab.
