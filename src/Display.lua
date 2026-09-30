-- Display: one line per listed value in the QuickApp's user interface, with
-- the name in the selected language and the unit. The HC3 shows a label on a
-- single line, so every value has its own label row (lblValue1, lblValue2,
-- ...). The QuickApp adds or removes these rows itself when the lists change;
-- saving the new layout restarts it once.

App.Display = {}
local Display = App.Display

local LABEL = "lblValue"

local qa    = nil
local names = {} -- names in display order
local texts = {} -- name -> formatted value
local shown = {} -- label id -> text currently shown

local function isValueRow(row)
  local first = type(row) == "table" and type(row.components) == "table" and row.components[1]
  return type(first) == "table" and type(first.name) == "string" and first.name:find("^" .. LABEL .. "%d+$") ~= nil
end

local function valueRow(index)
  return {
    type       = "horizontal",
    style      = { weight = "1.0" },
    components = { { name = LABEL .. index, text = "", type = "label", style = { weight = "1.00" } } },
  }
end

--- The UI rows with exactly `count` value rows after lblStatus, or nil if
-- uiView already has them.
function Display.layout(uiView, count)
  local rows, existing, insertAt = {}, 0, 1
  for _, row in ipairs(uiView) do
    if isValueRow(row) then
      existing = existing + 1
    else
      rows[#rows + 1] = row
      local first = row.components and row.components[1]
      if first and first.name == "lblStatus" then insertAt = #rows + 1 end
    end
  end
  if existing == count then return nil end
  for i = count, 1, -1 do table.insert(rows, insertAt, valueRow(i)) end
  return rows
end

--- Make the UI have one value row per listed value. Returns true if the
-- layout was saved, which restarts the QuickApp.
function Display.ensureLayout(quickApp, count)
  local device = api.get("/devices/" .. tostring(quickApp.id))
  local uiView = device and device.properties and device.properties.uiView
  if type(uiView) ~= "table" then return false end
  local rows = Display.layout(uiView, count)
  if not rows then return false end
  Log.info("Rebuilding the value list for %s value(s); the QuickApp restarts", count)
  api.put("/devices/" .. tostring(quickApp.id), { properties = { uiView = rows } })
  return true
end

function Display.init(quickApp, list)
  qa, names, texts, shown = quickApp, list, {}, {}
end

local function clock(quarter)
  return string.format("%02d:%02d", quarter // 4, (quarter % 4) * 15)
end

--- Time windows of a 96-slot day: "11:45-12:00 (2)" per run of equal digits.
function Display.slots(text)
  local windows, i = {}, 1
  while i <= #text do
    local digit = text:sub(i, i)
    local j = i
    while j < #text and text:sub(j + 1, j + 1) == digit do j = j + 1 end
    if digit ~= "0" then
      windows[#windows + 1] = string.format("%s-%s (%s)", clock(i - 1), clock(j), digit)
    end
    i = j + 1
  end
  return #windows > 0 and table.concat(windows, ", ") or "-"
end

--- The text of one value, with unit.
function Display.format(entry, value)
  if value == nil or value == "" then return "-" end
  if entry.format == "slots" then return Display.slots(tostring(value)) end
  if entry.format == "switch" then return I18n.t(tostring(value) == "1" and "value.on" or "value.off") end
  if entry.unit and entry.unit ~= "" then return tostring(value) .. " " .. entry.unit end
  return tostring(value)
end

function Display.set(entry, value)
  texts[entry.name] = Display.format(entry, value)
end

--- Write the labels whose text changed.
function Display.render()
  if not qa then return end
  for i, name in ipairs(names) do
    local id   = LABEL .. i
    local text = I18n.t("value." .. name) .. ": " .. (texts[name] or "-")
    if shown[id] ~= text then
      shown[id] = text
      local ok, err = pcall(qa.updateView, qa, id, "text", text)
      if not ok then Log.warn("Cannot update UI element '%s': %s", id, err) end
    end
  end
end
