import Quickshell
import Quickshell.Io
import Quickshell.Wayland
import QtQuick
import qs.Commons
import qs.Ui
import "KeybindModel.js" as KeybindModel

Item {
  id: root

  property var shell: null
  property var manifest: null
  // Directory this QML file lives in, as a filesystem path — works wherever
  // the plugin is installed.
  property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0) url = url.substring(7)
    return url.replace(/\/$/, "")
  }

  property bool opened: false
  property string filterText: ""
  property int selectedIndex: 0
  property bool cursorActive: false

  property var rows: []
  property var xkbMap: ({})        // keycode -> symbol, default layout (display)
  property var activeSymToCode: ({}) // symbol -> keycode, active layout (comparison)
  property var remaps: ({})        // normalized original -> replacement raw combo
  property var remapsInverse: ({}) // normalized replacement -> normalized original

  // Capture dialog state.
  property bool captureOpen: false
  property var captureRow: null    // row being changed
  property var capturedMods: []    // ["SUPER", "SHIFT"]
  property string capturedKeyToken: ""  // "code:45"
  property string capturedKeyLabel: "" // "é", "Enter", ...
  property var pendingMods: []     // modifiers held before a key lands
  // Qt on Wayland does not report AltGr (ISO_Level3_Shift) as a modifier on
  // subsequent key events — it shifts the produced symbol instead. Track the
  // key itself so AltGr combos are capturable. XKB keycode 108 = right Alt.
  property bool altgrHeld: false
  property string conflictText: ""
  property var conflictRow: null   // row currently holding the captured combo
  property bool applying: false
  property color warningColor: "#f2994a"

  property color background: Color.menu.background
  property color foreground: Color.menu.text
  property color border: Color.menu.border
  property var borderSpec: Border.surfaceSpec("menu", "border", border, Math.max(1, Style.space(2)))
  property color scrim: Color.menu.scrim
  property color selectedBackground: Color.menu.selectedBackground
  property color selectedText: Color.menu.selectedText
  readonly property int cornerRadius: Style.cornerRadius
  property string fontFamily: Style.font.menuFamily
  property int contentMargin: Style.spacing.panelPadding
  property int headerHeight: Math.max(Style.space(34), Style.font.title + Style.spacing.controlPaddingY * 2)
  property int contentSpacing: Style.spacing.md
  property int cardWidth: Math.min(Style.space(820), panel.width - Style.gapsOut * 2)
  property int cardHeight: Math.min(Style.space(600), panel.height - Style.gapsOut * 2)
  property int rowHeight: Math.max(Style.space(44), Style.font.body + Style.spacing.rowPaddingX * 2)

  property string lastFocusedAddress: ""

  function open(payloadJson) {
    root.lastFocusedAddress = ""
    activeWinProc.running = true
    root.opened = true
    root.filterText = ""
    root.selectedIndex = 0
    root.cursorActive = false
    root.captureOpen = false
    root.disarmPointer()
    xkbProc.running = true // chains into bindsProc when the symbol map is ready
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function close() {
    if (root.captureOpen) root.setBindsSuspended(false)
    root.captureOpen = false
    root.opened = false
  }

  function dismiss() {
    root.close()
    if (root.shell && typeof root.shell.hide === "function")
      root.shell.hide((root.manifest && root.manifest.id) || "astrofoundry.keybind-editor")
    // Give focus back to the window that had it when the overlay opened.
    // Delayed: dispatched immediately it races the layer unmap and the still
    // mapped exclusive layer keeps the keyboard while the border moves.
    if (root.lastFocusedAddress)
      refocusTimer.restart()
  }

  Timer {
    id: refocusTimer
    interval: 150
    repeat: false
    onTriggered: {
      if (root.lastFocusedAddress)
        root.dispatchCompat('hl.dsp.focus({ window = "address:' + root.lastFocusedAddress + '" })',
                            "focuswindow address:" + root.lastFocusedAddress)
    }
  }

  function toggle() {
    if (root.opened) root.dismiss()
    else root.open("{}")
  }

  function loadBinds(tsv) {
    root.rows = KeybindModel.buildRows(tsv, root.xkbMap)
    root.rebuildDisplay()
  }

  function loadRemaps(text) {
    var parsed = KeybindModel.parseRemaps(text || "")
    var inverse = {}
    for (var original in parsed)
      inverse[KeybindModel.normalize(parsed[original])] = KeybindModel.normalize(original)
    root.remaps = parsed
    root.remapsInverse = inverse
    if (root.opened) root.rebuildDisplay()
  }

  function originalFor(normalized) {
    return root.remapsInverse[normalized] || normalized
  }

  function rebuildDisplay() {
    var filter = root.filterText.toLowerCase()
    displayModel.clear()
    for (var i = 0; i < root.rows.length; i++) {
      var row = root.rows[i]
      if (filter && row.description.toLowerCase().indexOf(filter) === -1
          && row.comboPretty.toLowerCase().indexOf(filter) === -1) continue
      displayModel.append({
        normalized: row.normalized,
        comboPretty: row.comboPretty,
        description: row.description,
        changed: root.originalFor(row.normalized) !== row.normalized
      })
    }
    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0
    Qt.callLater(function() {
      if (displayModel.count > 0) resultList.positionViewAtIndex(root.selectedIndex, ListView.Contain)
    })
  }

  function select(delta) {
    if (displayModel.count === 0) return
    root.disarmPointer()
    if (!cursorActive) {
      cursorActive = true
      selectedIndex = delta < 0 ? displayModel.count - 1 : 0
    } else {
      selectedIndex = (selectedIndex + delta + displayModel.count) % displayModel.count
    }
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function setFilter(nextFilter) {
    root.filterText = nextFilter
    root.selectedIndex = 0
    root.cursorActive = true
    root.disarmPointer()
    root.rebuildDisplay()
  }

  function disarmPointer() {
    pointerGate.reset()
  }

  function selectFromPointer(index, item, mouse) {
    if (!pointerGate.moved(item, mouse)) return
    root.cursorActive = true
    root.selectedIndex = index
  }

  // While capturing, park Hyprland in an empty submap so no global bind
  // matches — otherwise pressing an already-bound combo (e.g. Super+Return)
  // fires its action instead of being captured. Reset is dispatched from
  // every close path; if the shell ever dies mid-capture, recover with:
  //   hyprctl dispatch submap reset
  // Hyprland's Lua-config builds evaluate `hyprctl dispatch` arguments as
  // Lua, so use the hl.dsp form and fall back to the native dispatcher for
  // non-Lua builds (the same pattern omarchy's own scripts use).
  function dispatchCompat(luaExpr, nativeArgs) {
    Quickshell.execDetached(["bash", "-c",
      "hyprctl dispatch '" + luaExpr + "' 2>/dev/null || hyprctl dispatch " + nativeArgs])
  }

  function setBindsSuspended(suspended) {
    var name = suspended ? "keybind-capture" : "reset"
    root.dispatchCompat('hl.dsp.submap("' + name + '")', "submap " + name)
  }

  function isAltgrEvent(event) {
    return event.key === Qt.Key_AltGr || event.key === Qt.Key_Mode_switch
      || event.nativeScanCode === 108
  }

  function openCapture(index) {
    if (index < 0 || index >= displayModel.count) return
    root.altgrHeld = false
    root.captureRow = displayModel.get(index)
    root.capturedMods = []
    root.capturedKeyToken = ""
    root.capturedKeyLabel = ""
    root.pendingMods = []
    root.conflictText = ""
    root.conflictRow = null
    root.applying = false
    root.captureOpen = true
    root.setBindsSuspended(true)
  }

  function closeCapture() {
    if (root.captureOpen) root.setBindsSuspended(false)
    root.captureOpen = false
    root.altgrHeld = false
    root.captureRow = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function capturedRaw() {
    if (!root.capturedKeyToken) return ""
    return KeybindModel.rawCombo(root.capturedMods, root.capturedKeyToken)
  }

  function capturedChips() {
    var chips = []
    var mods = root.capturedKeyToken ? root.capturedMods : root.pendingMods
    for (var i = 0; i < mods.length; i++) chips.push(KeybindModel.prettyMod(mods[i]))
    if (root.capturedKeyLabel) chips.push(root.capturedKeyLabel)
    return chips
  }

  function updateConflict() {
    root.conflictText = ""
    root.conflictRow = null
    var raw = root.capturedRaw()
    if (!raw || !root.captureRow) return
    var canonical = KeybindModel.canonicalCombo(KeybindModel.normalize(raw), root.activeSymToCode)
    if (canonical === KeybindModel.canonicalCombo(root.captureRow.normalized, root.activeSymToCode)) return
    for (var i = 0; i < root.rows.length; i++) {
      if (KeybindModel.canonicalCombo(root.rows[i].normalized, root.activeSymToCode) === canonical) {
        root.conflictRow = root.rows[i]
        root.conflictText = "Already bound: " + root.rows[i].description
          + " — Enter overrides and removes it there"
        return
      }
    }
  }

  function handleCaptureKey(event) {
    event.accepted = true
    if (root.applying) return

    var bare = KeybindModel.modTokensFromQt(event.modifiers).length === 0

    // Bare Escape always cancels — it is never capturable on its own.
    // Modified combos (e.g. Super+Escape) remain bindable.
    if (event.key === Qt.Key_Escape && bare && !root.altgrHeld) {
      root.closeCapture()
      return
    }
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && bare) {
      root.applyCapture()
      return
    }
    // Bare Backspace always clears (never capturable alone), like Escape.
    if (event.key === Qt.Key_Backspace && bare && !root.altgrHeld) {
      root.capturedMods = []
      root.capturedKeyToken = ""
      root.capturedKeyLabel = ""
      root.pendingMods = []
      root.conflictText = ""
      root.conflictRow = null
      return
    }

    if (KeybindModel.isModifierKey(event.key) || root.isAltgrEvent(event)) {
      if (root.isAltgrEvent(event)) root.altgrHeld = true
      var held = KeybindModel.modTokensFromQt(event.modifiers)
      var own = KeybindModel.modTokenOfKey(event.key)
      if (own && held.indexOf(own) === -1) held.push(own)
      if (root.altgrHeld && held.indexOf("MOD5") === -1) held.push("MOD5")
      root.pendingMods = held
      return
    }

    var mods = KeybindModel.modTokensFromQt(event.modifiers)
    if (root.altgrHeld && mods.indexOf("MOD5") === -1) mods.push("MOD5")
    root.capturedMods = mods
    root.capturedKeyToken = "code:" + event.nativeScanCode
    var named = KeybindModel.qtKeyName(event.key)
    if (named) root.capturedKeyLabel = named
    else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127)
      root.capturedKeyLabel = event.text
    else root.capturedKeyLabel = KeybindModel.prettyKey(root.capturedKeyToken, root.xkbMap)
    root.pendingMods = []
    root.updateConflict()
  }

  function applyCapture() {
    var raw = root.capturedRaw()
    if (!raw || !root.captureRow) return
    var original = root.originalFor(root.captureRow.normalized)
    var restoresDefault = KeybindModel.canonicalCombo(KeybindModel.normalize(raw), root.activeSymToCode)
      === KeybindModel.canonicalCombo(original, root.activeSymToCode)
    var ops = restoresDefault
      ? ["delete", original]
      : ["set", original, raw]
    // Overriding a conflict removes the combo from the action that held it.
    if (root.conflictRow)
      ops = ops.concat(["disable", root.originalFor(root.conflictRow.normalized)])
    root.applying = true
    applyProc.command = [root.pluginDir + "/apply-remap.sh"].concat(ops)
    applyProc.running = true
  }

  ListModel { id: displayModel }

  PointerMoveGate {
    id: pointerGate
    referenceItem: card
  }

  Process {
    id: activeWinProc
    command: ["hyprctl", "activewindow", "-j"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        try {
          var win = JSON.parse(text)
          root.lastFocusedAddress = win && win.address ? String(win.address) : ""
        } catch (e) {
          root.lastFocusedAddress = ""
        }
      }
    }
  }

  Process {
    id: xkbProc
    command: ["bash", root.pluginDir + "/xkb-symbols.sh"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var map = {}
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split("\t")
          if (parts.length === 2) map[parts[0]] = parts[1]
        }
        root.xkbMap = map
        activeXkbProc.running = true
      }
    }
  }

  Process {
    id: activeXkbProc
    command: ["bash", root.pluginDir + "/xkb-symbols.sh", "--active"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var inverse = {}
        var lines = text.split("\n")
        for (var i = 0; i < lines.length; i++) {
          var parts = lines[i].split("\t")
          if (parts.length !== 2) continue
          var code = parseInt(parts[0], 10)
          var symbol = parts[1]
          if (!(symbol in inverse) || code < inverse[symbol]) inverse[symbol] = code
        }
        root.activeSymToCode = inverse
        bindsProc.running = true
      }
    }
  }

  Process {
    id: bindsProc
    command: ["lua", root.pluginDir + "/extract-binds.lua"]
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.loadBinds(text)
    }
  }

  Process {
    id: applyProc
    onExited: function(exitCode) {
      root.applying = false
      if (exitCode === 0) {
        root.closeCapture()
        bindsProc.running = true
      } else {
        root.conflictText = "Apply failed — see notification"
      }
    }
  }

  FileView {
    id: remapsFile
    path: Quickshell.env("HOME") + "/.config/hypr/keybind-remaps.lua"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadRemaps(text())
    onLoadFailed: root.loadRemaps("")
    onFileChanged: reload()
  }

  PanelWindow {
    id: panel
    visible: root.opened
    anchors { top: true; bottom: true; left: true; right: true }
    color: "transparent"
    WlrLayershell.namespace: "omarchy-keybind-editor"
    WlrLayershell.layer: WlrLayer.Overlay
    WlrLayershell.keyboardFocus: WlrKeyboardFocus.Exclusive
    exclusionMode: ExclusionMode.Ignore

    Rectangle {
      anchors.fill: parent
      color: root.scrim
    }

    MouseArea {
      anchors.fill: parent
      onClicked: root.dismiss()
    }

    BorderSurface {
      id: card
      width: root.cardWidth
      height: root.cardHeight
      radius: root.cornerRadius
      anchors.centerIn: parent
      color: root.background
      borderSpec: root.borderSpec
      padding: root.contentMargin

      MouseArea { anchors.fill: parent; onClicked: {} }

      Item {
        id: keyCatcher
        anchors.fill: parent
        focus: true

        Keys.priority: Keys.BeforeItem
        Keys.onReleased: function(event) {
          if (root.captureOpen && root.isAltgrEvent(event)) {
            root.altgrHeld = false
            event.accepted = true
          }
        }
        Keys.onPressed: function(event) {
          if (root.captureOpen) {
            root.handleCaptureKey(event)
            return
          }

          if (event.key === Qt.Key_Escape) {
            if (root.filterText) root.setFilter("")
            else root.dismiss()
            event.accepted = true
          } else if (Util.editsFilter(event, root.filterText)) {
            root.setFilter(Util.editedFilter(event, root.filterText))
            event.accepted = true
          } else if (event.key === Qt.Key_Up) {
            root.select(-1)
            event.accepted = true
          } else if (event.key === Qt.Key_Down) {
            root.select(1)
            event.accepted = true
          } else if (event.key === Qt.Key_PageUp) {
            root.select(-6)
            event.accepted = true
          } else if (event.key === Qt.Key_PageDown) {
            root.select(6)
            event.accepted = true
          } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
            if (root.cursorActive) root.openCapture(root.selectedIndex)
            else if (displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.text && event.text.length === 1 && event.text.charCodeAt(0) >= 32 && event.text.charCodeAt(0) !== 127) {
            root.setFilter(root.filterText + event.text)
            event.accepted = true
          }
        }
      }

      Column {
        anchors.fill: parent
        anchors.topMargin: card.contentTopInset
        anchors.rightMargin: card.contentRightInset
        anchors.bottomMargin: card.contentBottomInset
        anchors.leftMargin: card.contentLeftInset
        spacing: root.contentSpacing

        Item {
          width: parent.width
          height: root.headerHeight

          Text {
            anchors.left: parent.left
            anchors.right: hintText.left
            anchors.verticalCenter: parent.verticalCenter
            text: root.filterText || "Search keybindings…"
            color: root.foreground
            opacity: root.filterText ? 1 : 0.58
            font.family: root.fontFamily
            font.pixelSize: Style.font.heading
            elide: Text.ElideRight
          }

          Text {
            id: hintText
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            text: "Enter to change · Esc to close"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }
        }

        Item {
          width: parent.width
          height: parent.height - root.headerHeight - root.contentSpacing

          ListView {
            id: resultList
            anchors.fill: parent
            model: displayModel
            clip: true
            spacing: Style.space(4)
            boundsBehavior: Flickable.StopAtBounds

            delegate: Rectangle {
              id: row
              required property int index
              required property string normalized
              required property string comboPretty
              required property string description
              required property bool changed

              readonly property bool hasCursor: root.cursorActive && index === root.selectedIndex

              width: ListView.view.width
              height: root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              MouseArea {
                anchors.fill: parent
                hoverEnabled: true
                onPositionChanged: function(mouse) { root.selectFromPointer(row.index, row, mouse) }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                }
              }

              Row {
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(10)

                Item {
                  width: Style.space(230)
                  height: parent.height

                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    Text {
                      text: row.comboPretty
                      color: row.hasCursor ? root.selectedText : root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                    }

                    Text {
                      visible: row.changed
                      anchors.verticalCenter: parent.verticalCenter
                      text: "· changed"
                      color: row.hasCursor ? root.selectedText : root.foreground
                      opacity: 0.55
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption
                    }
                  }
                }

                Text {
                  width: parent.width - Style.space(230) - changeButton.width - parent.spacing * 2
                  height: parent.height
                  text: row.description
                  color: row.hasCursor ? root.selectedText : root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  elide: Text.ElideRight
                  verticalAlignment: Text.AlignVCenter
                }

                Rectangle {
                  id: changeButton
                  anchors.verticalCenter: parent.verticalCenter
                  width: changeLabel.implicitWidth + Style.space(20)
                  height: Math.min(root.rowHeight - Style.space(12), Style.space(28))
                  radius: root.cornerRadius
                  color: changeArea.containsMouse ? root.selectedBackground : "transparent"
                  border.color: Util.alpha(row.hasCursor ? root.selectedText : root.foreground, 0.4)
                  border.width: 1
                  opacity: row.hasCursor || changeArea.containsMouse ? 1 : 0.55

                  Text {
                    id: changeLabel
                    anchors.centerIn: parent
                    text: "Change"
                    color: changeArea.containsMouse ? root.selectedText : (row.hasCursor ? root.selectedText : root.foreground)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                  }

                  MouseArea {
                    id: changeArea
                    anchors.fill: parent
                    hoverEnabled: true
                    cursorShape: Qt.PointingHandCursor
                    onClicked: {
                      root.cursorActive = true
                      root.selectedIndex = row.index
                      root.openCapture(row.index)
                    }
                  }
                }
              }
            }
          }

          Text {
            anchors.centerIn: parent
            visible: displayModel.count === 0
            text: root.rows.length === 0 ? "Loading keybindings…" : "No matches for “" + root.filterText + "”"
            color: root.foreground
            opacity: 0.7
            font.family: root.fontFamily
            font.pixelSize: Style.font.title
          }
        }
      }

      // Capture popin, VS Code style.
      Rectangle {
        anchors.fill: parent
        visible: root.captureOpen
        color: root.scrim
        radius: root.cornerRadius

        MouseArea { anchors.fill: parent; onClicked: root.closeCapture() }

        BorderSurface {
          width: Math.min(Style.space(480), parent.width - Style.space(40))
          height: captureColumn.implicitHeight + Style.space(48)
          radius: root.cornerRadius
          anchors.centerIn: parent
          color: root.background
          borderSpec: root.borderSpec

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: captureColumn
            anchors.centerIn: parent
            width: parent.width - Style.space(48)
            spacing: Style.space(14)

            Text {
              width: parent.width
              text: root.captureRow ? root.captureRow.description : ""
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideMiddle
            }

            Text {
              width: parent.width
              text: "Press desired key combination and then press ENTER."
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }

            Rectangle {
              width: parent.width
              height: Style.space(38)
              radius: root.cornerRadius
              color: "transparent"
              border.color: root.conflictRow ? root.warningColor : root.selectedBackground
              border.width: 2

              Text {
                anchors.centerIn: parent
                text: root.capturedRaw()
                    ? KeybindModel.prettyCombo(root.capturedRaw(), root.xkbMap)
                    : (root.pendingMods.length > 0
                        ? KeybindModel.rawCombo(root.pendingMods.map(KeybindModel.prettyMod), "…")
                        : (root.captureRow ? root.captureRow.comboPretty : ""))
                color: root.foreground
                opacity: root.capturedRaw() ? 1 : 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              spacing: Style.space(6)
              visible: root.capturedChips().length > 0

              Repeater {
                model: root.capturedChips()

                Row {
                  spacing: Style.space(6)

                  Text {
                    visible: index > 0
                    anchors.verticalCenter: parent.verticalCenter
                    text: "+"
                    color: root.foreground
                    opacity: 0.6
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                  }

                  Rectangle {
                    width: chipLabel.implicitWidth + Style.space(16)
                    height: chipLabel.implicitHeight + Style.space(8)
                    radius: Style.space(5)
                    color: Util.alpha(root.foreground, 0.14)

                    Text {
                      id: chipLabel
                      anchors.centerIn: parent
                      text: modelData
                      color: root.foreground
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }
                  }
                }
              }
            }

            Text {
              width: parent.width
              visible: root.conflictText !== ""
              text: "⚠ " + root.conflictText
              color: root.warningColor
              opacity: 1
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              text: root.applying ? "Applying…" : "Enter apply · Esc cancel · Backspace clear"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }
    }
  }
}
