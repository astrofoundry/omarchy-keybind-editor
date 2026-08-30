#!/bin/bash
# Rewrite ~/.config/hypr/keybind-remaps.lua for the keybind editor plugin,
# then reload Hyprland so the remap takes effect.
#
# Usage: apply-remap.sh <op>... where each op is one of:
#   set <normalized-original> <replacement-combo>   remap a combo
#   delete <normalized-original>                    drop the entry (restore default)
#   disable <normalized-original>                   remove the bind entirely
#                                                   (empty value; the hook skips it)
set -euo pipefail

file="$HOME/.config/hypr/keybind-remaps.lua"

declare -A entries=()
if [[ -f $file ]]; then
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*\[\"([^\"]+)\"\][[:space:]]*=[[:space:]]*\"([^\"]*)\" ]]; then
      entries["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}"
    fi
  done <"$file"
fi

while (( $# )); do
  case $1 in
    set)
      entries["${2:?set needs an original combo}"]="${3:?set needs a replacement}"
      shift 3
      ;;
    delete)
      unset "entries[${2:?delete needs an original combo}]" 2>/dev/null || true
      shift 2
      ;;
    disable)
      entries["${2:?disable needs an original combo}"]=""
      shift 2
      ;;
    *)
      echo "unknown op: $1" >&2
      exit 2
      ;;
  esac
done

tmp=$(mktemp "${file}.XXXXXX")
{
  echo '-- Managed by the keybind editor plugin (astrofoundry.keybind-editor).'
  echo '-- Maps an original key combo (normalized) to its replacement.'
  echo '-- An empty replacement removes the bind entirely (editor override).'
  echo '-- Applied by ~/.config/hypr/keybind-remap-hook.lua as binds register.'
  echo 'return {'
  while IFS= read -r key; do
    [[ -n $key ]] && printf '  ["%s"] = "%s",\n' "$key" "${entries[$key]}"
  done < <(printf '%s\n' "${!entries[@]}" | sort)
  echo '}'
} >"$tmp"
mv "$tmp" "$file"

hyprctl reload >/dev/null
errors=$(hyprctl configerrors 2>/dev/null || true)
if [[ -n $errors && ${errors,,} != *"no errors"* ]]; then
  omarchy-notification-send "Keybind editor" "Hyprland config error: $errors" >/dev/null 2>&1 || true
  echo "$errors" >&2
  exit 1
fi
echo OK
