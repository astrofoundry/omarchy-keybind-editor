#!/bin/bash
# Rewrite ~/.config/hypr/keybind-remaps.lua and keybind-renames.lua for the
# keybind editor plugin, then reload Hyprland so the change takes effect.
#
# Usage: apply-remap.sh <op>... where each op is one of:
#   set <normalized-original> <replacement-combo>   remap a combo
#   delete <normalized-original>                    drop the entry (restore default)
#   disable <normalized-original>                   remove the bind entirely
#                                                   (empty value; the hook skips it)
#   rename <normalized-original> <description>      replace the description
#   unrename <normalized-original>                  drop the rename (stock name)
#
# After a successful apply, fires `omarchy-hook keybind-remap <op>...` with
# the ops it was given, for user automation (backup, auto-commit, ...).
set -euo pipefail

remaps_file="$HOME/.config/hypr/keybind-remaps.lua"
renames_file="$HOME/.config/hypr/keybind-renames.lua"
ops=("$@")

# Parse a managed table file into the named associative array.
read_table() {
  local -n out=$1
  local file=$2 line
  [[ -f $file ]] || return 0
  while IFS= read -r line; do
    if [[ $line =~ ^[[:space:]]*\[\"([^\"]+)\"\][[:space:]]*=[[:space:]]*\"(.*)\",?[[:space:]]*$ ]]; then
      out["${BASH_REMATCH[1]}"]=$(lua_unquote "${BASH_REMATCH[2]}")
    fi
  done <"$file"
}

# Escape for a double-quoted Lua string. Combos cannot produce a quote or
# backslash; descriptions can. Escaping keeps the generated file, which the
# compositor executes, safe by construction rather than by data flow.
lua_quote() {
  local s=${1//\\/\\\\}
  printf '%s' "${s//\"/\\\"}"
}

lua_unquote() {
  local s=${1//\\\"/\"}
  printf '%s' "${s//\\\\/\\}"
}

declare -A remaps=() renames=()
read_table remaps "$remaps_file"
read_table renames "$renames_file"

touch_remaps=0
touch_renames=0
while (( $# )); do
  case $1 in
    set)
      remaps["${2:?set needs an original combo}"]="${3:?set needs a replacement}"
      touch_remaps=1
      shift 3
      ;;
    delete)
      unset "remaps[${2:?delete needs an original combo}]" 2>/dev/null || true
      touch_remaps=1
      shift 2
      ;;
    disable)
      remaps["${2:?disable needs an original combo}"]=""
      touch_remaps=1
      shift 2
      ;;
    rename)
      renames["${2:?rename needs an original combo}"]="${3:?rename needs a description}"
      touch_renames=1
      shift 3
      ;;
    unrename)
      unset "renames[${2:?unrename needs an original combo}]" 2>/dev/null || true
      touch_renames=1
      shift 2
      ;;
    *)
      echo "unknown op: $1" >&2
      exit 2
      ;;
  esac
done

# write_table <file> <array-name> <header-line>...
write_table() {
  local file=$1
  local -n table=$2
  shift 2
  # Resolve symlinks (e.g. into a dotfiles repo) so the rewrite goes through
  # the link instead of replacing it with a regular file.
  local target
  target=$(realpath -m "$file")
  local tmp key
  tmp=$(mktemp "${target}.XXXXXX")
  {
    echo '-- Managed by the Astro Keybind Editor plugin (astrofoundry.keybind-editor).'
    printf '%s\n' "$@"
    echo '-- Applied by ~/.config/hypr/keybind-remap-hook.lua as binds register.'
    echo 'return {'
    while IFS= read -r key; do
      [[ -n $key ]] && printf '  ["%s"] = "%s",\n' "$(lua_quote "$key")" "$(lua_quote "${table[$key]}")"
    done < <(printf '%s\n' "${!table[@]}" | sort)
    echo '}'
  } >"$tmp"
  mv "$tmp" "$target"
}

if (( touch_remaps )); then
  write_table "$remaps_file" remaps \
    '-- Maps an original key combo (normalized) to its replacement.' \
    '-- An empty replacement removes the bind entirely (editor override).'
fi
if (( touch_renames )); then
  write_table "$renames_file" renames \
    '-- Maps an original key combo (normalized) to a replacement description.'
fi

hyprctl reload >/dev/null
errors=$(hyprctl configerrors 2>/dev/null || true)
if [[ -n $errors && ${errors,,} != *"no errors"* ]]; then
  omarchy-notification-send "Astro Keybind Editor" "Hyprland config error: $errors" >/dev/null 2>&1 || true
  echo "$errors" >&2
  exit 1
fi

# Detached and silenced: a slow hook must not block the capture dialog or
# hold the caller's stdout open.
omarchy-hook keybind-remap "${ops[@]}" >/dev/null 2>&1 &

echo OK
