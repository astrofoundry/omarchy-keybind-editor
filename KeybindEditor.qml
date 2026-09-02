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
  property var removedRows: []     // binds the hook dropped (editor removed); combo is the original
  property var xkbMap: ({})        // keycode -> symbol, default layout (display)
  property var activeSymToCode: ({}) // symbol -> keycode, active layout (comparison)
  property var remaps: ({})        // normalized original -> replacement raw combo
  property var remapsInverse: ({}) // normalized replacement -> normalized original
  property var renames: ({})       // normalized original -> replacement description (defaults only)
  property var customBinds: ({})   // normalized combo -> { combo, description, command } from bindings.lua marker lines
  property bool bindsSuspended: false // Hyprland parked in the capture submap

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
  property bool deleteConfirm: false // capture dialog is confirming a delete
  property bool renameMode: false    // capture dialog is editing the description
  property bool applying: false
  property color warningColor: "#f2994a"

  // Reset confirmation dialog state. Kind "combo" resets a changed row to
  // its default combo, "name" drops a rename, "restore" brings a removed
  // bind back.
  property bool resetOpen: false
  property var resetRow: null
  property string resetKind: "combo"

  // Add-custom-bind dialog state. Stage 0 captures the combo (binds
  // suspended, like the capture dialog); stages 1 and 2 are plain text
  // entry for the description and the command.
  property bool addOpen: false
  property int addStage: 0

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
    if (root.bindsSuspended) root.setBindsSuspended(false)
    root.captureOpen = false
    root.renameMode = false
    root.resetOpen = false
    root.resetRow = null
    root.addOpen = false
    root.addStage = 0
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
    root.removedRows = KeybindModel.buildRemoved(tsv, root.xkbMap)
    root.rebuildDisplay()
  }

  function loadRenames(text) {
    root.renames = KeybindModel.parseRemaps(text || "")
    if (root.opened) root.rebuildDisplay()
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

  function loadCustomBinds(text) {
    root.customBinds = KeybindModel.parseCustomBinds(text || "")
    if (root.opened) root.rebuildDisplay()
  }

  function matchesFilter(filter, row) {
    return !filter || row.description.toLowerCase().indexOf(filter) !== -1
      || row.comboPretty.toLowerCase().indexOf(filter) !== -1
  }

  // Every append carries the full role set: a ListModel fixes its roles on
  // the first row, and the header and removed rows share the delegate.
  function rebuildDisplay() {
    var filter = root.filterText.toLowerCase()
    displayModel.clear()
    for (var i = 0; i < root.rows.length; i++) {
      var row = root.rows[i]
      if (!root.matchesFilter(filter, row)) continue
      var original = root.originalFor(row.normalized)
      var isCustom = !!root.customBinds[original]
      displayModel.append({
        kind: "bind",
        normalized: row.normalized,
        comboPretty: row.comboPretty,
        description: row.description,
        stockDescription: row.sortDescription,
        // A custom bind is updated in place, so it has no default to mark a
        // change against; a legacy remap entry may still redirect it. Same
        // for its name: a custom rename rewrites the o.bind line.
        changed: original !== row.normalized && !isCustom,
        renamed: !isCustom && (original in root.renames),
        custom: isCustom
      })
    }
    var removed = root.removedRows.filter(function(row) { return root.matchesFilter(filter, row) })
    if (removed.length > 0) {
      displayModel.append({
        kind: "header", normalized: "", comboPretty: "", description: "Removed",
        stockDescription: "", changed: false, renamed: false, custom: false
      })
      for (var j = 0; j < removed.length; j++) {
        displayModel.append({
          kind: "removed",
          normalized: removed[j].normalized,
          comboPretty: removed[j].comboPretty,
          description: removed[j].description,
          stockDescription: removed[j].description,
          changed: false, renamed: false, custom: false
        })
      }
    }
    if (displayModel.count === 0) selectedIndex = 0
    else if (selectedIndex >= displayModel.count) selectedIndex = displayModel.count - 1
    else if (selectedIndex < 0) selectedIndex = 0
    // Only removed rows match: the header sits at the top; skip it.
    if (displayModel.count > 1 && displayModel.get(selectedIndex).kind === "header") selectedIndex++
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
    // The section header is not selectable; step over it in the direction
    // of travel (it never sits at either end of the list).
    if (displayModel.get(selectedIndex).kind === "header")
      selectedIndex = (selectedIndex + (delta < 0 ? -1 : 1) + displayModel.count) % displayModel.count
    resultList.positionViewAtIndex(selectedIndex, ListView.Contain)
  }

  function selectedKind() {
    if (!root.cursorActive || root.selectedIndex < 0 || root.selectedIndex >= displayModel.count) return ""
    return displayModel.get(root.selectedIndex).kind
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
    root.bindsSuspended = suspended
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
    root.deleteConfirm = false
    root.renameMode = false
    root.applying = false
    root.captureOpen = true
    root.setBindsSuspended(true)
  }

  function closeCapture() {
    if (root.bindsSuspended) root.setBindsSuspended(false)
    root.captureOpen = false
    root.deleteConfirm = false
    root.renameMode = false
    root.altgrHeld = false
    root.captureRow = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Shortcuts from the list: open the dialog straight into delete
  // confirmation or rename, skipping the capture step.
  function openDelete(index) {
    root.openCapture(index)
    if (root.captureOpen) root.enterDeleteConfirm()
  }

  function openRename(index) {
    root.openCapture(index)
    if (root.captureOpen) root.enterRename()
  }

  function openAdd() {
    root.altgrHeld = false
    root.captureRow = null
    root.capturedMods = []
    root.capturedKeyToken = ""
    root.capturedKeyLabel = ""
    root.pendingMods = []
    root.conflictText = ""
    root.conflictRow = null
    root.applying = false
    root.addStage = 0
    addDescriptionInput.text = ""
    addCommandInput.text = ""
    root.addOpen = true
    root.setBindsSuspended(true)
  }

  function closeAdd() {
    if (root.bindsSuspended) root.setBindsSuspended(false)
    root.addOpen = false
    root.addStage = 0
    root.altgrHeld = false
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  function advanceAdd() {
    if (root.applying) return
    if (root.addStage === 0) {
      // A taken combo blocks here: adding would duplicate an existing bind.
      if (!root.capturedRaw() || root.conflictRow) return
      root.setBindsSuspended(false)
      root.addStage = 1
      Qt.callLater(function() { addDescriptionInput.forceActiveFocus() })
    } else if (root.addStage === 1) {
      if (!addDescriptionInput.text.trim()) return
      root.addStage = 2
      Qt.callLater(function() { addCommandInput.forceActiveFocus() })
    } else {
      if (!addCommandInput.text.trim()) return
      root.applying = true
      applyProc.command = [root.pluginDir + "/add-bind.sh", root.capturedRaw(),
                           addDescriptionInput.text.trim(), addCommandInput.text.trim()]
      applyProc.running = true
    }
  }

  // No submap suspension here: the dialog only confirms, it captures no keys.
  function openReset(index, kind) {
    if (index < 0 || index >= displayModel.count) return
    root.resetRow = displayModel.get(index)
    root.resetKind = kind || "combo"
    root.conflictText = ""
    root.applying = false
    // A restored bind lands on its original combo; warn when a live bind
    // holds it, since both would then fire.
    if (root.resetKind === "restore") {
      var canonical = KeybindModel.canonicalCombo(root.resetRow.normalized, root.activeSymToCode)
      for (var i = 0; i < root.rows.length; i++) {
        if (KeybindModel.canonicalCombo(root.rows[i].normalized, root.activeSymToCode) === canonical) {
          root.conflictText = "Already bound: " + root.rows[i].description
            + " · both would fire on this combination"
          break
        }
      }
    }
    root.resetOpen = true
  }

  function closeReset() {
    root.resetOpen = false
    root.resetRow = null
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // Every kind is one apply-remap.sh op on the original combo: "combo" and
  // "restore" delete the remap entry (a removed bind's row already carries
  // its original combo), "name" drops the rename entry.
  function applyReset() {
    if (!root.resetRow || root.applying) return
    root.applying = true
    var original = root.originalFor(root.resetRow.normalized)
    applyProc.command = [root.pluginDir + "/apply-remap.sh",
                         root.resetKind === "name" ? "unrename" : "delete", original]
    applyProc.running = true
  }

  function resetPrompt() {
    if (!root.resetRow) return ""
    var row = root.resetRow
    if (root.resetKind === "name")
      return "Reset the name of " + row.comboPretty + " to “" + row.stockDescription + "”?"
    if (root.resetKind === "restore")
      return "Restore " + row.comboPretty + " (" + row.description + ")?"
    return "Reset " + row.comboPretty + " to its default "
      + KeybindModel.prettyCombo(root.originalFor(row.normalized), root.xkbMap) + "?"
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
    if (!raw) return
    var canonical = KeybindModel.canonicalCombo(KeybindModel.normalize(raw), root.activeSymToCode)
    // Rebinding a row to its own combo is not a conflict; adding has no self.
    if (root.captureRow
        && canonical === KeybindModel.canonicalCombo(root.captureRow.normalized, root.activeSymToCode)) return
    for (var i = 0; i < root.rows.length; i++) {
      if (KeybindModel.canonicalCombo(root.rows[i].normalized, root.activeSymToCode) === canonical) {
        root.conflictRow = root.rows[i]
        root.conflictText = "Already bound: " + root.rows[i].description
          + (root.addOpen ? " · press another combination"
                          : " · Enter overrides and removes it there")
        return
      }
    }
  }

  // Clear any captured combo first so the dialog shows the binding about to
  // be deleted, not a half-entered replacement.
  function enterDeleteConfirm() {
    if (!root.captureRow || root.applying) return
    root.capturedMods = []
    root.capturedKeyToken = ""
    root.capturedKeyLabel = ""
    root.pendingMods = []
    root.conflictText = ""
    root.conflictRow = null
    root.deleteConfirm = true
  }

  // Rename edits text, so binds are un-suspended for it (like the add
  // dialog's text stages); Esc back to capture suspends them again.
  function enterRename() {
    if (!root.captureRow || root.applying) return
    root.capturedMods = []
    root.capturedKeyToken = ""
    root.capturedKeyLabel = ""
    root.pendingMods = []
    root.conflictText = ""
    root.conflictRow = null
    root.deleteConfirm = false
    root.renameMode = true
    renameInput.text = root.captureRow.description
    root.setBindsSuspended(false)
    Qt.callLater(function() { renameInput.forceActiveFocus(); renameInput.selectAll() })
  }

  function leaveRename() {
    root.renameMode = false
    root.setBindsSuspended(true)
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  // A custom bind is renamed in place in bindings.lua; a default goes into
  // keybind-renames.lua, and typing its stock name back drops the entry.
  function applyRename() {
    if (!root.captureRow || root.applying) return
    var name = renameInput.text.trim()
    if (!name) return
    if (name === root.captureRow.description) {
      root.closeCapture()
      return
    }
    var original = root.originalFor(root.captureRow.normalized)
    var custom = root.customBinds[original]
    root.applying = true
    if (custom) {
      applyProc.command = [root.pluginDir + "/update-bind.sh", "--description", custom.combo, name]
    } else if (name === root.captureRow.stockDescription) {
      applyProc.command = [root.pluginDir + "/apply-remap.sh", "unrename", original]
    } else {
      applyProc.command = [root.pluginDir + "/apply-remap.sh", "rename", original, name]
    }
    applyProc.running = true
  }

  // A custom bind loses its o.bind line (remove-bind.sh); everything else is
  // disabled through an empty remap, which the hook drops at registration.
  function applyDelete() {
    if (!root.captureRow || root.applying) return
    var original = root.originalFor(root.captureRow.normalized)
    var custom = root.customBinds[original]
    root.applying = true
    if (custom) {
      var cmd = [root.pluginDir + "/remove-bind.sh",
                 custom.combo, custom.description, custom.command]
      if (original !== root.captureRow.normalized) cmd.push(original)
      applyProc.command = cmd
    } else {
      applyProc.command = [root.pluginDir + "/apply-remap.sh", "disable", original]
    }
    applyProc.running = true
  }

  function handleCaptureKey(event) {
    event.accepted = true
    if (root.applying) return

    var bare = KeybindModel.modTokensFromQt(event.modifiers).length === 0

    // Delete-confirm state: Enter deletes, Esc drops back to capture. Every
    // other key is swallowed so the captured combo cannot change under the
    // confirmation text.
    if (root.deleteConfirm) {
      if (event.key === Qt.Key_Escape && bare) root.deleteConfirm = false
      else if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && bare) root.applyDelete()
      return
    }

    // Bare Escape always cancels — it is never capturable on its own.
    // Modified combos (e.g. Super+Escape) remain bindable.
    if (event.key === Qt.Key_Escape && bare && !root.altgrHeld) {
      if (root.addOpen) root.closeAdd()
      else root.closeCapture()
      return
    }
    if ((event.key === Qt.Key_Return || event.key === Qt.Key_Enter) && bare) {
      if (root.addOpen) root.advanceAdd()
      else root.applyCapture()
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
    // Bare Delete asks to delete the binding (reserved like Backspace);
    // modified combos such as Super+Delete stay capturable. The add dialog
    // has nothing to delete. Bare F2 renames, for the same reasons.
    if (event.key === Qt.Key_Delete && bare && !root.altgrHeld && !root.addOpen) {
      root.enterDeleteConfirm()
      return
    }
    if (event.key === Qt.Key_F2 && bare && !root.altgrHeld && !root.addOpen) {
      root.enterRename()
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
    var custom = root.customBinds[original]
    var cmd
    if (custom) {
      // Custom binds are rewritten in place in bindings.lua; the extra args
      // are apply-remap.sh ops for a legacy remap entry and any conflict.
      cmd = [root.pluginDir + "/update-bind.sh", custom.combo, raw]
      if (original !== root.captureRow.normalized) cmd.push("delete", original)
      if (root.conflictRow) cmd.push("disable", root.originalFor(root.conflictRow.normalized))
    } else {
      var restoresDefault = KeybindModel.canonicalCombo(KeybindModel.normalize(raw), root.activeSymToCode)
        === KeybindModel.canonicalCombo(original, root.activeSymToCode)
      var ops = restoresDefault
        ? ["delete", original]
        : ["set", original, raw]
      // Overriding a conflict removes the combo from the action that held it.
      if (root.conflictRow)
        ops = ops.concat(["disable", root.originalFor(root.conflictRow.normalized)])
      cmd = [root.pluginDir + "/apply-remap.sh"].concat(ops)
    }
    root.applying = true
    applyProc.command = cmd
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
        root.closeReset()
        root.closeAdd()
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

  FileView {
    id: renamesFile
    path: Quickshell.env("HOME") + "/.config/hypr/keybind-renames.lua"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadRenames(text())
    onLoadFailed: root.loadRenames("")
    onFileChanged: reload()
  }

  FileView {
    id: bindingsFile
    path: Quickshell.env("HOME") + "/.config/hypr/bindings.lua"
    watchChanges: true
    printErrors: false
    onLoaded: root.loadCustomBinds(text())
    onLoadFailed: root.loadCustomBinds("")
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
          if ((root.captureOpen || (root.addOpen && root.addStage === 0)) && root.isAltgrEvent(event)) {
            root.altgrHeld = false
            event.accepted = true
          }
        }
        Keys.onPressed: function(event) {
          if (root.captureOpen) {
            // Rename keeps focus in a TextInput; only a stray Escape lands here.
            if (root.renameMode) {
              if (event.key === Qt.Key_Escape) root.leaveRename()
              event.accepted = true
              return
            }
            root.handleCaptureKey(event)
            return
          }

          if (root.addOpen) {
            // Stage 0 captures the combo; later stages keep focus in a
            // TextInput and only a stray Escape lands here.
            if (root.addStage === 0) root.handleCaptureKey(event)
            else if (event.key === Qt.Key_Escape) {
              root.closeAdd()
              event.accepted = true
            }
            return
          }

          if (root.resetOpen) {
            if (event.key === Qt.Key_Escape) root.closeReset()
            else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) root.applyReset()
            event.accepted = true
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
            var kind = root.selectedKind()
            if (kind === "bind") root.openCapture(root.selectedIndex)
            else if (kind === "removed") root.openReset(root.selectedIndex, "restore")
            else if (!root.cursorActive && displayModel.count > 0) root.cursorActive = true
            event.accepted = true
          } else if (event.key === Qt.Key_Delete) {
            if (root.selectedKind() === "bind") root.openDelete(root.selectedIndex)
            event.accepted = true
          } else if (event.key === Qt.Key_F2) {
            if (root.selectedKind() === "bind") root.openRename(root.selectedIndex)
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
            anchors.right: addButton.left
            anchors.rightMargin: Style.space(14)
            anchors.verticalCenter: parent.verticalCenter
            text: "Enter change · F2 rename · Del delete · Esc close"
            color: root.foreground
            opacity: 0.4
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
          }

          Rectangle {
            id: addButton
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            width: addLabel.implicitWidth + Style.space(20)
            height: Math.min(root.headerHeight - Style.space(6), Style.space(28))
            radius: root.cornerRadius
            color: addButtonArea.containsMouse ? root.selectedBackground : "transparent"
            border.color: Util.alpha(root.foreground, 0.4)
            border.width: 1
            opacity: addButtonArea.containsMouse ? 1 : 0.7

            Text {
              id: addLabel
              anchors.centerIn: parent
              text: "+ Add custom…"
              color: addButtonArea.containsMouse ? root.selectedText : root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            MouseArea {
              id: addButtonArea
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: root.openAdd()
            }
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
              required property string kind
              required property string normalized
              required property string comboPretty
              required property string description
              required property bool changed
              required property bool renamed

              readonly property bool isHeader: kind === "header"
              readonly property bool isRemoved: kind === "removed"
              readonly property bool hasCursor: !isHeader && root.cursorActive && index === root.selectedIndex
              readonly property color textColor: hasCursor ? root.selectedText : root.foreground
              readonly property int buttonHeight: Math.min(root.rowHeight - Style.space(12), Style.space(28))

              width: ListView.view.width
              height: isHeader ? Style.space(30) : root.rowHeight
              radius: root.cornerRadius
              color: hasCursor ? root.selectedBackground : "transparent"

              MouseArea {
                anchors.fill: parent
                enabled: !row.isHeader
                hoverEnabled: true
                onPositionChanged: function(mouse) { root.selectFromPointer(row.index, row, mouse) }
                onClicked: {
                  root.cursorActive = true
                  root.selectedIndex = row.index
                }
              }

              // Section header for the removed binds below the live list.
              Row {
                visible: row.isHeader
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                anchors.bottom: parent.bottom
                anchors.bottomMargin: Style.space(4)
                spacing: Style.space(10)

                Text {
                  text: row.description
                  color: root.foreground
                  opacity: 0.55
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                  font.bold: true
                }

                Text {
                  anchors.verticalCenter: parent.verticalCenter
                  text: "Enter or Restore brings a binding back"
                  color: root.foreground
                  opacity: 0.35
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.caption
                }
              }

              Row {
                visible: !row.isHeader
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
                      color: row.textColor
                      opacity: row.isRemoved ? 0.5 : 1
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      font.bold: true
                      font.strikeout: row.isRemoved
                    }

                    Text {
                      visible: row.changed
                      anchors.verticalCenter: parent.verticalCenter
                      // Fixed to the wider label so the hover swap cannot
                      // shrink the hit area under the pointer and flicker.
                      width: badgeMetrics.width
                      text: badgeArea.containsMouse ? "· reset" : "· changed"
                      color: badgeArea.containsMouse ? root.warningColor : row.textColor
                      opacity: badgeArea.containsMouse ? 1 : 0.55
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption

                      TextMetrics {
                        id: badgeMetrics
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        text: "· changed"
                      }

                      MouseArea {
                        id: badgeArea
                        anchors.fill: parent
                        anchors.margins: -Style.space(4)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.cursorActive = true
                          root.selectedIndex = row.index
                          root.openReset(row.index, "combo")
                        }
                      }
                    }
                  }
                }

                // Description plus the renamed marker (defaults only; a
                // custom bind's name lives in its own o.bind line).
                Item {
                  id: descriptionSlot
                  width: parent.width - Style.space(230) - actionRow.width - parent.spacing * 2
                  height: parent.height

                  Row {
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(6)

                    Text {
                      width: Math.min(implicitWidth, descriptionSlot.width
                                      - (row.renamed ? renamedMetrics.width + Style.space(6) : 0))
                      text: row.description
                      color: row.textColor
                      opacity: row.isRemoved ? 0.5 : 1
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                      elide: Text.ElideRight
                    }

                    Text {
                      visible: row.renamed
                      anchors.verticalCenter: parent.verticalCenter
                      width: renamedMetrics.width
                      text: renamedArea.containsMouse ? "· reset name" : "· renamed"
                      color: renamedArea.containsMouse ? root.warningColor : row.textColor
                      opacity: renamedArea.containsMouse ? 1 : 0.55
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption

                      TextMetrics {
                        id: renamedMetrics
                        font.family: root.fontFamily
                        font.pixelSize: Style.font.caption
                        text: "· reset name"
                      }

                      MouseArea {
                        id: renamedArea
                        anchors.fill: parent
                        anchors.margins: -Style.space(4)
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.cursorActive = true
                          root.selectedIndex = row.index
                          root.openReset(row.index, "name")
                        }
                      }
                    }
                  }
                }

                // Live rows: a small delete button (opens the dialog in its
                // confirm step, never one-click) and Change. Removed rows: Restore.
                Row {
                  id: actionRow
                  anchors.verticalCenter: parent.verticalCenter
                  spacing: Style.space(6)

                  Rectangle {
                    id: deleteButton
                    visible: !row.isRemoved
                    width: row.buttonHeight
                    height: row.buttonHeight
                    radius: root.cornerRadius
                    color: deleteButtonArea.containsMouse ? Util.alpha(root.warningColor, 0.18) : "transparent"
                    border.color: deleteButtonArea.containsMouse ? root.warningColor : Util.alpha(row.textColor, 0.4)
                    border.width: 1
                    opacity: row.hasCursor || deleteButtonArea.containsMouse ? 1 : 0.55

                    Text {
                      anchors.centerIn: parent
                      text: "×"
                      color: deleteButtonArea.containsMouse ? root.warningColor : row.textColor
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.body
                    }

                    MouseArea {
                      id: deleteButtonArea
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: {
                        root.cursorActive = true
                        root.selectedIndex = row.index
                        root.openDelete(row.index)
                      }
                    }
                  }

                  Rectangle {
                    id: changeButton
                    width: changeLabel.implicitWidth + Style.space(20)
                    height: row.buttonHeight
                    radius: root.cornerRadius
                    color: changeArea.containsMouse ? root.selectedBackground : "transparent"
                    border.color: Util.alpha(row.textColor, 0.4)
                    border.width: 1
                    opacity: row.hasCursor || changeArea.containsMouse ? 1 : 0.55

                    Text {
                      id: changeLabel
                      anchors.centerIn: parent
                      text: row.isRemoved ? "Restore" : "Change"
                      color: changeArea.containsMouse ? root.selectedText : row.textColor
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
                        if (row.isRemoved) root.openReset(row.index, "restore")
                        else root.openCapture(row.index)
                      }
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
              text: root.deleteConfirm
                  ? (root.captureRow && root.captureRow.custom
                      ? "Delete this custom binding? Its o.bind line is removed from bindings.lua."
                      : "Remove this binding? It moves to the Removed section, where Restore brings it back.")
                  : root.renameMode ? "Type the new name and press ENTER."
                  : "Press desired key combination and then press ENTER."
              color: root.deleteConfirm ? root.warningColor : root.foreground
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
              border.color: root.deleteConfirm ? root.warningColor
                          : (root.conflictRow ? root.warningColor : root.selectedBackground)
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

            // Rename field; a custom bind is renamed in place, a default
            // through keybind-renames.lua.
            Rectangle {
              visible: root.renameMode
              width: parent.width
              height: Style.space(38)
              radius: root.cornerRadius
              color: "transparent"
              border.color: root.selectedBackground
              border.width: 2

              TextInput {
                id: renameInput
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                verticalAlignment: TextInput.AlignVCenter
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                clip: true
                onAccepted: root.applyRename()
                Keys.onEscapePressed: root.leaveRename()
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                visible: renameInput.text === ""
                text: "New name"
                color: root.foreground
                opacity: 0.35
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
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

            Row {
              anchors.horizontalCenter: parent.horizontalCenter
              visible: !root.applying && !root.renameMode
              spacing: Style.space(16)

              Text {
                visible: !root.deleteConfirm
                text: "Rename…"
                color: root.foreground
                opacity: renameArea.containsMouse ? 1 : 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  id: renameArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.enterRename()
                }
              }

              Text {
                text: root.deleteConfirm ? "Confirm delete" : "Delete this binding…"
                color: root.warningColor
                opacity: deleteArea.containsMouse ? 1 : 0.7
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption

                MouseArea {
                  id: deleteArea
                  anchors.fill: parent
                  anchors.margins: -Style.space(4)
                  hoverEnabled: true
                  cursorShape: Qt.PointingHandCursor
                  onClicked: root.deleteConfirm ? root.applyDelete() : root.enterDeleteConfirm()
                }
              }
            }

            Text {
              width: parent.width
              text: root.applying ? "Applying…"
                  : root.deleteConfirm ? "Enter delete · Esc back"
                  : root.renameMode ? "Enter apply · Esc back"
                  : "Enter apply · Esc cancel · Backspace clear · F2 rename · Del delete"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }

      // Reset confirmation popin.
      Rectangle {
        anchors.fill: parent
        visible: root.resetOpen
        color: root.scrim
        radius: root.cornerRadius

        MouseArea { anchors.fill: parent; onClicked: root.closeReset() }

        BorderSurface {
          width: Math.min(Style.space(480), parent.width - Style.space(40))
          height: resetColumn.implicitHeight + Style.space(48)
          radius: root.cornerRadius
          anchors.centerIn: parent
          color: root.background
          borderSpec: root.borderSpec

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: resetColumn
            anchors.centerIn: parent
            width: parent.width - Style.space(48)
            spacing: Style.space(14)

            Text {
              width: parent.width
              text: root.resetRow ? root.resetRow.description : ""
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              elide: Text.ElideMiddle
            }

            Text {
              width: parent.width
              text: root.resetPrompt()
              color: root.foreground
              font.family: root.fontFamily
              font.pixelSize: Style.font.body
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              visible: root.conflictText !== ""
              text: "⚠ " + root.conflictText
              color: root.warningColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              text: root.applying ? "Applying…"
                  : "Enter " + (root.resetKind === "restore" ? "restore" : "reset") + " · Esc cancel"
              color: root.foreground
              opacity: 0.4
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }
          }
        }
      }

      // Add-custom-bind popin: combo capture, then description, then command.
      Rectangle {
        anchors.fill: parent
        visible: root.addOpen
        color: root.scrim
        radius: root.cornerRadius

        MouseArea { anchors.fill: parent; onClicked: root.closeAdd() }

        BorderSurface {
          width: Math.min(Style.space(480), parent.width - Style.space(40))
          height: addColumn.implicitHeight + Style.space(48)
          radius: root.cornerRadius
          anchors.centerIn: parent
          color: root.background
          borderSpec: root.borderSpec

          MouseArea { anchors.fill: parent; onClicked: {} }

          Column {
            id: addColumn
            anchors.centerIn: parent
            width: parent.width - Style.space(48)
            spacing: Style.space(14)

            Text {
              width: parent.width
              text: "Add custom keybinding"
              color: root.foreground
              opacity: 0.55
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
            }

            Text {
              width: parent.width
              text: root.addStage === 0 ? "Press desired key combination and then press ENTER."
                  : root.addStage === 1 ? "Describe what the binding does."
                  : "Enter the command to run."
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
              border.color: root.conflictRow ? root.warningColor
                          : (root.addStage === 0 ? root.selectedBackground : Util.alpha(root.foreground, 0.25))
              border.width: root.addStage === 0 ? 2 : 1

              Text {
                anchors.centerIn: parent
                text: root.capturedRaw()
                    ? KeybindModel.prettyCombo(root.capturedRaw(), root.xkbMap)
                    : (root.pendingMods.length > 0
                        ? KeybindModel.rawCombo(root.pendingMods.map(KeybindModel.prettyMod), "…")
                        : "…")
                color: root.foreground
                opacity: root.capturedRaw() ? 1 : 0.45
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Rectangle {
              visible: root.addStage >= 1
              width: parent.width
              height: Style.space(38)
              radius: root.cornerRadius
              color: "transparent"
              border.color: root.addStage === 1 ? root.selectedBackground : Util.alpha(root.foreground, 0.25)
              border.width: root.addStage === 1 ? 2 : 1

              TextInput {
                id: addDescriptionInput
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                verticalAlignment: TextInput.AlignVCenter
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                clip: true
                onAccepted: root.advanceAdd()
                Keys.onEscapePressed: root.closeAdd()
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                visible: addDescriptionInput.text === ""
                text: "Description, e.g. Screenshot region to clipboard"
                color: root.foreground
                opacity: 0.35
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Rectangle {
              visible: root.addStage >= 2
              width: parent.width
              height: Style.space(38)
              radius: root.cornerRadius
              color: "transparent"
              border.color: root.addStage === 2 ? root.selectedBackground : Util.alpha(root.foreground, 0.25)
              border.width: 2

              TextInput {
                id: addCommandInput
                anchors.fill: parent
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                verticalAlignment: TextInput.AlignVCenter
                color: root.foreground
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
                clip: true
                onAccepted: root.advanceAdd()
                Keys.onEscapePressed: root.closeAdd()
              }

              Text {
                anchors.verticalCenter: parent.verticalCenter
                anchors.left: parent.left
                anchors.leftMargin: Style.space(12)
                visible: addCommandInput.text === ""
                text: "Command, e.g. omarchy capture screenshot region copy"
                color: root.foreground
                opacity: 0.35
                font.family: root.fontFamily
                font.pixelSize: Style.font.body
              }
            }

            Text {
              width: parent.width
              visible: root.conflictText !== ""
              text: "⚠ " + root.conflictText
              color: root.warningColor
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              horizontalAlignment: Text.AlignHCenter
              wrapMode: Text.Wrap
            }

            Text {
              width: parent.width
              text: root.applying ? "Applying…"
                  : (root.addStage === 0 ? "Enter next · Esc cancel · Backspace clear"
                                         : "Enter " + (root.addStage === 2 ? "apply" : "next") + " · Esc cancel")
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
