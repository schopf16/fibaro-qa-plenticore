-- Values: every listed value in one QuickApp variable "values" (JSON), which
-- scenes and other QuickApps read with fibaro.getValue(id, "quickAppVariables").
--
-- The variable is written only when a value changed: by more than its dead
-- band (10 W, 0.01 kWh, 1 %), or by any amount when the dead band is off.

App.Values = {}
local Values = App.Values

local VARIABLE = "values"

-- Variables of earlier versions that this version no longer uses.
local OBSOLETE = { pollIntervalSec = true, logLevel = true, language = true }

local qa       = nil
local deadband = true
local current  = {} -- name -> value
local written  = {} -- name -> value in the variable

function Values.init(quickApp, useDeadband)
  qa, deadband, current, written = quickApp, useDeadband, {}, {}
end

function Values.set(entry, value)
  if value ~= nil then current[entry.name] = value end
end

function Values.get(name)
  return current[name]
end

local function changed(name)
  local old, new = written[name], current[name]
  if deadband then return App.Catalog.changed(App.Catalog.get(name), old, new) end
  return old ~= new
end

--- Write the variable if any value changed enough since the last write.
function Values.flush()
  local any = false
  for name in pairs(current) do
    if changed(name) then
      any = true
      break
    end
  end
  if not any then return end
  for name, value in pairs(current) do written[name] = value end
  qa:setVariable(VARIABLE, json.encode(current))
end

--- Remove the single-value variables of version 1.0.0 and the options that
-- moved into the code. Saving the variable list restarts the QuickApp.
-- Returns true if variables were removed.
function Values.removeObsolete()
  local device = api.get("/devices/" .. tostring(qa.id))
  local list   = device and device.properties and device.properties.quickAppVariables
  if type(list) ~= "table" then return false end
  local kept, removed = {}, {}
  for _, variable in ipairs(list) do
    local name = variable.name
    if App.Catalog.get(name) or OBSOLETE[name] then
      removed[#removed + 1] = name
    else
      -- The API returns password values masked; restore them from the QuickApp.
      if variable.type == "password" then variable.value = qa:getVariable(name) end
      kept[#kept + 1] = variable
    end
  end
  if #removed == 0 then return false end
  Log.info("Removing variables that are no longer used: %s", Util.join(removed))
  local _, status = api.put("/devices/" .. tostring(qa.id), { properties = { quickAppVariables = kept } })
  if math.type(status) == "integer" and status < 300 then return true end
  Log.error("Cannot remove the variables (HTTP %s)", status)
  return false
end
