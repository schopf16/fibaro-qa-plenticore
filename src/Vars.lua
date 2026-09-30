-- Vars: publishes values as QuickApp variables, which other scenes and
-- QuickApps read with fibaro.getValue(id, "quickAppVariables").
--
-- Only changed values are written. Variables of catalog values that are no
-- longer listed are removed; configuration variables are never touched.

App.Vars = {}
local Vars = App.Vars

local qa = nil
local published = {} -- name -> last published value
local existing = {}  -- name -> true for variables the QuickApp has

-- The HC3 logs a warning for every getVariable of a missing variable, so the
-- list of existing variables is loaded once and kept up to date.
function Vars.init(quickApp)
  qa, published, existing = quickApp, {}, {}
  local device = api.get("/devices/" .. tostring(qa.id))
  local list = device and device.properties and device.properties.quickAppVariables
  for _, variable in ipairs(type(list) == "table" and list or {}) do existing[variable.name] = true end
end

--- Current text of a QuickApp variable ("" if missing).
function Vars.get(name)
  if not existing[name] then return "" end
  local value = qa:getVariable(name)
  if value == nil then return "" end
  return tostring(value)
end

local function write(name, value)
  qa:setVariable(name, value)
  existing[name] = true
end

--- Publish a value if it changed enough since the last time.
function Vars.publish(entry, value)
  if value == nil then return end
  if not App.Catalog.changed(entry, published[entry.name], value) then return end
  published[entry.name] = value
  if Vars.get(entry.name) ~= tostring(value) then write(entry.name, tostring(value)) end
end

--- Set a variable unconditionally (settings synchronisation).
function Vars.set(name, value)
  published[name] = nil
  if Vars.get(name) ~= tostring(value) then write(name, tostring(value)) end
end

--- Remove variables of catalog values that are not in `keep` (name -> true).
function Vars.removeUnlisted(keep)
  local device = api.get("/devices/" .. tostring(qa.id))
  local list = device and device.properties and device.properties.quickAppVariables
  if type(list) ~= "table" then return end
  local kept, removed = {}, {}
  for _, variable in ipairs(list) do
    local name = variable.name
    if App.Catalog.get(name) and not keep[name] then
      removed[#removed + 1] = name
      existing[name] = nil
    else
      -- The API returns password values masked; restore them from the QuickApp.
      if variable.type == "password" then variable.value = qa:getVariable(name) end
      kept[#kept + 1] = variable
    end
  end
  if #removed == 0 then return end
  -- Saving the variable list restarts the QuickApp, so log first.
  Log.info("Removing variables no longer listed: %s", Util.join(removed))
  api.put("/devices/" .. tostring(qa.id), { properties = { quickAppVariables = kept } })
end
