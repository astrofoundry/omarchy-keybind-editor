-- Remap layer for the keybind editor plugin (astrofoundry.keybind-editor).
-- Loaded from hyprland.lua BEFORE the Omarchy defaults, it wraps hl.bind and
-- hl.unbind so any bind — default or personal — can be moved to another key
-- by combo alone, without knowing its action. The combo table lives in
-- hypr/keybind-remaps.lua, written by the plugin. A second table,
-- hypr/keybind-renames.lua, replaces a bind's description the same way.
--
-- normalize() must stay in sync with the plugin's KeybindModel.js.
--
-- Two optional globals let the plugin's extract-binds.lua see through the
-- layer when it replays the config with a stubbed hl; Hyprland never
-- defines them:
--   _G.__keybind_editor_on_removed(keys, opts)  called for a dropped bind
--   _G.__keybind_editor_original_description    set around a renamed bind

local MOD_ALIAS = {
  WIN = "SUPER", META = "SUPER", MOD4 = "SUPER", LOGO = "SUPER",
  CONTROL = "CTRL", MOD1 = "ALT", ALTGR = "MOD5",
}
local MOD_ORDER = { SUPER = 1, CTRL = 2, ALT = 3, SHIFT = 4, MOD2 = 5, MOD3 = 6, MOD5 = 7, CAPS = 8 }

local function normalize(combo)
  local mods, key = {}, ""
  for raw_token in tostring(combo):gmatch("[^+]+") do
    local token = raw_token:match("^%s*(.-)%s*$"):upper()
    if token ~= "" then
      token = MOD_ALIAS[token] or token
      if MOD_ORDER[token] then
        table.insert(mods, token)
      else
        key = token
      end
    end
  end
  table.sort(mods, function(a, b)
    return MOD_ORDER[a] < MOD_ORDER[b]
  end)
  table.insert(mods, key)
  return table.concat(mods, "+")
end

-- Register the capture submap: the editor parks Hyprland here while its
-- capture dialog is open, so no global bind fires while pressing a combo.
-- A submap only exists once a bind is registered in it; Escape doubles as a
-- compositor-level escape hatch if the shell ever dies mid-capture.
pcall(function()
  hl.define_submap("keybind-capture", function()
    hl.bind("ESCAPE", hl.dsp.submap("reset"), { description = "Exit keybind capture" })
  end)
end)

-- Refresh the table on every config reload (bootstrap.lua clears hypr.*
-- modules from package.loaded, so the require re-reads the file).
local ok, remaps = pcall(require, "hypr.keybind-remaps")
if not ok or type(remaps) ~= "table" then
  remaps = {}
end

local normalized = {}
for original, replacement in pairs(remaps) do
  normalized[normalize(original)] = replacement
end
_G.__keybind_editor_remaps = normalized

local ok_renames, renames = pcall(require, "hypr.keybind-renames")
if not ok_renames or type(renames) ~= "table" then
  renames = {}
end

local normalized_renames = {}
for original, description in pairs(renames) do
  normalized_renames[normalize(original)] = description
end
_G.__keybind_editor_renames = normalized_renames

-- Wrap only once per Lua state; the wrappers read the refreshed global.
local already_hooked = false
pcall(function()
  already_hooked = hl.__keybind_editor_hooked == true
end)

if not already_hooked and not _G.__keybind_editor_hooked then
  if not pcall(function() hl.__keybind_editor_hooked = true end) then
    _G.__keybind_editor_hooked = true
  end

  -- An empty replacement means the bind was overridden away in the editor:
  -- drop the registration entirely instead of remapping it. A rename swaps
  -- the description on a copy of opts, keyed by the ORIGINAL combo like the
  -- remap, so renaming survives a later rebind of the same action.
  local original_bind = hl.bind
  hl.bind = function(keys, dispatcher, opts)
    if type(keys) ~= "string" then
      return original_bind(keys, dispatcher, opts)
    end
    local key = normalize(keys)
    local target = _G.__keybind_editor_remaps[key]
    if target == "" then
      local on_removed = _G.__keybind_editor_on_removed
      if type(on_removed) == "function" then
        on_removed(keys, opts)
      end
      return
    end
    if target then
      keys = target
    end
    local renamed = _G.__keybind_editor_renames[key]
    if renamed == nil then
      return original_bind(keys, dispatcher, opts)
    end
    local copy = {}
    if type(opts) == "table" then
      for k, v in pairs(opts) do
        copy[k] = v
      end
    end
    _G.__keybind_editor_original_description = copy.description or ""
    copy.description = renamed
    local result = original_bind(keys, dispatcher, copy)
    _G.__keybind_editor_original_description = nil
    return result
  end

  local original_unbind = hl.unbind
  hl.unbind = function(keys)
    if type(keys) == "string" then
      local target = _G.__keybind_editor_remaps[normalize(keys)]
      if target == "" then
        return
      end
      if target then
        keys = target
      end
    end
    return original_unbind(keys)
  end
end
