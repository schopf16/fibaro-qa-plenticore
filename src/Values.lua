-- Values: every listed value in one QuickApp variable "values" (JSON), which
-- scenes and other QuickApps read with fibaro.getValue(id, "quickAppVariables").
--
-- The variable is written only when a value changed: by more than its dead
-- band (10 W, 0.01 kWh, 1 %) or to or from zero, or by any amount when the
-- dead band is off.

App.Values = {}
local Values = App.Values

local VARIABLE = "values"

-- Variables of earlier versions that this version no longer uses.
local OBSOLETE  = { pollIntervalSec = true, logLevel = true, language = true }
local MIGRATION = "migration" -- internal storage: migrations already done

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

-- The QuickApp's variable list from the API, or nil.
local function variableList(id)
  local device = api.get("/devices/" .. tostring(id))
  local list   = device and device.properties and device.properties.quickAppVariables
  if type(list) ~= "table" then return nil end
  return list
end

--- Migration from 1.0.0, run once: remove the single-value variables that
-- 1.0.0 created (one per name in readValues and writeValues) and the options
-- that moved into the code. Other variables, also those a user created, are
-- kept. Saving the variable list restarts the QuickApp; returns true if it was
-- saved and the controller kept the change.
function Values.removeObsolete(lists)
  local done = App.Store.get(MIGRATION)
  if done.variables then return false end
  App.Store.set(MIGRATION, { variables = true })

  local list = variableList(qa.id)
  if not list then return false end
  local created = {}
  for _, names in ipairs({ lists.read, lists.write }) do
    for _, name in ipairs(names) do created[name] = true end
  end
  local kept, removed = {}, {}
  for _, variable in ipairs(list) do
    local name = variable.name
    if created[name] or OBSOLETE[name] then
      removed[#removed + 1] = name
    else
      -- The API returns password values masked; restore them from the QuickApp.
      if variable.type == "password" then variable.value = qa:getVariable(name) end
      kept[#kept + 1] = variable
    end
  end
  if #removed == 0 then return false end
  Log.info("Removing variables of version 1.0.0 that are no longer used: %s", Util.join(removed))
  local _, status = api.put("/devices/" .. tostring(qa.id), { properties = { quickAppVariables = kept } })
  if not (math.type(status) == "integer" and status < 300) then
    Log.error("Cannot remove the variables (HTTP %s); remove them by hand", status)
    return false
  end
  -- Restart only if the change was kept, so that it cannot cause a restart loop.
  for _, variable in ipairs(variableList(qa.id) or {}) do
    if created[variable.name] or OBSOLETE[variable.name] then
      Log.error("The controller did not remove the variables; remove them by hand")
      return false
    end
  end
  return true
end
