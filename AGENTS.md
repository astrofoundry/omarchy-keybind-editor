# Repository guide

Omarchy shell plugin: an overlay that lists all Hyprland keybindings and
rebinds any of them interactively. See README.md for user-facing docs and
the architecture summary.

## Layout

The repo root IS the plugin: `omarchy plugin add` clones it verbatim into
`~/.config/omarchy/plugins/astrofoundry.keybind-editor/`. Everything at the
root ships to users. `hypr/keybind-remap-hook.lua` is not loaded from here —
`install.sh` copies it into `~/.config/hypr/`, where Hyprland loads it.

## Invariants

- `main` is the release channel: `omarchy plugin update` fast-forwards users
  to its tip. Keep `main` always releasable; develop on branches.
- NEVER force-push or rebase `main` — the updater refuses non-fast-forward
  pulls, so a rewrite breaks updates for every installed copy.
- `normalize()` exists twice — `KeybindModel.js` and
  `hypr/keybind-remap-hook.lua` — and the two MUST stay identical in
  behavior. Change them together.
- A change to `hypr/keybind-remap-hook.lua` does NOT reach users through
  `plugin update`; they must re-run `install.sh`. Say so in the release
  notes. `release.sh` warns when this applies.

## Releasing

Commit the work first, then run:

```bash
./release.sh patch   # or minor / major
```

The script verifies a clean tree on an up-to-date `main`, validates the
plugin, bumps `version` in `manifest.json` as its own commit, tags
`v<version>`, and pushes branch and tag. Tag every release; never move a
published tag.

Semver: patch = fix, minor = feature, major = breaking or anything that
needs user action (e.g. re-running `install.sh`).

## Developing locally

- Edit the repo clone, not the installed copy. To test: push to a branch is
  unnecessary — `git -C ~/.config/omarchy/plugins/astrofoundry.keybind-editor pull <repo-clone> <branch>`
  or temporarily rsync the files over, then reload.
- QML hot-reloads on save under the installed plugin directory.
  `KeybindModel.js` does NOT — the shell caches JS libraries; run
  `omarchy restart shell` after changing it.
- Hook changes: copy to `~/.config/hypr/keybind-remap-hook.lua` and
  `hyprctl reload`, then check `hyprctl configerrors`. Hyprland's Lua treats
  for-loop variables as const.
- Headless smoke test:
  `omarchy-shell shell summon astrofoundry.keybind-editor '{}'`, check
  `hyprctl layers` for the `omarchy-keybind-editor` namespace, then
  `omarchy-shell shell hide astrofoundry.keybind-editor`. Errors appear in
  `journalctl --user -t omarchy-shell`.
