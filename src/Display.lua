-- Display: the listed values as a table in the QuickApp's user interface.
--
-- The HC3 shows a label on a single line, so every value has its own row of
-- two labels: the name in the selected language, and the value with its unit.
-- The HC3 gives all labels of a row the same width and ignores weight and
-- alignment, so two columns keep the names from wrapping. The QuickApp adds or
-- removes these rows itself when the lists change; saving the new layout
-- restarts it once.

App.Display = {}
local Display = App.Display

-- One column per label in a value row: id prefix and share of the width.
local COLUMNS = {
  { prefix = "lblName",  weight = "0.50" },
  { prefix = "lblValue", weight = "0.50" },
}

local qa    = nil
local names = {} -- names in display order
local texts = {} -- name -> value with unit
local shown = {} -- label id -> text currently shown

-- A row of this QuickApp's value table (current or earlier layout).
local function isValueRow(row)
  local first = type(row) == "table" and type(row.components) == "table" and row.components[1]
  local name  = type(first) == "table" and type(first.name) == "string" and first.name or ""
  return name:find("^lblName%d+$") ~= nil or name:find("^lblValue%d+$") ~= nil
end

local function isCurrentRow(row)
  return #row.components == #COLUMNS and row.components[1].name:find("^lblName%d+$") ~= nil
end

local function valueRow(index)
  local components = {}
  for i, column in ipairs(COLUMNS) do
    components[i] = {
      name  = column.prefix .. index,
      text  = "",
      type  = "label",
      style = { weight = column.weight },
    }
  end
  return { type = "horizontal", style = { weight = "1.0" }, components = components }
end

--- The UI rows with exactly `count` value rows after lblStatus, or nil if
-- uiView already has them in the current layout.
function Display.layout(uiView, count)
  local rows, existing, current, insertAt = {}, 0, true, 1
  for _, row in ipairs(uiView) do
    if isValueRow(row) then
      existing = existing + 1
      current  = current and isCurrentRow(row)
    else
      rows[#rows + 1] = row
      local first = row.components and row.components[1]
      if first and first.name == "lblStatus" then insertAt = #rows + 1 end
    end
  end
  if existing == count and current then return nil end
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
  Log.info("Rebuilding the value table for %s value(s); the QuickApp restarts", count)
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

local function show(id, text)
  if shown[id] == text then return end
  shown[id] = text
  local ok, err = pcall(qa.updateView, qa, id, "text", text)
  if not ok then Log.warn("Cannot update UI element '%s': %s", id, err) end
end

--- Write the labels whose text changed.
function Display.render()
  if not qa then return end
  for i, name in ipairs(names) do
    show(COLUMNS[1].prefix .. i, I18n.t("value." .. name))
    show(COLUMNS[2].prefix .. i, texts[name] or "-")
  end
end
