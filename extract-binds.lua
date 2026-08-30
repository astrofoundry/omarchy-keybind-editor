-- Extract the effective keybindings by executing the Hyprland Lua config
-- with a stubbed `hl` API. `hyprctl binds -j` cannot be the source: it
-- reports Lua binds without their key. Because the config loads the keybind
-- remap hook, the combos printed here are post-remap, exactly what Hyprland
-- registers.
--
-- Output TSV, in registration order:
--   BIND<TAB>combo<TAB>description
--   UNBIND<TAB>combo

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

hl.bind = function(keys, dispatcher, opts)
  local description = ""
  if type(opts) == "table" then
    -- Submap-scoped binds (like the editor's own capture submap) are not
    -- part of the global keymap; don't list them.
    if opts.submap ~= nil and opts.submap ~= "" then
      return
    end
    if type(opts.description) == "string" then
      description = opts.description
    end
  end
  io.write("BIND\t", tostring(keys), "\t", (description:gsub("[\t\n]", " ")), "\n")
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
