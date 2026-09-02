-- Extract the effective keybindings by executing the Hyprland Lua config
-- with a stubbed `hl` API. `hyprctl binds -j` cannot be the source: it
-- reports Lua binds without their key. Because the config loads the keybind
-- remap hook, the combos printed here are post-remap, exactly what Hyprland
-- registers.
--
-- Output TSV, in registration order:
--   BIND<TAB>combo<TAB>description[<TAB>original description]
--   UNBIND<TAB>combo
--   REMOVED<TAB>combo<TAB>description
--
-- The fourth BIND column is present when the remap hook renamed the bind
-- (the stock description, used to keep the row at its stock position).
-- REMOVED lines are binds the hook dropped because the editor removed them;
-- the hook reports them through _G.__keybind_editor_on_removed.

local stub
stub = setmetatable({}, {
  __index = function() return stub end,
  __call = function() return stub end,
  __tostring = function() return "" end,
  __concat = function(a, b)
    local left = type(a) == "table" and "" or tostring(a)
    local right = type(b) == "table" and "" or tostring(b)
    return left .. right
  end,
})

hl = setmetatable({}, { __index = function() return stub end })

local function clean(text)
  return (tostring(text):gsub("[\t\n]", " "))
end

-- Description of a bind, or nil for submap-scoped binds (like the editor's
-- own capture submap), which are not part of the global keymap.
local function description_of(opts)
  local description = ""
  if type(opts) == "table" then
    if opts.submap ~= nil and opts.submap ~= "" then
      return nil
    end
    if type(opts.description) == "string" then
      description = opts.description
    end
  end
  return description
end

hl.bind = function(keys, dispatcher, opts)
  local description = description_of(opts)
  if description == nil then
    return
  end
  local original = _G.__keybind_editor_original_description
  if type(original) == "string" then
    io.write("BIND\t", tostring(keys), "\t", clean(description), "\t", clean(original), "\n")
  else
    io.write("BIND\t", tostring(keys), "\t", clean(description), "\n")
  end
end

_G.__keybind_editor_on_removed = function(keys, opts)
  local description = description_of(opts)
  if description == nil then
    return
  end
  io.write("REMOVED\t", tostring(keys), "\t", clean(description), "\n")
end

hl.unbind = function(keys)
  io.write("UNBIND\t", tostring(keys), "\n")
end

local home = os.getenv("HOME") or ""
local ok, err = pcall(dofile, home .. "/.config/hypr/hyprland.lua")
if not ok then
  io.stderr:write("extract-binds: " .. tostring(err) .. "\n")
  os.exit(1)
end
