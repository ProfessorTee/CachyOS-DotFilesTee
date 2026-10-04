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
    property var files: []           // eingebettete Bilder (Pfade) für die Vorschau
    property string current: ""      // zuletzt angeklicktes Bild
    property bool more: false        // "Mehr"-Bereich offen

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

    function loadFiles() {
        exe.run("list", (code, out) => { if (code === 0) root.files = out.split("\n").filter(l => l.length) })
    }

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

    Component.onCompleted: { refresh(); loadFiles() }
    onExpandedChanged: if (expanded) { refresh(); loadFiles() }
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

    // kompakter Regler: kleine Beschriftung, Wert rechts, schreibt beim Loslassen
    component MiniSlider: RowLayout {
        id: row
        property string label
        property string key
        property real from: 0
        property real to: 100
        property real stepSize: 1
        property int fallback: 0
        property var format: v => String(v)
        Layout.fillWidth: true
        spacing: Kirigami.Units.smallSpacing
        PC3.Label { text: row.label; font: Kirigami.Theme.smallFont; opacity: 0.75; Layout.preferredWidth: Kirigami.Units.gridUnit * 4 }
        PC3.Slider {
            id: sl
            Layout.fillWidth: true
            from: row.from; to: row.to; stepSize: row.stepSize
            value: root.num(row.key, row.fallback)
            onPressedChanged: if (!pressed) root.setValue(row.key, Math.round(value))
        }
        PC3.Label {
            text: row.format(Math.round(sl.value))
            font: Kirigami.Theme.smallFont
            Layout.preferredWidth: Kirigami.Units.gridUnit * 2.6
            horizontalAlignment: Text.AlignRight
        }
    }
    component IconBtn: PC3.ToolButton {
        display: PC3.AbstractButton.IconOnly
        QQC2.ToolTip.text: text
        QQC2.ToolTip.visible: hovered
        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
    }

    // ---------- Popup (kompakt) ----------
    fullRepresentation: PlasmaExtras.Representation {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 17
        Layout.preferredHeight: col.implicitHeight + Kirigami.Units.largeSpacing * 2
        Layout.minimumWidth: Kirigami.Units.gridUnit * 14
        Layout.maximumHeight: Kirigami.Units.gridUnit * 34

        ColumnLayout {
            id: col
            anchors.fill: parent
            spacing: Kirigami.Units.smallSpacing

            // Zeile 1: Status + Steuerung
            RowLayout {
                Layout.fillWidth: true
                spacing: 0
                PC3.Label {
                    Layout.fillWidth: true
                    elide: Text.ElideRight
                    font: Kirigami.Theme.smallFont
                    opacity: 0.75
                    text: (root.paused ? "⏸ " : "✎ ") + root.images + " Bilder"
                }
                IconBtn { icon.name: "view-refresh"; text: "Aktuelles Bild neu malen"; onClicked: root.call("again") }
                IconBtn {
                    icon.name: root.paused ? "media-playback-start" : "media-playback-pause"
                    text: root.paused ? "Weiter" : "Pause"
                    onClicked: root.call("toggle")
                }
                IconBtn { icon.name: "media-seek-forward"; text: "Sofort fertig malen"; onClicked: root.call("finish") }
                IconBtn { icon.name: "media-skip-forward"; text: "Nächstes Bild"; onClicked: root.call("next") }
                IconBtn {
                    icon.name: root.more ? "arrow-up" : "configure"
                    text: root.more ? "Weniger" : "Mehr Einstellungen"
                    checkable: true; checked: root.more
                    onToggled: root.more = checked
                }
            }

            // Zeile 2: Formen als Symbol-Schalter
            RowLayout {
                Layout.fillWidth: true
                spacing: 2
                Repeater {
                    model: root.shapes
                    PC3.ToolButton {
                        Layout.fillWidth: true
                        text: modelData.sym
                        font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.2
                        checked: root.shapeSet.indexOf(modelData.value) >= 0
                        onClicked: root.toggleShape(modelData.value)
                        QQC2.ToolTip.text: modelData.label + (checked ? " (an)" : " (aus)")
                        QQC2.ToolTip.visible: hovered
                        QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                    }
                }
                PC3.ToolButton {
                    Layout.fillWidth: true
                    readonly property bool all: root.shapeSet.length === root.allShapes.length
                    text: "✦"
                    font.pointSize: Kirigami.Theme.defaultFont.pointSize * 1.2
                    checked: all
                    onClicked: root.writeShapes(all ? ["dreiecke"] : root.allShapes)
                    QQC2.ToolTip.text: all ? "Nur noch Dreiecke" : "Alle Formen mischen"
                    QQC2.ToolTip.visible: hovered
                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
            }

            // Zeile 3: die wichtigsten Regler
            MiniSlider { label: "Deckkraft"; key: "deckkraft"; from: 16; to: 255; fallback: 128; format: v => Math.round(v / 2.55) + "%" }
            MiniSlider { label: "Formen"; key: "anzahl"; from: 50; to: 5000; stepSize: 50; fallback: 600 }
            MiniSlider { label: "Tempo"; key: "tempo"; from: 0; to: 60; fallback: 8; format: v => v === 0 ? "max" : v + "/s" }

            // "Mehr": seltener gebrauchte Einstellungen
            ColumnLayout {
                visible: root.more
                Layout.fillWidth: true
                spacing: Kirigami.Units.smallSpacing
                MiniSlider { label: "Standzeit"; key: "standzeit"; from: 0; to: 300; stepSize: 5; fallback: 20; format: v => v + "s" }
                MiniSlider { label: "Genauigkeit"; key: "aufloesung"; from: 80; to: 400; stepSize: 10; fallback: 200 }
                MiniSlider { label: "CPU/Frame"; key: "cpu"; from: 2; to: 25; fallback: 10; format: v => v + "ms" }
                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.smallSpacing
                    PC3.CheckBox { text: "Zufall"; font: Kirigami.Theme.smallFont; checked: root.yes("zufall", true); onToggled: root.setValue("zufall", checked ? "ja" : "nein") }
                    PC3.CheckBox {
                        text: "Überlagern"; font: Kirigami.Theme.smallFont
                        checked: root.yes("ueberlagern", false); onToggled: root.setValue("ueberlagern", checked ? "ja" : "nein")
                        QQC2.ToolTip.text: "Nächstes Bild über das aktuelle malen"; QQC2.ToolTip.visible: hovered
                    }
                    PC3.CheckBox {
                        text: "Ganzes Bild"; font: Kirigami.Theme.smallFont
                        checked: (root.s.anpassung || "passend") !== "fuellen"
                        onToggled: root.setValue("anpassung", checked ? "passend" : "fuellen")
                        QQC2.ToolTip.text: "An: ganzes Bild zeigen (Rand weich gefüllt) · Aus: Bildschirm füllen (beschneiden)"; QQC2.ToolTip.visible: hovered
                    }
                    PC3.CheckBox { text: "Fortschritt"; font: Kirigami.Theme.smallFont; checked: root.yes("fortschritt", false); onToggled: root.setValue("fortschritt", checked ? "ja" : "nein") }
                }
                RowLayout {
                    Layout.fillWidth: true
                    spacing: 0
                    IconBtn { icon.name: "folder-pictures"; text: "Bilderordner öffnen"; onClicked: { root.call("open"); root.expanded = false } }
                    IconBtn {
                        icon.name: "view-refresh"; text: "Bilder neu einlesen"; enabled: !root.busy
                        onClicked: { root.busy = true; root.call("sync", (code, out) => { root.busy = false; root.info = out; root.loadFiles() }) }
                    }
                    IconBtn { icon.name: "document-edit"; text: "Einstellungsdatei bearbeiten"; onClicked: { root.call("edit"); root.expanded = false } }
                    Item { Layout.fillWidth: true }
                    IconBtn { icon.name: "edit-undo"; text: "Standardwerte"; onClicked: root.call("reset") }
                }
            }

            PC3.Label {
                Layout.fillWidth: true
                visible: text.length > 0
                wrapMode: Text.Wrap
                font: Kirigami.Theme.smallFont
                color: root.error ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.positiveTextColor
                text: root.error || root.info
            }

            Kirigami.Separator { Layout.fillWidth: true }

            // Vorschau der Bilder – Klick malt genau dieses Bild
            GridView {
                id: grid
                Layout.fillWidth: true
                Layout.preferredHeight: Math.min(Math.ceil(count / Math.max(1, Math.floor(width / cellWidth))) * cellHeight,
                                                 cellHeight * 3)
                clip: true
                readonly property int cols: Math.max(3, Math.floor(width / (Kirigami.Units.gridUnit * 3.6)))
                cellWidth: Math.floor(width / cols)
                cellHeight: cellWidth
                model: root.files
                QQC2.ScrollBar.vertical: PC3.ScrollBar {}
                delegate: Item {
                    width: grid.cellWidth; height: grid.cellHeight
                    Rectangle {
                        anchors.fill: parent
                        anchors.margins: 2
                        radius: Kirigami.Units.smallSpacing
                        color: "transparent"
                        border.width: root.current === modelData ? 2 : (ma.containsMouse ? 1 : 0)
                        border.color: Kirigami.Theme.highlightColor
                        Image {
                            anchors.fill: parent
                            anchors.margins: 2
                            source: "file://" + modelData
                            sourceSize.width: 160; sourceSize.height: 160
                            fillMode: Image.PreserveAspectCrop
                            asynchronous: true
                            cache: true
                            smooth: true
                        }
                    }
                    MouseArea {
                        id: ma
                        anchors.fill: parent
                        hoverEnabled: true
                        onClicked: { root.current = modelData; root.call("show " + root.sq(modelData)) }
                    }
                    QQC2.ToolTip.text: modelData.split("/").pop()
                    QQC2.ToolTip.visible: ma.containsMouse
                    QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                }
                PC3.Label {
                    anchors.centerIn: parent
                    visible: grid.count === 0
                    font: Kirigami.Theme.smallFont
                    opacity: 0.6
                    text: "Keine Bilder in ~/Bilder/Primitive"
                }
            }
        }
    }
}
