-- Children: optional child devices for selected values, with stable IDs.
--
-- A child is created exactly once. Its ID is stored in the internal storage
-- and its value name in the child's own variable "key", so it is found again
-- after every restart. Only a change of the list creates or deletes children.
-- A child deleted by hand is left alone while running and recreated at the
-- next start if its value is still listed. Children without a matching key
-- are never touched.

App.Children = {}
local Children = App.Children

local STORE_KEY = "children"

local qa      = nil
local active  = {} -- name -> child object
local missing = {} -- name -> true once reported
local last    = {} -- name -> last value written

local function classMap()
  local map = {}
  for _, entry in ipairs(App.Catalog.ALL) do
    if entry.child then map[entry.child.type] = QuickAppChild end
  end
  return map
end

-- Create a child in the parent's room, with unit and energy panel properties.
local function create(entry, roomID)
  local options = { name = qa.name .. " " .. entry.name, type = entry.child.type }
  local child = qa:createChildDevice(options, QuickAppChild)
  child:setVariable("key", entry.name)
  local properties = {
    unit            = entry.unit,
    rateType        = entry.child.rateType,
    storeEnergyData = entry.child.storeEnergyData or nil,
  }
  api.put("/devices/" .. tostring(child.id), { roomID = roomID, properties = properties })
  return child
end

--- Match children to `names` (list of catalog names). Creates and deletes
-- only what the list requires.
function Children.sync(quickApp, names)
  qa, active, missing, last = quickApp, {}, {}, {}
  qa:initChildDevices(classMap())

  local mapping = App.Store.get(STORE_KEY)
  local byId, byKey = {}, {}
  for id, child in pairs(qa.childDevices or {}) do
    byId[id] = child
    local key = child:getVariable("key")
    if key ~= "" then byKey[key] = child end
  end

  local wanted = {}
  for _, name in ipairs(names) do wanted[name] = true end

  -- Removed from the list: delete our child, found by stored ID or by its key.
  local function remove(name, child)
    local _, status = api.delete("/devices/" .. tostring(child.id))
    if math.type(status) == "integer" and status < 300 then
      byId[child.id] = nil
      Log.info("Deleted child %s for '%s' (removed from childValues)", child.id, name)
    else
      Log.error("Cannot delete child %s for '%s' (HTTP %s)", child.id, name, status)
    end
  end
  for name, id in pairs(mapping) do
    if not wanted[name] then
      if byId[id] then remove(name, byId[id]) end
      mapping[name], byKey[name] = nil, nil
    end
  end
  for key, child in pairs(byKey) do
    if not wanted[key] and App.Catalog.get(key) and byId[child.id] then remove(key, child) end
  end

  local parent = api.get("/devices/" .. tostring(qa.id)) or {}
  for _, name in ipairs(names) do
    local id = mapping[name]
    if id and byId[id] then
      active[name] = byId[id]
    elseif byKey[name] then
      active[name] = byKey[name]
      mapping[name] = byKey[name].id
      Log.info("Adopted existing child %s for '%s'", byKey[name].id, name)
    else
      if id then Log.warn("Child %s for '%s' was deleted; creating a new one", id, name) end
      local ok, child = pcall(create, App.Catalog.get(name), parent.roomID)
      if ok then
        active[name], mapping[name] = child, child.id
        Log.info("Created child %s for '%s'", child.id, name)
      else
        Log.error("Cannot create child for '%s': %s", name, child)
      end
    end
  end

  for id, child in pairs(byId) do
    local key = child:getVariable("key")
    if key == "" or (not wanted[key]) then
      Log.warn("Child %s ('%s') is not managed by this QuickApp and is left unchanged", id, key)
    end
  end
  App.Store.set(STORE_KEY, mapping)
end

--- Update child values. Children deleted while running are reported once.
-- With deadband, a value is written only when it changed by more than its
-- dead band; without, on every change.
function Children.update(values, existingIds, deadband)
  for name, child in pairs(active) do
    if existingIds and not existingIds[child.id] then
      if not missing[name] then
        missing[name] = true
        Log.warn("Child %s for '%s' was deleted; it is recreated at the next start "
          .. "while listed in childValues", child.id, name)
      end
    elseif values[name] ~= nil and (deadband == false and last[name] ~= values[name]
        or deadband ~= false and App.Catalog.changed(App.Catalog.get(name), last[name], values[name])) then
      child:updateProperty("value", values[name])
      last[name] = values[name]
    end
  end
end

--- IDs of the children that still exist on the controller.
function Children.existingIds()
  local ids = {}
  for _, device in ipairs(api.get("/devices?parentId=" .. tostring(qa.id)) or {}) do
    ids[device.id] = true
  end
  return ids
end
