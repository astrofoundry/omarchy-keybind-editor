#!/bin/bash
# Print "keycode<TAB>SYMBOL" lines used by the keybind editor.
#
# Default mode mirrors the stock omarchy-menu-keybindings rendering: the
# default compiled keymap plus digit-row fallbacks, so combos read the same
# as in the stock menu.
#
# With --active, compiles the active Hyprland layout instead. That map is
# used to canonicalize key names to keycodes: Hyprland resolves keysym binds
# (e.g. RETURN, K) against the active layout, so comparing a captured code:N
# against them needs the active layout's symbol positions.

args=()
if [[ ${1:-} == "--active" ]]; then
  layout=$(hyprctl getoption input:kb_layout -j 2>/dev/null | jq -r '.str // empty')
  variant=$(hyprctl getoption input:kb_variant -j 2>/dev/null | jq -r '.str // empty')
  [[ -n $layout ]] && args+=(--layout "${layout%%,*}")
  [[ -n $variant ]] && args+=(--variant "${variant%%,*}")
fi

{ xkbcli compile-keymap "${args[@]}" </dev/null 2>/dev/null \
    || xkbcli compile-keymap </dev/null 2>/dev/null; } | awk '
  BEGIN {
    split("10=1 11=2 12=3 13=4 14=5 15=6 16=7 17=8 18=9 19=0 20=MINUS 21=EQUAL 59=COMMA 60=PERIOD 61=SLASH", fallbacks, " ")
    for (i in fallbacks) {
      separator = index(fallbacks[i], "=")
      symbol_by_code[substr(fallbacks[i], 1, separator - 1)] = substr(fallbacks[i], separator + 1)
    }
  }
  /xkb_keycodes/ { section = "codes"; next }
  /xkb_symbols/  { section = "syms";  next }
  section == "codes" && match($0, /<([A-Za-z0-9_]+)>[[:space:]]*=[[:space:]]*([0-9]+)[[:space:]]*;/, m) { code[m[1]] = m[2] }
  section == "syms"  && match($0, /key[[:space:]]*<([A-Za-z0-9_]+)>[[:space:]]*\{[[:space:]]*\[[[:space:]]*([^, \]]+)/, m) { sym[m[1]] = m[2] }
  END {
    for (name in code)
      if (sym[name] != "" && sym[name] != "NoSymbol")
        symbol_by_code[code[name]] = toupper(sym[name])
    for (keycode in symbol_by_code)
      print keycode "\t" symbol_by_code[keycode]
  }
'
