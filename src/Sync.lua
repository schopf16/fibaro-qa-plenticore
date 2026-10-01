-- Sync: normalising and validating setting values before they are written.

App.Sync = {}
local Sync = App.Sync

local function isFinite(number)
  return number == number and number ~= math.huge and number ~= -math.huge
end

--- Canonical text of a setting value, so "50", "50.0" and 50 compare equal.
function Sync.normalize(entry, value)
  if value == nil then return nil end
  local text = Util.trim(tostring(value))
  if entry.format == "slots" then return text end
  if text == "true" then return "1" end
  if text == "false" then return "0" end
  local number = tonumber(text)
  if not number or not isFinite(number) then return text end
  local integer = math.tointeger(number)
  if integer then return string.format("%d", integer) end
  -- Whole numbers beyond the 64-bit integer range have no integer representation.
  if number == math.floor(number) then return string.format("%.0f", number) end
  return (string.format("%.3f", number):gsub("0+$", ""):gsub("%.$", ""))
end

--- Validate a value for writing. meta: { type, min, max } from the inverter.
-- Returns the normalized value or nil, reason.
function Sync.validate(entry, value, meta)
  local text = Sync.normalize(entry, value) or ""
  if entry.format == "slots" then
    if #text ~= 96 or text:find("[^0-2]") then return nil, "must be 96 digits 0, 1 or 2" end
    return text
  end
  local number = tonumber(text)
  if not number or not isFinite(number) then return nil, "is not a number" end
  meta = meta or {}
  if meta.type and meta.type:find("^u?int") or meta.type == "byte" or meta.type == "bool" then
    if number ~= math.floor(number) then return nil, "must be a whole number" end
  end
  if (meta.min and number < meta.min) or (meta.max and number > meta.max) then
    return nil, "must be between " .. tostring(meta.min or "-") .. " and " .. tostring(meta.max or "-")
  end
  return Sync.normalize(entry, number)
end

--- The value to publish: a number for numbers and switches, text otherwise.
function Sync.publishable(entry, text)
  if text == nil or entry.format == "slots" then return text end
  return tonumber(text) or text
end
