/*
 * Primitive Live – Plasma-6-Widget zur Steuerung des Primitive-Live-Wallpapers.
 * Spricht ausschließlich mit ~/.local/bin/primitive-live-ctl.
 */
import QtQuick
import QtQuick.Layouts
import QtQuick.Controls as QQC2
import org.kde.plasma.plasmoid
import org.kde.plasma.core as PlasmaCore
import org.kde.plasma.components as PC3
import org.kde.plasma.extras as PlasmaExtras
import org.kde.plasma.plasma5support as P5Support
import org.kde.kirigami as Kirigami

PlasmoidItem {
    id: root

    property bool paused: false
    property int images: 0
    property var s: ({})          // Einstellungen als Strings aus der .conf
    property string error: ""
    property string info: ""
    property bool busy: false

    readonly property string ctl: "\"$HOME/.local/bin/primitive-live-ctl\""
    readonly property var shapes: [
        { label: "Dreiecke",        sym: "△", value: "dreiecke" },
        { label: "Rechtecke",       sym: "▭", value: "rechtecke" },
        { label: "Ellipsen",        sym: "◯", value: "ellipsen" },
        { label: "Gedr. Rechtecke", sym: "◇", value: "gedrehte-rechtecke" },
        { label: "Gedr. Ellipsen",  sym: "⬭", value: "gedrehte-ellipsen" }
    ]

    Plasmoid.icon: paused ? "media-playback-pause" : "draw-triangle"
    toolTipMainText: "Primitive Live"
    toolTipSubText: (paused ? "Pausiert" : "Malt") + " · " + images + " Bilder · Mittelklick: nächstes Bild"

    // aktuell gewählte Formen als Liste (aus "dreiecke,ellipsen" bzw. "alle"/"gemischt")
    readonly property var allShapes: shapes.map(x => x.value)
    readonly property var shapeSet: {
        const raw = (s.formen || "dreiecke").toLowerCase()
        if (raw === "alle" || raw === "gemischt") return allShapes
        const list = raw.split(/[ ,]+/).filter(v => allShapes.indexOf(v) >= 0)
        return list.length ? list : ["dreiecke"]
    }
    function writeShapes(list) {
        const ordered = allShapes.filter(v => list.indexOf(v) >= 0)
        const str = ordered.length === allShapes.length ? "alle" : ordered.join(",")
        s = Object.assign({}, s, { formen: str })     // sofort anzeigen
        setValue("formen", str)
    }
    function toggleShape(v) {
        const cur = shapeSet.slice()
        const i = cur.indexOf(v)
        if (i >= 0) { if (cur.length === 1) return; cur.splice(i, 1) }   // mindestens eine bleibt an
        else cur.push(v)
        writeShapes(cur)
    }

    function sq(v) { return "'" + String(v).replace(/'/g, "'\\''") + "'" }
    function num(key, def) { const n = parseInt(s[key]); return isNaN(n) ? def : n }
    function yes(key, def) { const v = (s[key] || "").toLowerCase(); return v === "" ? def : ["ja", "j", "yes", "true", "1", "an", "on"].indexOf(v) >= 0 }

    // ---------- Befehle ----------
    P5Support.DataSource {
        id: exe
        engine: "executable"
        connectedSources: []
        property var callbacks: ({})
        property int counter: 0
        onNewData: (source, data) => {
            const cb = callbacks[source]
            delete callbacks[source]
            disconnectSource(source)
            if (cb) cb(data["exit code"], (data.stdout || "").trim(), (data.stderr || "").trim())
        }
        function run(args, cb) {
            const src = root.ctl + " " + args + " #" + (++counter)
            callbacks[src] = cb
            connectSource(src)
        }
    }

    function call(args, cb) {
        exe.run(args, (code, out, err) => {
            if (code !== 0) root.error = err || "Fehler bei: " + args
            if (cb) cb(code, out, err)
            refresh()
        })
    }
    function setValue(key, value) { root.error = ""; call("set " + key + " " + sq(value)) }

    function refresh() {
        exe.run("status", (code, out) => {
            if (code !== 0) { root.error = "primitive-live-ctl nicht gefunden – install.sh ausführen"; return }
            try {
                const st = JSON.parse(out)
                root.paused = st.paused; root.images = st.images; root.s = st.settings
            } catch (e) { root.error = "Status unlesbar" }
        })
    }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: "Nächstes Bild"; icon.name: "media-skip-forward"
            onTriggered: root.call("next")
        },
        PlasmaCore.Action {
            text: root.paused ? "Weiter" : "Pause"
            icon.name: root.paused ? "media-playback-start" : "media-playback-pause"
            onTriggered: root.call("toggle")
        },
        PlasmaCore.Action {
            text: "Bilderordner öffnen"; icon.name: "folder-pictures"
            onTriggered: root.call("open")
        }
    ]

    Component.onCompleted: refresh()
    onExpandedChanged: if (expanded) refresh()
    Timer { interval: 4000; repeat: true; running: root.expanded; onTriggered: root.refresh() }

    // ---------- Panel-Icon ----------
    compactRepresentation: MouseArea {
        acceptedButtons: Qt.LeftButton | Qt.MiddleButton
        hoverEnabled: true
        onClicked: mouse => {
            if (mouse.button === Qt.MiddleButton) root.call(root.paused ? "toggle" : "next")
            else root.expanded = !root.expanded
        }
        onWheel: wheel => { if (wheel.angleDelta.y < 0) root.call("next") }
        Kirigami.Icon {
            anchors.fill: parent
            source: Plasmoid.icon
            active: parent.containsMouse
        }
    }

    // Slider mit Beschriftung, schreibt beim Loslassen
    component SettingSlider: RowLayout {
        id: row
        property string label
        property string key
        property real from: 0
        property real to: 100
        property real stepSize: 1
        property int fallback: 0
        property var format: v => String(v)
        Layout.fillWidth: true
        PC3.Label { text: row.label; Layout.preferredWidth: Kirigami.Units.gridUnit * 5.5; elide: Text.ElideRight }
        PC3.Slider {
            id: sl
            Layout.fillWidth: true
            from: row.from; to: row.to; stepSize: row.stepSize
            value: root.num(row.key, row.fallback)
            onPressedChanged: if (!pressed) root.setValue(row.key, Math.round(value))
        }
        PC3.Label {
            text: row.format(Math.round(sl.value))
            Layout.preferredWidth: Kirigami.Units.gridUnit * 3.5
            horizontalAlignment: Text.AlignRight
        }
    }

    // ---------- Popup ----------
    fullRepresentation: PlasmaExtras.Representation {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 22
        Layout.preferredHeight: Kirigami.Units.gridUnit * 30
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 20

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                Kirigami.Icon { source: "draw-triangle"; Layout.preferredWidth: Kirigami.Units.iconSizes.medium; Layout.preferredHeight: Layout.preferredWidth }
                ColumnLayout {
                    spacing: 0
                    Layout.fillWidth: true
                    PlasmaExtras.Heading { level: 3; text: "Primitive Live" }
                    PC3.Label {
                        Layout.fillWidth: true
                        opacity: 0.7
                        font: Kirigami.Theme.smallFont
                        elide: Text.ElideRight
                        text: (root.paused ? "⏸ pausiert" : "✎ malt") + " · " + root.images + (root.images === 1 ? " Bild" : " Bilder")
                    }
                }
            }
        }

        PC3.ScrollView {
            id: scroll
            anchors.fill: parent
            contentWidth: availableWidth

            ColumnLayout {
                width: scroll.availableWidth
                spacing: Kirigami.Units.smallSpacing

                // --- Steuerung ---
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    PC3.ToolButton {
                        icon.name: "view-refresh"; display: PC3.AbstractButton.IconOnly
                        text: "Aktuelles Bild neu malen"
                        QQC2.ToolTip.text: text; QQC2.ToolTip.visible: hovered
                        onClicked: root.call("again")
                    }
                    PC3.Button {
                        icon.name: root.paused ? "media-playback-start" : "media-playback-pause"
                        text: root.paused ? "Weiter" : "Pause"
                        onClicked: root.call("toggle")
                    }
                    PC3.ToolButton {
                        icon.name: "media-seek-forward"; display: PC3.AbstractButton.IconOnly
                        text: "Sofort fertig malen"
                        QQC2.ToolTip.text: text; QQC2.ToolTip.visible: hovered
                        onClicked: root.call("finish")
                    }
                    PC3.Button {
                        icon.name: "media-skip-forward"; text: "Nächstes"
                        onClicked: root.call("next")
                    }
                }

                // --- Formen ---
                Kirigami.Heading { level: 4; text: "Formen"; Layout.topMargin: Kirigami.Units.largeSpacing }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: Kirigami.Units.smallSpacing
                    rowSpacing: Kirigami.Units.smallSpacing
                    Repeater {
                        model: root.shapes
                        PC3.Button {
                            Layout.fillWidth: true
                            Layout.preferredWidth: 1     // gleich breite Spalten
                            // nicht "checkable": der Zustand kommt immer aus root.shapeSet
                            checked: root.shapeSet.indexOf(modelData.value) >= 0
                            text: modelData.sym + "  " + modelData.label
                            onClicked: root.toggleShape(modelData.value)
                        }
                    }
                    PC3.Button {
                        Layout.fillWidth: true
                        Layout.preferredWidth: 1
                        readonly property bool all: root.shapeSet.length === root.allShapes.length
                        checked: all
                        text: "✦  Alle"
                        QQC2.ToolTip.text: all ? "Nur noch Dreiecke" : "Alle Formen mischen"
                        QQC2.ToolTip.visible: hovered
                        onClicked: root.writeShapes(all ? ["dreiecke"] : root.allShapes)
                    }
                }
                PC3.Label {
                    Layout.fillWidth: true
                    opacity: 0.6
                    font: Kirigami.Theme.smallFont
                    wrapMode: Text.Wrap
                    text: root.shapeSet.length > 1 ? "Mischung aus " + root.shapeSet.length + " Formen – Klick schaltet einzeln an/aus"
                                                   : "Klick auf weitere Formen, um sie dazuzumischen"
                }

                // --- Werte ---
                Kirigami.Heading { level: 4; text: "Malen"; Layout.topMargin: Kirigami.Units.largeSpacing }
                SettingSlider { label: "Deckkraft"; key: "deckkraft"; from: 16; to: 255; fallback: 128; format: v => Math.round(v / 2.55) + " %" }
                SettingSlider { label: "Formen/Bild"; key: "anzahl"; from: 50; to: 5000; stepSize: 50; fallback: 600 }
                SettingSlider { label: "Tempo"; key: "tempo"; from: 0; to: 60; fallback: 8; format: v => v === 0 ? "max" : v + "/s" }
                SettingSlider { label: "Standzeit"; key: "standzeit"; from: 0; to: 300; stepSize: 5; fallback: 20; format: v => v + " s" }

                Kirigami.Heading { level: 4; text: "Leistung"; Layout.topMargin: Kirigami.Units.largeSpacing }
                SettingSlider { label: "Genauigkeit"; key: "aufloesung"; from: 80; to: 400; stepSize: 10; fallback: 200; format: v => v + " px" }
                SettingSlider { label: "CPU/Frame"; key: "cpu"; from: 2; to: 25; fallback: 10; format: v => v + " ms" }

                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing
                    PC3.CheckBox {
                        text: "Zufällige Reihenfolge"
                        checked: root.yes("zufall", true)
                        onToggled: root.setValue("zufall", checked ? "ja" : "nein")
                    }
                    PC3.CheckBox {
                        text: "Überlagern"
                        checked: root.yes("ueberlagern", false)
                        onToggled: root.setValue("ueberlagern", checked ? "ja" : "nein")
                        QQC2.ToolTip.text: "Das nächste Bild wird über das aktuelle gemalt – es verwandelt sich Form für Form"
                        QQC2.ToolTip.visible: hovered
                    }
                    PC3.CheckBox {
                        text: "Fortschritt anzeigen"
                        checked: root.yes("fortschritt", false)
                        onToggled: root.setValue("fortschritt", checked ? "ja" : "nein")
                    }
                }

                PC3.Label {
                    Layout.fillWidth: true
                    visible: root.error || root.info
                    wrapMode: Text.Wrap
                    font: Kirigami.Theme.smallFont
                    color: root.error ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.positiveTextColor
                    text: root.error || root.info
                }

                // --- Bilder ---
                Kirigami.Heading { level: 4; text: "Bilder"; Layout.topMargin: Kirigami.Units.largeSpacing }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                    PC3.Button {
                        icon.name: "folder-pictures"; text: "Ordner"
                        onClicked: { root.call("open"); root.expanded = false }
                    }
                    PC3.Button {
                        icon.name: "view-refresh"; text: "Neu einlesen"
                        enabled: !root.busy
                        onClicked: {
                            root.busy = true; root.error = ""; root.info = ""
                            root.call("sync", (code, out) => { root.busy = false; if (code === 0) root.info = out })
                        }
                    }
                    Item { Layout.fillWidth: true }
                    PC3.ToolButton {
                        icon.name: "edit-undo"; display: PC3.AbstractButton.IconOnly
                        text: "Standardwerte"
                        QQC2.ToolTip.text: text; QQC2.ToolTip.visible: hovered
                        onClicked: root.call("reset")
                    }
                }
            }
        }
    }
}
