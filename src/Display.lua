-- Display: one line per listed value in the QuickApp's user interface, with
-- the name in the selected language and the unit. The HC3 shows a label on a
-- single line, so every value has its own label (lblValue1, lblValue2, ...);
-- labels without a value are hidden.

App.Display = {}
local Display = App.Display

local qa      = nil
local names   = {} -- names in display order
local texts   = {} -- name -> formatted value
local shown   = {} -- label id -> text currently shown
local labels  = 0  -- number of value labels in the UI

--- labelCount: number of lblValue labels in the manifest (one per catalog entry).
function Display.init(quickApp, list, labelCount)
  qa, names, texts, shown, labels = quickApp, list, {}, {}, labelCount
  if #names > labels then
    Log.warn("Only %s of %s listed values fit into the value list", labels, #names)
  end
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
  local first = shown[id] == nil
  shown[id] = text
  local ok, err = pcall(function()
    if first then qa:updateView(id, "visible", text ~= false) end
    if text then qa:updateView(id, "text", text) end
  end)
  if not ok then Log.warn("Cannot update UI element '%s': %s", id, err) end
end

--- Write the labels whose text changed; hide the unused ones once.
function Display.render()
  if not qa then return end
  for i = 1, labels do
    local name = names[i]
    local text = false
    if name then text = I18n.t("value." .. name) .. ": " .. (texts[name] or "-") end
    show("lblValue" .. i, text)
  end
end
