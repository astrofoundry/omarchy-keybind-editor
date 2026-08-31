#!/bin/bash
# Rewrite the combo of an editor-added o.bind line in ~/.config/hypr/
# bindings.lua in place for the Astro Keybind Editor plugin, then reload
# Hyprland and validate. On a config error the file is restored from backup
# and the reload repeated.
#
# Usage: update-bind.sh <old-combo> <new-combo> [<apply-remap-op>...]
#
# The line is matched by its exact combo plus the editor marker comment, so
# only lines add-bind.sh wrote can be updated. Any extra arguments are passed
# to apply-remap.sh after a successful rewrite: the editor uses this to purge
# a legacy remap entry (delete <n>) and to disable a conflicting bind
# (disable <n>) in the same apply.
set -euo pipefail

old_combo=${1:?update-bind: old combo required}
new_combo=${2:?update-bind: new combo required}
shift 2

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="$HOME/.config/hypr/bindings.lua"
# Resolve symlinks (e.g. into a dotfiles repo) so the rewrite goes through
# the link instead of replacing it with a regular file.
target=$(realpath -m "$file")
[[ -f $target ]] || { echo "update-bind: $file not found" >&2; exit 1; }

backup=$(mktemp "${target}.bak.XXXXXX")
cp "$target" "$backup"

# Splice the new combo into every editor-marker line carrying the old one.
# index/substr instead of sub(): combos contain regex metacharacters (+).
tmp=$(mktemp "${target}.XXXXXX")
if ! gawk -v old="$old_combo" -v new="$new_combo" '
  BEGIN { prefix = "o.bind(\"" old "\"," }
  {
    s = $0; sub(/^[[:space:]]+/, "", s)
    if (index(s, prefix) == 1 && s ~ /-- added by the Astro Keybind Editor[[:space:]]*$/) {
      at = index($0, prefix)
      $0 = substr($0, 1, at - 1) "o.bind(\"" new "\"," substr($0, at + length(prefix))
      found++
    }
    print
  }
  END { if (!found) exit 3 }
' "$backup" >"$tmp"; then
  rm -f "$tmp" "$backup"
  echo "update-bind: no editor-added line for combo: $old_combo" >&2
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

if (( $# )); then
  "$here/apply-remap.sh" "$@" >/dev/null
fi

# Detached and silenced, like the other scripts: never block the dialog.
omarchy-hook keybind-remap update "$old_combo" "$new_combo" >/dev/null 2>&1 &

echo OK
