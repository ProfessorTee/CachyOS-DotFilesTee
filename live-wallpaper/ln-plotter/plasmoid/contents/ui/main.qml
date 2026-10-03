/*
 * LN Plotter – Plasma-6-Widget zur Steuerung des LN Plotter Wallpapers.
 * Spricht ausschließlich mit ~/.local/bin/ln-plotter-ctl.
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

    // ---------- Zustand ----------
    property bool paused: false
    property bool timerOn: true
    property bool vpype: true
    property int drawings: 0
    property string lastFormula: ""
    property var settings: ({})
    property var formulas: []
    property bool busy: false
    property string error: ""
    property string info: ""

    readonly property string ctl: "\"$HOME/.local/bin/ln-plotter-ctl\""
    readonly property var styles: [
        { text: "Zufall", value: "" }, { text: "Gitter", value: "grid" },
        { text: "Linien X", value: "x" }, { text: "Linien Y", value: "y" },
        { text: "Diagonal", value: "diag" }, { text: "Strahlen", value: "radial" },
        { text: "Ringe", value: "rings" }, { text: "Spirale", value: "spiral" },
        { text: "Höhenlinien", value: "contour" }
    ]
    readonly property var themes: [
        { text: "Wie im Wallpaper", value: "" }, { text: "Papier", value: "papier" },
        { text: "Nacht", value: "nacht" }, { text: "Blaupause", value: "blaupause" },
        { text: "Terminal", value: "terminal" }, { text: "Sonnenuntergang", value: "sonnenuntergang" },
        { text: "Aquarell", value: "aquarell" }
    ]

    Plasmoid.icon: paused ? "media-playback-pause" : "draw-freehand"
    toolTipMainText: "LN Plotter"
    toolTipSubText: paused ? "Pausiert – Mittelklick: weiter" : "Zeichnet – Mittelklick: nächste Zeichnung"

    function sq(s) { return "'" + String(s).replace(/'/g, "'\\''") + "'" }

    // ---------- Befehle ausführen ----------
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
            if (code !== 0 && err) root.error = err
            if (cb) cb(code, out, err)
            if (!args.startsWith("status")) refresh()
        })
    }

    function refresh() {
        exe.run("status", (code, out) => {
            if (code !== 0) { root.error = "ln-plotter-ctl nicht gefunden – install.sh ausführen"; return }
            try {
                const s = JSON.parse(out)
                root.paused = s.paused; root.timerOn = s.timer; root.vpype = s.vpype
                root.drawings = s.drawings; root.lastFormula = s.last; root.settings = s.settings
            } catch (e) { root.error = "Status unlesbar: " + out }
        })
    }

    function loadFormulas() {
        exe.run("formulas", (code, out) => { if (code === 0) root.formulas = out.split("\n").filter(l => l.length) })
    }

    function draw(formula, style) {
        if (!formula.trim()) return
        root.busy = true; root.error = ""; root.info = ""
        exe.run("draw " + sq(formula) + (style ? " " + sq(style) : ""), (code, out, err) => {
            root.busy = false
            if (code === 0) root.info = "Wird gezeichnet ✓"
            else root.error = err || "Fehler beim Rendern"
            refresh()
        })
    }

    function setValue(key, value) { call("set " + key + (value === "" || value === null || value === undefined ? "" : " " + sq(value))) }

    Plasmoid.contextualActions: [
        PlasmaCore.Action {
            text: "Nächste Zeichnung"; icon.name: "media-skip-forward"
            onTriggered: root.call("next")
        },
        PlasmaCore.Action {
            text: root.paused ? "Weiter" : "Pause"
            icon.name: root.paused ? "media-playback-start" : "media-playback-pause"
            onTriggered: root.call("toggle")
        },
        PlasmaCore.Action {
            text: "Neue Zeichnungen erzeugen"; icon.name: "view-refresh"
            onTriggered: root.call("generate 3")
        }
    ]

    Component.onCompleted: { refresh(); loadFormulas() }
    onExpandedChanged: if (expanded) { refresh(); loadFormulas() }
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

    // ---------- Popup ----------
    fullRepresentation: PlasmaExtras.Representation {
        Layout.preferredWidth: Kirigami.Units.gridUnit * 24
        Layout.preferredHeight: Kirigami.Units.gridUnit * 34
        Layout.minimumWidth: Kirigami.Units.gridUnit * 18
        Layout.minimumHeight: Kirigami.Units.gridUnit * 22

        header: PlasmaExtras.PlasmoidHeading {
            RowLayout {
                anchors.fill: parent
                Kirigami.Icon { source: "draw-freehand"; Layout.preferredWidth: Kirigami.Units.iconSizes.medium; Layout.preferredHeight: Layout.preferredWidth }
                ColumnLayout {
                    spacing: 0
                    Layout.fillWidth: true
                    PlasmaExtras.Heading { level: 3; text: "LN Plotter" }
                    PC3.Label {
                        Layout.fillWidth: true
                        opacity: 0.7
                        font: Kirigami.Theme.smallFont
                        elide: Text.ElideRight
                        text: (root.paused ? "⏸ pausiert" : "✎ zeichnet") + " · " + root.drawings + " Zeichnungen"
                              + (root.vpype ? " · vpype ✓" : " · ohne vpype")
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

                // --- Transport ---
                RowLayout {
                    Layout.alignment: Qt.AlignHCenter
                    Layout.topMargin: Kirigami.Units.smallSpacing
                    spacing: Kirigami.Units.smallSpacing
                    PC3.ToolButton {
                        icon.name: "media-skip-backward"; display: PC3.AbstractButton.IconOnly
                        text: "Von vorn"; QQC2.ToolTip.text: text; QQC2.ToolTip.visible: hovered
                        onClicked: root.call("restart")
                    }
                    PC3.Button {
                        icon.name: root.paused ? "media-playback-start" : "media-playback-pause"
                        text: root.paused ? "Weiter" : "Pause"
                        onClicked: root.call("toggle")
                    }
                    PC3.ToolButton {
                        icon.name: "media-seek-forward"; display: PC3.AbstractButton.IconOnly
                        text: "Sofort fertig zeichnen"; QQC2.ToolTip.text: text; QQC2.ToolTip.visible: hovered
                        onClicked: root.call("finish")
                    }
                    PC3.Button {
                        icon.name: "media-skip-forward"; text: "Nächste"
                        onClicked: root.call("next")
                    }
                }

                // --- Formel ---
                Kirigami.Heading { level: 4; text: "Formel zeichnen"; Layout.topMargin: Kirigami.Units.largeSpacing }
                RowLayout {
                    Layout.fillWidth: true
                    PC3.Label { text: "z ="; font.family: "monospace" }
                    PC3.TextField {
                        id: formulaField
                        Layout.fillWidth: true
                        font.family: "monospace"
                        placeholderText: "sin(a*3*r - phi*b) / (1 + r)"
                        text: root.lastFormula
                        onAccepted: root.draw(text, styleBox.currentValue)
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    PC3.ComboBox {
                        id: styleBox
                        Layout.fillWidth: true
                        model: root.styles
                        textRole: "text"; valueRole: "value"
                    }
                    PC3.Button {
                        icon.name: "list-add"; display: PC3.AbstractButton.IconOnly
                        text: "Zu formeln.txt hinzufügen"; QQC2.ToolTip.text: text; QQC2.ToolTip.visible: hovered
                        enabled: formulaField.text.trim().length > 0
                        onClicked: root.call("add " + root.sq(formulaField.text), (code) => {
                            if (code === 0) { root.info = "Gespeichert ✓"; root.loadFormulas() }
                        })
                    }
                    PC3.Button {
                        icon.name: "draw-freehand"; text: "Zeichnen"
                        enabled: !root.busy && formulaField.text.trim().length > 0
                        onClicked: root.draw(formulaField.text, styleBox.currentValue)
                    }
                }
                RowLayout {
                    Layout.fillWidth: true
                    visible: root.busy || root.error || root.info
                    PC3.BusyIndicator { visible: root.busy; running: visible; Layout.preferredHeight: Kirigami.Units.iconSizes.small; Layout.preferredWidth: Layout.preferredHeight }
                    PC3.Label {
                        Layout.fillWidth: true
                        wrapMode: Text.Wrap
                        font: Kirigami.Theme.smallFont
                        color: root.error ? Kirigami.Theme.negativeTextColor : Kirigami.Theme.positiveTextColor
                        text: root.busy ? "Rendere …" : (root.error || root.info)
                    }
                }

                // Formel-Liste
                Rectangle {
                    Layout.fillWidth: true
                    Layout.preferredHeight: Kirigami.Units.gridUnit * 8
                    color: "transparent"
                    border.color: Qt.rgba(Kirigami.Theme.textColor.r, Kirigami.Theme.textColor.g, Kirigami.Theme.textColor.b, 0.15)
                    radius: Kirigami.Units.smallSpacing
                    ListView {
                        id: list
                        anchors.fill: parent
                        anchors.margins: 1
                        clip: true
                        model: root.formulas
                        PC3.ScrollBar.vertical: PC3.ScrollBar {}
                        delegate: PC3.ItemDelegate {
                            width: ListView.view.width
                            text: modelData
                            font.family: "monospace"
                            font.pointSize: Kirigami.Theme.smallFont.pointSize
                            QQC2.ToolTip.text: "Klick: übernehmen · Doppelklick: zeichnen"
                            QQC2.ToolTip.visible: hovered
                            QQC2.ToolTip.delay: Kirigami.Units.toolTipDelay
                            onClicked: formulaField.text = modelData
                            onDoubleClicked: { formulaField.text = modelData; root.draw(modelData, styleBox.currentValue) }
                        }
                    }
                }
                PC3.Label {
                    Layout.fillWidth: true
                    wrapMode: Text.Wrap
                    opacity: 0.6
                    font: Kirigami.Theme.smallFont
                    text: "x, y ∈ [−1, 1] · r, phi polar · a, b, c zufällig · sin cos exp sqrt abs atan … · x^2"
                }

                // --- Darstellung ---
                Kirigami.Heading { level: 4; text: "Darstellung"; Layout.topMargin: Kirigami.Units.largeSpacing }
                GridLayout {
                    Layout.fillWidth: true
                    columns: 3
                    columnSpacing: Kirigami.Units.smallSpacing

                    PC3.Label { text: "Farben" }
                    PC3.ComboBox {
                        Layout.fillWidth: true
                        Layout.columnSpan: 2
                        model: root.themes
                        textRole: "text"; valueRole: "value"
                        currentIndex: Math.max(0, root.themes.findIndex(t => t.value === (root.settings.theme || "")))
                        onActivated: root.setValue("theme", currentValue)
                    }

                    PC3.Label { text: "Dauer" }
                    PC3.Slider {
                        id: durSlider
                        Layout.fillWidth: true
                        from: 10; to: 900; stepSize: 10
                        value: root.settings.duration || 150
                        onPressedChanged: if (!pressed) root.setValue("duration", Math.round(value))
                    }
                    PC3.Label {
                        text: root.settings.duration === null || root.settings.duration === undefined
                              ? "Std." : (durSlider.value >= 60 ? Math.floor(durSlider.value / 60) + ":" + String(Math.round(durSlider.value % 60)).padStart(2, "0") + " min" : Math.round(durSlider.value) + " s")
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 3.5
                    }

                    PC3.Label { text: "Pause danach" }
                    PC3.Slider {
                        id: holdSlider
                        Layout.fillWidth: true
                        from: 0; to: 600; stepSize: 5
                        value: root.settings.hold ?? 40
                        onPressedChanged: if (!pressed) root.setValue("hold", Math.round(value))
                    }
                    PC3.Label {
                        text: root.settings.hold === null || root.settings.hold === undefined ? "Std." : Math.round(holdSlider.value) + " s"
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 3.5
                    }

                    PC3.Label { text: "Strich" }
                    PC3.Slider {
                        id: widthSlider
                        Layout.fillWidth: true
                        from: 0.3; to: 3; stepSize: 0.1
                        value: root.settings.width || 1.0
                        onPressedChanged: if (!pressed) root.setValue("width", value.toFixed(1))
                    }
                    PC3.Label {
                        text: root.settings.width === null || root.settings.width === undefined ? "Std." : widthSlider.value.toFixed(1) + " px"
                        Layout.preferredWidth: Kirigami.Units.gridUnit * 3.5
                    }
                }
                Flow {
                    Layout.fillWidth: true
                    spacing: Kirigami.Units.largeSpacing
                    PC3.CheckBox {
                        text: "Stift"
                        checked: root.settings.pen ?? true
                        onToggled: root.setValue("pen", checked ? 1 : 0)
                    }
                    PC3.CheckBox {
                        text: "Formel anzeigen"
                        checked: root.settings.label ?? true
                        onToggled: root.setValue("label", checked ? 1 : 0)
                    }
                    PC3.CheckBox {
                        text: "Leerfahrten"
                        checked: root.settings.travel ?? false
                        onToggled: root.setValue("travel", checked ? 1 : 0)
                    }
                }
                PC3.Button {
                    icon.name: "edit-undo"
                    text: "Auf Wallpaper-Einstellungen zurücksetzen"
                    onClicked: root.call("reset")
                }

                // --- Generator ---
                Kirigami.Heading { level: 4; text: "Generator"; Layout.topMargin: Kirigami.Units.largeSpacing }
                PC3.Switch {
                    text: "Alle 30 Minuten neue Zeichnungen"
                    checked: root.timerOn
                    onToggled: root.call("timer " + (checked ? "on" : "off"))
                }
                RowLayout {
                    Layout.fillWidth: true
                    Layout.bottomMargin: Kirigami.Units.smallSpacing
                    PC3.Button {
                        icon.name: "view-refresh"; text: "3 neue"
                        enabled: !root.busy
                        onClicked: {
                            root.busy = true; root.error = ""; root.info = ""
                            root.call("generate 3", (code) => { root.busy = false; if (code === 0) root.info = "3 neue Zeichnungen ✓" })
                        }
                    }
                    PC3.Button { icon.name: "document-edit"; text: "Formeln"; onClicked: { root.call("edit"); root.expanded = false } }
                    PC3.Button { icon.name: "folder-pictures"; text: "SVGs"; onClicked: { root.call("open"); root.expanded = false } }
                }
            }
        }
    }
}
