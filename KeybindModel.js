// Shared logic for the keybind editor overlay.
//
// Combos are compared through normalize(): uppercase tokens, modifiers in a
// canonical order, joined with "+". The Lua remap hook
// (~/.config/hypr/keybind-remap-hook.lua) normalizes the same way — the two
// implementations must stay in sync.

.pragma library

var MOD_ALIAS = {
  WIN: "SUPER", META: "SUPER", MOD4: "SUPER", LOGO: "SUPER",
  CONTROL: "CTRL", MOD1: "ALT", ALTGR: "MOD5"
}
var MOD_ORDER = { SUPER: 1, CTRL: 2, ALT: 3, SHIFT: 4, MOD2: 5, MOD3: 6, MOD5: 7, CAPS: 8 }
var MOD_PRETTY = { SUPER: "Super", CTRL: "Ctrl", ALT: "Alt", SHIFT: "Shift", MOD2: "Mod2", MOD3: "Mod3", MOD5: "AltGr", CAPS: "Caps" }

function normalize(combo) {
  var mods = []
  var key = ""
  var tokens = String(combo).split("+")
  for (var i = 0; i < tokens.length; i++) {
    var token = tokens[i].trim().toUpperCase()
    if (!token) continue
    token = MOD_ALIAS[token] || token
    if (MOD_ORDER[token]) mods.push(token)
    else key = token
  }
  mods.sort(function(a, b) { return MOD_ORDER[a] - MOD_ORDER[b] })
  mods.push(key)
  return mods.join("+")
}

// Raw combo string in the style used in bindings.lua: "SUPER + SHIFT + code:45".
function rawCombo(modTokens, keyToken) {
  return modTokens.concat([keyToken]).join(" + ")
}

// Media keys arrive as raw XF86 keysym names; show them as words. Display
// only: matching and normalize() still use the raw name.
var XF86_PRETTY = {
  AudioRaiseVolume: "Volume Up", AudioLowerVolume: "Volume Down",
  AudioMute: "Mute", AudioMicMute: "Mic Mute",
  AudioPlay: "Play", AudioPause: "Pause",
  AudioNext: "Next Track", AudioPrev: "Previous Track", AudioStop: "Stop",
  MonBrightnessUp: "Brightness Up", MonBrightnessDown: "Brightness Down",
  KbdBrightnessUp: "Kbd Brightness Up", KbdBrightnessDown: "Kbd Brightness Down",
  KbdLightOnOff: "Kbd Light"
}

function prettyKey(keyToken, xkbMap) {
  if (keyToken.toLowerCase().indexOf("code:") === 0) {
    var code = keyToken.slice(5)
    var symbol = xkbMap[code]
    if (symbol) return symbol
  }
  if (keyToken.indexOf("XF86") === 0) {
    var name = keyToken.slice(4)
    return XF86_PRETTY[name] || name.replace(/([a-z0-9])([A-Z])/g, "$1 $2")
  }
  return keyToken
}

function prettyMod(token) {
  return MOD_PRETTY[token] || token
}

// Pretty form of a source combo string: "SUPER + SHIFT + code:25" -> "Super + Shift + É".
function prettyCombo(combo, xkbMap) {
  var mods = []
  var key = ""
  var tokens = String(combo).split("+")
  for (var i = 0; i < tokens.length; i++) {
    var token = tokens[i].trim()
    var upper = MOD_ALIAS[token.toUpperCase()] || token.toUpperCase()
    if (MOD_ORDER[upper]) mods.push(MOD_PRETTY[upper])
    else key = token
  }
  mods.push(prettyKey(key, xkbMap))
  return mods.join(" + ")
}

