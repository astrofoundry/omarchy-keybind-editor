#!/bin/bash
# Install the Hyprland-side remap hook for the keybind editor plugin.
#
# The overlay plugin itself is installed by `omarchy plugin add`; this script
# adds the config-side piece the plugin cannot ship as a shell plugin: a hook
# that must load inside Hyprland's Lua config, before the Omarchy defaults
# register their binds.
#
# What it does:
#   1. Copies hypr/keybind-remap-hook.lua to ~/.config/hypr/.
#   2. Creates ~/.config/hypr/keybind-remaps.lua (the remap table) and
#      ~/.config/hypr/keybind-renames.lua (the rename table) if missing.
#   3. Adds require("hypr.keybind-remap-hook") to hyprland.lua, right before
#      require("default.hypr.omarchy").
#   4. Reloads Hyprland.
set -euo pipefail

hypr_dir="$HOME/.config/hypr"
src_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
main="$hypr_dir/hyprland.lua"
require_line='require("hypr.keybind-remap-hook")'

[[ -f $main ]] || { echo "install: $main not found — is this an Omarchy system?" >&2; exit 1; }

install -m 0644 "$src_dir/hypr/keybind-remap-hook.lua" "$hypr_dir/keybind-remap-hook.lua"

if [[ ! -f $hypr_dir/keybind-remaps.lua ]]; then
  cat >"$hypr_dir/keybind-remaps.lua" <<'EOF'
-- Managed by the Astro Keybind Editor plugin (astrofoundry.keybind-editor).
-- Maps an original key combo (normalized) to its replacement.
-- An empty replacement removes the bind entirely (editor override).
-- Applied by ~/.config/hypr/keybind-remap-hook.lua as binds register.
return {
}
EOF
fi

if [[ ! -f $hypr_dir/keybind-renames.lua ]]; then
  cat >"$hypr_dir/keybind-renames.lua" <<'EOF'
-- Managed by the Astro Keybind Editor plugin (astrofoundry.keybind-editor).
-- Maps an original key combo (normalized) to a replacement description.
-- Applied by ~/.config/hypr/keybind-remap-hook.lua as binds register.
return {
}
EOF
fi

if ! grep -qF "$require_line" "$main"; then
  cp "$main" "$main.bak.keybind-editor"
  if ! awk -v line="$require_line" '
    !done && /require\("default\.hypr\.omarchy"\)/ {
      print "-- Astro Keybind Editor remap layer; must load before the Omarchy defaults."
      print line
      print ""
      done = 1
    }
    { print }
    END { exit done ? 0 : 1 }
  ' "$main" >"$main.tmp"; then
    rm -f "$main.tmp"
    echo "install: could not find require(\"default.hypr.omarchy\") in $main." >&2
    echo "Add this line manually before the Omarchy defaults load: $require_line" >&2
    exit 1
  fi
  mv "$main.tmp" "$main"
fi

hyprctl reload >/dev/null
errors=$(hyprctl configerrors 2>/dev/null || true)
if [[ -n $errors && ${errors,,} != *"no errors"* ]]; then
  echo "install: Hyprland reports config errors:" >&2
  echo "$errors" >&2
  exit 1
fi

cat <<'EOF'
Astro Keybind Editor hook installed.

Open the editor with:
  omarchy-shell shell toggle astrofoundry.keybind-editor

Suggested keybinding (in ~/.config/hypr/bindings.lua):
  hl.unbind("SUPER + K") -- Previously: the read-only keybindings menu.
  o.bind("SUPER + K", "Keybindings", "omarchy-shell shell toggle astrofoundry.keybind-editor")
EOF
