#!/bin/bash
# Append a custom o.bind line to ~/.config/hypr/bindings.lua for the
# Astro Keybind Editor plugin, then reload Hyprland and validate. On a
# config error the file is restored from backup and the reload repeated.
#
# Usage: add-bind.sh <combo> <description> <command>
#
# After a successful apply, fires `omarchy-hook keybind-remap add <args>`
# like apply-remap.sh does for remaps.
set -euo pipefail

combo=${1:?add-bind: combo required}
description=${2:?add-bind: description required}
command=${3:?add-bind: command required}

file="$HOME/.config/hypr/bindings.lua"
# Resolve symlinks (e.g. into a dotfiles repo) so the append goes through
# the link instead of a copy diverging from it.
target=$(realpath -m "$file")
[[ -f $target ]] || { echo "add-bind: $file not found" >&2; exit 1; }

# Escape for a double-quoted Lua string. Inputs are single-line (the
# dialog's text fields cannot produce newlines).
lua_quote() {
  local s=${1//\\/\\\\}
  printf '%s' "${s//\"/\\\"}"
}

backup=$(mktemp "${target}.bak.XXXXXX")
cp "$target" "$backup"

printf '\no.bind("%s", "%s", "%s") -- added by the Astro Keybind Editor\n' \
  "$(lua_quote "$combo")" "$(lua_quote "$description")" "$(lua_quote "$command")" >>"$target"

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

# Detached and silenced, like the remap hook: never block the dialog.
omarchy-hook keybind-remap add "$combo" "$description" "$command" >/dev/null 2>&1 &

echo OK
