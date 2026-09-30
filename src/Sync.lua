-- Sync: three-way synchronisation of writable settings.
--
-- For every setting the last agreed value (the reference) is stored. A local
-- change (QuickApp variable differs from the reference) is written to the
-- inverter; a change made on the inverter (web UI, app) becomes the new
-- reference and is copied to the variable. If both changed, the inverter wins.

App.Sync = {}
local Sync = App.Sync

local STORE_KEY = "settingRefs"

--- Canonical text of a setting value, so "50", "50.0" and 50 compare equal.
function Sync.normalize(entry, value)
  if value == nil then return nil end
  local text = Util.trim(tostring(value))
  if entry.format == "slots" then return text end
  local number = tonumber(text)
  if not number then return text end
  if number == math.floor(number) then return string.format("%d", math.floor(number)) end
  return (string.format("%.3f", number):gsub("0+$", ""):gsub("%.$", ""))
end

--- Decide what to do. All values are normalized text or nil.
-- Returns "none", "write", "adopt" or "conflict" (= adopt, with a warning).
function Sync.decide(localValue, remoteValue, reference)
  if remoteValue == nil then return "none" end
  if reference == nil then return "adopt" end
  local localChanged = localValue ~= nil and localValue ~= "" and localValue ~= reference
  local remoteChanged = remoteValue ~= reference
  if remoteChanged and localChanged and localValue ~= remoteValue then return "conflict" end
  if remoteChanged then return "adopt" end
  if localChanged then return "write" end
  return "none"
end

--- Validate a value for writing. meta: { type, min, max } from the inverter.
-- Returns the normalized value or nil, reason.
function Sync.validate(entry, value, meta)
  local text = Util.trim(tostring(value or ""))
  if entry.format == "slots" then
    if #text ~= 96 or text:find("[^0-2]") then return nil, "must be 96 digits 0, 1 or 2" end
    return text
  end
  local number = tonumber(text)
  if not number or number ~= number then return nil, "is not a number" end
  meta = meta or {}
  if meta.type and meta.type:find("^u?int") or meta.type == "byte" or meta.type == "bool" then
    if number ~= math.floor(number) then return nil, "must be a whole number" end
  end
  if (meta.min and number < meta.min) or (meta.max and number > meta.max) then
    return nil, "must be between " .. tostring(meta.min or "-") .. " and " .. tostring(meta.max or "-")
  end
  return Sync.normalize(entry, number)
end

function Sync.references()
  return App.Store.get(STORE_KEY)
end

function Sync.saveReferences(references)
  App.Store.set(STORE_KEY, references)
end