// Sort priorities ported from omarchy-menu-keybindings' prioritize_entries,
// so the list reads in the same order as the stock Super+K menu. Rules run
// in order; the last matching rule wins, exactly like the awk original.
// Matched against "MODS + KEY → description" in stock formatting.
var PRIORITY_RULES = [
  [/Keybindings/, 0], [/Omarchy menu/, 1], [/Terminal/, 2],
  [/Browser/, 3, function(line) { return !/Browser\s*\(/.test(line) && !/SUPER SHIFT.*\+.*B.*→.*Browser/.test(line) }],
  [/File manager/, 4, function(line) { return !/File manager \(cwd\)/.test(line) }],
  [/Launch apps/, 5], [/System menu/, 6], [/Theme menu/, 7],
  [/Full screen/, 8], [/Full width/, 9], [/Close window/, 10],
  [/Close all windows/, 11], [/Lock system/, 12], [/Toggle window floating/, 13],
  [/Toggle window split/, 14], [/Pop window/, 15], [/Universal/, 16],
  [/Clipboard/, 17], [/Audio controls/, 18], [/Bluetooth controls/, 19],
  [/Wifi controls/, 20], [/Emojis/, 21], [/Color picker/, 22],
  [/Screenshot/, 23], [/Screenrecording/, 24], [/Tmux/, 25], [/Herdr/, 26],
  [/SUPER SHIFT.*\+.*B.*→.*Browser/, 27], [/File manager \(cwd\)/, 28],
  [/(Switch|Next|Former|Previous).*workspace/, 29], [/Move window to workspace/, 30],
  [/Move window silently to workspace/, 31], [/Swap window/, 32], [/Focus/, 33],
  [/Move window$/, 34], [/Resize window/, 35], [/Expand window/, 36],
  [/Shrink window/, 37], [/scratchpad/, 38], [/notification/, 39],
  [/Toggle window transparency/, 40], [/Toggle workspace gaps/, 41],
  [/Toggle nightlight/, 42], [/Toggle locking/, 43],
  [/group/, 94], [/Scroll active workspace/, 95], [/Cycle to/, 96],
  [/Reveal active/, 97], [/Apple Display/, 98], [/XF86/, 99],
  [/Tmux keybindings/, 100], [/Herdr keybindings/, 101]
]

function priorityFor(line) {
  var prio = 50
  for (var i = 0; i < PRIORITY_RULES.length; i++) {
    var rule = PRIORITY_RULES[i]
    if (rule[0].test(line) && (!rule[2] || rule[2](line))) prio = rule[1]
  }
  return prio
}

// Stock-format line ("SUPER SHIFT + K → description") used for priority
// matching and as the secondary sort key, mirroring the original menu.
function stockLine(combo, keyPretty, description) {
  var mods = []
  var tokens = String(combo).split("+")
  for (var i = 0; i < tokens.length; i++) {
    var token = tokens[i].trim().toUpperCase()
    var alias = MOD_ALIAS[token] || token
    if (MOD_ORDER[alias]) mods.push(alias)
  }
  var comboText = (mods.length ? mods.join(" ") + " + " : "") + keyPretty.toUpperCase()
  return comboText + " → " + description
}

// Rows from extract-binds.lua TSV, in registration order. UNBIND lines remove
// earlier matching combos. Deduplicated by normalized combo (press and
// release variants of the same combo move together, so they share a row).
// Sorted by the stock menu's priorities.
function buildRows(tsv, xkbMap) {
  var sequence = []
  var lines = String(tsv).split("\n")
  for (var i = 0; i < lines.length; i++) {
    var parts = lines[i].split("\t")
    if (parts[0] === "BIND" && parts[1]) {
      sequence.push({ combo: parts[1], normalized: normalize(parts[1]), description: parts[2] || "" })
    } else if (parts[0] === "UNBIND" && parts[1]) {
      var normalized = normalize(parts[1])
      sequence = sequence.filter(function(entry) { return entry.normalized !== normalized })
    }
  }

  var byCombo = {}
  var order = []
  for (var j = 0; j < sequence.length; j++) {
    var bind = sequence[j]
    // The Copilot key duplicates an existing binding; the stock menu hides it too.
    if (bind.normalized.indexOf("CODE:201") !== -1) continue
    if (byCombo[bind.normalized]) {
      var row = byCombo[bind.normalized]
      if (bind.description && row.description.indexOf(bind.description) === -1)
        row.description += " / " + bind.description
      continue
    }
    var entry = {
      normalized: bind.normalized,
      combo: bind.combo,
      comboPretty: prettyCombo(bind.combo, xkbMap),
      description: bind.description
    }
    byCombo[bind.normalized] = entry
    order.push(entry)
  }

  for (var k = 0; k < order.length; k++) {
    var item = order[k]
    var line = stockLine(item.combo, prettyKey(String(item.combo).split("+").pop().trim(), xkbMap), item.description)
    item.sortLine = line
    item.priority = priorityFor(line)
  }
  order.sort(function(a, b) {
    if (a.priority !== b.priority) return a.priority - b.priority
    return a.sortLine < b.sortLine ? -1 : (a.sortLine > b.sortLine ? 1 : 0)
  })
  return order
}

// Qt key names for non-printable keys shown as capture chips.
function qtKeyName(key) {
  var names = {}
  names[Qt.Key_Escape] = "Escape"; names[Qt.Key_Tab] = "Tab"; names[Qt.Key_Backtab] = "Tab"
  names[Qt.Key_Backspace] = "Backspace"; names[Qt.Key_Return] = "Enter"; names[Qt.Key_Enter] = "Enter"
  names[Qt.Key_Insert] = "Insert"; names[Qt.Key_Delete] = "Delete"; names[Qt.Key_Pause] = "Pause"
  names[Qt.Key_Print] = "Print"; names[Qt.Key_Home] = "Home"; names[Qt.Key_End] = "End"
  names[Qt.Key_Left] = "Left"; names[Qt.Key_Up] = "Up"; names[Qt.Key_Right] = "Right"; names[Qt.Key_Down] = "Down"
  names[Qt.Key_PageUp] = "PageUp"; names[Qt.Key_PageDown] = "PageDown"; names[Qt.Key_Space] = "Space"
  names[Qt.Key_Menu] = "Menu"
  if (names[key]) return names[key]
  if (key >= Qt.Key_F1 && key <= Qt.Key_F35) return "F" + (key - Qt.Key_F1 + 1)
  return ""
}

function isModifierKey(key) {
  return key === Qt.Key_Shift || key === Qt.Key_Control || key === Qt.Key_Meta
    || key === Qt.Key_Alt || key === Qt.Key_AltGr || key === Qt.Key_Super_L
    || key === Qt.Key_Super_R || key === Qt.Key_Hyper_L || key === Qt.Key_Hyper_R
    || key === Qt.Key_CapsLock || key === Qt.Key_NumLock || key === Qt.Key_Mode_switch
}

function modTokensFromQt(modifiers) {
  var out = []
  if (modifiers & Qt.MetaModifier) out.push("SUPER")
  if (modifiers & Qt.ControlModifier) out.push("CTRL")
  if (modifiers & Qt.AltModifier) out.push("ALT")
  if (modifiers & Qt.ShiftModifier) out.push("SHIFT")
  if (modifiers & Qt.GroupSwitchModifier) out.push("MOD5")
  return out
}

// Token contributed by a modifier key itself (Qt.modifiers excludes the key
// being pressed on some platforms).
function modTokenOfKey(key) {
  if (key === Qt.Key_Shift) return "SHIFT"
  if (key === Qt.Key_Control) return "CTRL"
  if (key === Qt.Key_Alt) return "ALT"
  if (key === Qt.Key_Meta || key === Qt.Key_Super_L || key === Qt.Key_Super_R) return "SUPER"
  if (key === Qt.Key_AltGr || key === Qt.Key_Mode_switch) return "MOD5"
  return ""
}

// Canonicalize a normalized combo's key to code form using the ACTIVE
// layout's symbol->keycode map, so "CTRL+SHIFT+RETURN" and
// "CTRL+SHIFT+CODE:36" compare equal. Hyprland resolves keysym binds against
// the active layout, so this is the correct equivalence.
function canonicalCombo(normalized, symToCode) {
  var tokens = String(normalized).split("+")
  var key = tokens.pop()
  if (key.indexOf("CODE:") !== 0 && symToCode[key])
    key = "CODE:" + symToCode[key]
  tokens.push(key)
  return tokens.join("+")
}

// Parse the managed keybind-remaps.lua text into { original: replacementRaw }.
function parseRemaps(text) {
  var out = {}
  var re = /\["([^"]+)"\]\s*=\s*"([^"]*)"/g
  var m
  while ((m = re.exec(text)) !== null) out[m[1]] = m[2]
  return out
}
