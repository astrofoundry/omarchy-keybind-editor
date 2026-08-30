# Keybind Editor

An [Omarchy](https://omarchy.org) shell plugin that turns the keybindings
viewer into an editor. It lists every effective Hyprland binding with a
**Change** button; press the new combination in a VS Code-style capture
dialog and the rebind applies immediately — no config editing, no reload.

- Works on **any** binding, including Omarchy defaults, without knowing what
  the binding does.
- Conflicts show in orange; applying anyway removes the combo from the
  action that held it.
- Rebinds are stored in one plain file, `~/.config/hypr/keybind-remaps.lua`,
  easy to review, version, or copy to another machine.
- Capturing a binding's original combo restores the default.
- The stock read-only menu stays available via `omarchy menu keybindings`.

![Keybindings list — every binding gets a Change button; rebound entries are marked "changed"](screenshots/list.png)

![Capture dialog — press the new combination, Enter applies](screenshots/capture.png)

![Conflict — the combo is taken; Enter overrides and unbinds it from the other action](screenshots/conflict.png)

## Install

```bash
omarchy plugin add https://github.com/astrofoundry/omarchy-keybind-editor.git --enable
bash ~/.config/omarchy/plugins/astrofoundry.keybind-editor/install.sh
```

The second step installs the config-side hook (see *How it works*) and is
idempotent. Then bind a key to the editor, e.g. in
`~/.config/hypr/bindings.lua`:

```lua
hl.unbind("SUPER + K") -- Previously: the read-only keybindings menu.
o.bind("SUPER + K", "Keybindings", "omarchy-shell shell toggle astrofoundry.keybind-editor")
```

## Usage

- Type to search; arrows to navigate.
- **Enter** or the **Change** button opens the capture dialog for a row.
- Press the new combination, then **Enter** to apply. **Backspace** clears,
  **Esc** cancels.
- An orange warning means the combo is taken; **Enter** overrides and unbinds
  it from the other action.
- To restore a binding's default, capture its original combination.
- To restore an overridden (removed) binding, delete its empty-value line in
  `~/.config/hypr/keybind-remaps.lua`.

## How it works

Hyprland reports Lua-registered binds without a recoverable action, so
editing binds by rewriting actions is a dead end. Instead, every binding —
default or personal — passes through `hl.bind` when the config loads. The
`install.sh` step adds a small hook, loaded before the Omarchy defaults,
that wraps `hl.bind`/`hl.unbind` and rewrites combos according to
`~/.config/hypr/keybind-remaps.lua`. A remap moves a binding without
touching its action; an empty remap removes it.

The overlay lists binds by re-executing the Hyprland Lua config with a
stubbed API (the same technique the stock menu uses), so the list always
matches what Hyprland registered, remaps included.

## Files

| File | Role |
|---|---|
| `KeybindEditor.qml` | Overlay UI and capture dialog |
| `KeybindModel.js` | Parsing, normalization, ordering, conflict logic |
| `extract-binds.lua` | Lists effective binds from the Lua config |
| `apply-remap.sh` | Rewrites the remap table, reloads Hyprland |
| `xkb-symbols.sh` | Keycode/name maps for display and comparison |
| `hypr/keybind-remap-hook.lua` | The remap layer, installed by `install.sh` |

## Uninstall

```bash
omarchy plugin remove astrofoundry.keybind-editor
```

Then remove the `require("hypr.keybind-remap-hook")` line from
`~/.config/hypr/hyprland.lua` and delete
`~/.config/hypr/keybind-remap-hook.lua`. Keep or delete
`~/.config/hypr/keybind-remaps.lua`; without the hook it has no effect.

## Requirements

Stock Omarchy (Hyprland Lua config, omarchy-shell, `lua`, `jq`, `gawk`,
`xkbcli`).
