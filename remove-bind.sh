#!/bin/bash
# Remove an editor-added o.bind line from ~/.config/hypr/bindings.lua for the
# Astro Keybind Editor plugin, then reload Hyprland and validate. On a config
# error the file is restored from backup and the reload repeated.
#
# Usage: remove-bind.sh <combo> <description> <command> [<normalized-original>]
#
# The line is matched by its exact combo plus the editor marker comment, so
# only lines add-bind.sh wrote can be removed; description and command are
# only echoed to the `keybind-remap remove` hook. When the bind was remapped
# after being added, pass its normalized original as the fourth argument so
# the stale entry leaves keybind-remaps.lua too.
set -euo pipefail

combo=${1:?remove-bind: combo required}
description=${2:?remove-bind: description required}
command=${3:?remove-bind: command required}
remap_original=${4:-}

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="$HOME/.config/hypr/bindings.lua"
# Resolve symlinks (e.g. into a dotfiles repo) so the rewrite goes through
# the link instead of replacing it with a regular file.
target=$(realpath -m "$file")
[[ -f $target ]] || { echo "remove-bind: $file not found" >&2; exit 1; }

backup=$(mktemp "${target}.bak.XXXXXX")
cp "$target" "$backup"

# Drop every editor-marker line carrying this exact combo, plus the blank
# line add-bind.sh put before it.
tmp=$(mktemp "${target}.XXXXXX")
if ! gawk -v combo="$combo" '
  function flush() { if (pending) { print blank; pending = 0 } }
  BEGIN { prefix = "o.bind(\"" combo "\"," }
  /^[[:space:]]*$/ { flush(); blank = $0; pending = 1; next }
  {
    s = $0; sub(/^[[:space:]]+/, "", s)
    if (index(s, prefix) == 1 && s ~ /-- added by the Astro Keybind Editor[[:space:]]*$/) {
      found++; pending = 0; next
    }
    flush(); print
  }
  END { flush(); if (!found) exit 3 }
' "$backup" >"$tmp"; then
  rm -f "$tmp" "$backup"
  echo "remove-bind: no editor-added line for combo: $combo" >&2
  exit 1
fi
mv "$tmp" "$target"

hyprctl reload >/dev/null
errors=$(hyprctl configerrors 2>/dev/null || true)
if [[ -n $errors && ${errors,,} != *"no errors"* ]]; then
  mv "$backup" "$target"
  hyprctl reload >/dev/null || true
  omarchy-notification-send "Astro Keybind Editor" "Hyprland config error: $errors" >/dev/null 2>&1 || true
  echo "$errors" >&2
  exit 1
fi
rm -f "$backup"

# A leftover remap entry keyed on this combo would silently re-route any
# future bind with the same combo; drop it. apply-remap.sh reloads again.
if [[ -n $remap_original ]]; then
  "$here/apply-remap.sh" delete "$remap_original" >/dev/null
fi

# Detached and silenced, like the other scripts: never block the dialog.
omarchy-hook keybind-remap remove "$combo" "$description" "$command" >/dev/null 2>&1 &

echo OK
