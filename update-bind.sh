#!/bin/bash
# Rewrite the combo of an editor-added o.bind line in ~/.config/hypr/
# bindings.lua in place for the Astro Keybind Editor plugin, then reload
# Hyprland and validate. On a config error the file is restored from backup
# and the reload repeated.
#
# Usage: update-bind.sh <old-combo> <new-combo> [<apply-remap-op>...]
#        update-bind.sh --description <combo> <new-description>
#
# The line is matched by its exact combo plus the editor marker comment, so
# only lines add-bind.sh wrote can be updated. Any extra arguments are passed
# to apply-remap.sh after a successful rewrite: the editor uses this to purge
# a legacy remap entry (delete <n>) and to disable a conflicting bind
# (disable <n>) in the same apply. The --description form rewrites the
# line's description instead of its combo (a custom bind is renamed in
# place; it never enters keybind-renames.lua).
set -euo pipefail

mode=combo
if [[ ${1:-} == --description ]]; then
  mode=description
  shift
fi
old_combo=${1:?update-bind: combo required}
new_value=${2:?update-bind: new ${mode} required}
shift 2

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
file="$HOME/.config/hypr/bindings.lua"
# Resolve symlinks (e.g. into a dotfiles repo) so the rewrite goes through
# the link instead of replacing it with a regular file.
target=$(realpath -m "$file")
[[ -f $target ]] || { echo "update-bind: $file not found" >&2; exit 1; }

backup=$(mktemp "${target}.bak.XXXXXX")
cp "$target" "$backup"

# Escape for a double-quoted Lua string, like add-bind.sh does.
lua_quote() {
  local s=${1//\\/\\\\}
  printf '%s' "${s//\"/\\\"}"
}

# Splice the new combo (or description) into every editor-marker line
# carrying the old combo. index/substr instead of sub(): combos contain
# regex metacharacters (+). The description is the second quoted string;
# scan it by hand so escaped quotes inside it are skipped.
tmp=$(mktemp "${target}.XXXXXX")
# The new value travels through the environment: gawk -v would interpret
# the backslash escapes lua_quote just added.
if ! NEW_VALUE="$(lua_quote "$new_value")" gawk -v old="$old_combo" -v mode="$mode" '
  BEGIN { prefix = "o.bind(\"" old "\","; new = ENVIRON["NEW_VALUE"] }
  {
    s = $0; sub(/^[[:space:]]+/, "", s)
    if (index(s, prefix) == 1 && s ~ /-- added by the Astro Keybind Editor[[:space:]]*$/) {
      at = index($0, prefix)
      if (mode == "combo") {
        $0 = substr($0, 1, at - 1) "o.bind(\"" new "\"," substr($0, at + length(prefix))
        found++
      } else {
        i = at + length(prefix)
        while (substr($0, i, 1) == " ") i++
        if (substr($0, i, 1) == "\"") {
          j = i + 1
          while (j <= length($0)) {
            c = substr($0, j, 1)
            if (c == "\\") { j += 2; continue }
            if (c == "\"") break
            j++
          }
          $0 = substr($0, 1, i) new substr($0, j)
          found++
        }
      }
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
if [[ $mode == combo ]]; then
  omarchy-hook keybind-remap update "$old_combo" "$new_value" >/dev/null 2>&1 &
else
  omarchy-hook keybind-remap rename "$old_combo" "$new_value" >/dev/null 2>&1 &
fi

echo OK
