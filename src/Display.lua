-- Display: one line per listed value in the QuickApp's user interface, with
-- the name in the selected language and the unit.

App.Display = {}
local Display = App.Display

local LABEL = "lblValues"

local qa     = nil
local names  = {}  -- names in display order
local texts  = {}  -- name -> formatted value
local shown  = nil -- text currently in the label

function Display.init(quickApp, list)
  qa, names, texts, shown = quickApp, list, {}, nil
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

--- Write the label if its text changed.
function Display.render()
  if not qa or #names == 0 then return end
  local lines = {}
  for i, name in ipairs(names) do
    lines[i] = I18n.t("value." .. name) .. ": " .. Util.escapeHtml(texts[name] or "-")
  end
  local text = table.concat(lines, "<br>")
  if text == shown then return end
  shown = text
  local ok, err = pcall(qa.updateView, qa, LABEL, "text", text)
  if not ok then Log.warn("Cannot update the value list: %s", err) end
end
