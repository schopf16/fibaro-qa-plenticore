-- Display: the listed values as a table in the QuickApp's user interface.
--
-- The HC3 shows a label on a single line, gives all elements of a row the same
-- width and ignores alignment, so every value has its own row: the name in
-- the selected language, and the value with its unit. A writable switch
-- setting shows a switch instead of the value; a writable setting with a range
-- gets a slider row below its value. The QuickApp adds or removes these rows
-- itself when the lists change; saving the new layout restarts it once.

App.Display = {}
local Display = App.Display

local NAME, VALUE, SWITCH, SLIDER = "lblName", "lblValue", "swValue", "sldValue"
local EVENTS = { switch = "onToggled", slider = "onChanged" }

local qa       = nil
local rows     = {} -- { name, control } in display order
local texts    = {} -- name -> value text with unit
local raw      = {} -- name -> value, for the controls
local shown    = {} -- "id.property" -> content currently shown
local onChange = nil

-- Elements -----------------------------------------------------------------------

local function label(id)
  return { name = id, text = "", type = "label", style = { weight = "0.50" } }
end

local function binding(event, id)
  return { [event] = { { type = "deviceAction",
    params = { actionName = "UIAction", args = { event, id, "$event.value" } } } } }
end

local function switch(id)
  return { name = id, type = "switch", value = "false", style = { weight = "0.50" },
           eventBinding = binding(EVENTS.switch, id) }
end

local function slider(id, control)
  return { name = id, type = "slider", text = "", value = tostring(control.min), style = { weight = "1.0" },
           min = tostring(control.min), max = tostring(control.max), step = tostring(control.step or 1),
           eventBinding = binding(EVENTS.slider, id) }
end

local function row(components)
  return { type = "horizontal", style = { weight = "1.0" }, components = components }
end

-- The id of the control of value row i, and its event; nil for plain values.
local function controlOf(item, i)
  local kind = item.control and item.control.type
  if kind == "switch" then return SWITCH .. i, EVENTS.switch end
  if kind == "slider" then return SLIDER .. i, EVENTS.slider end
  return nil
end

local function callbackName(id, event)
  return "ui" .. id .. event:sub(1, 1):upper() .. event:sub(2)
end

--- The rows of the value table for `spec` ({ name, control } per value).
function Display.tableRows(spec)
  local result = {}
  for i, item in ipairs(spec) do
    local kind = item.control and item.control.type
    if kind == "switch" then
      result[#result + 1] = row({ label(NAME .. i), switch(SWITCH .. i) })
    else
      result[#result + 1] = row({ label(NAME .. i), label(VALUE .. i) })
      if kind == "slider" then result[#result + 1] = row({ slider(SLIDER .. i, item.control) }) end
    end
  end
  return result
end

-- Layout -------------------------------------------------------------------------

local function isTableRow(r)
  local first = type(r) == "table" and type(r.components) == "table" and r.components[1]
  local name  = type(first) == "table" and type(first.name) == "string" and first.name or ""
  for _, prefix in ipairs({ NAME, VALUE, SLIDER }) do
    if name:find("^" .. prefix .. "%d+$") then return true end
  end
  return false
end

-- Names and types of the elements, to compare an existing table with the wanted one.
local function signature(list)
  local parts = {}
  for _, r in ipairs(list) do
    for _, c in ipairs(r.components or {}) do parts[#parts + 1] = tostring(c.name) .. ":" .. tostring(c.type) end
    parts[#parts + 1] = "|"
  end
  return table.concat(parts, ",")
end

--- The UI rows with the value table for `spec` after lblStatus, or nil if
-- uiView already has exactly this table.
function Display.layout(uiView, spec)
  local wanted = Display.tableRows(spec)
  local others, existing, insertAt = {}, {}, 1
  for _, r in ipairs(uiView) do
    if isTableRow(r) then
      existing[#existing + 1] = r
    else
      others[#others + 1] = r
      local first = r.components and r.components[1]
      if first and first.name == "lblStatus" then insertAt = #others + 1 end
    end
  end
  if signature(existing) == signature(wanted) then return nil end
  for i = #wanted, 1, -1 do table.insert(others, insertAt, wanted[i]) end
  return others
end

--- UI callbacks: the existing ones except those of the value table, plus one
-- per switch and slider.
function Display.callbacks(existing, spec)
  local result = {}
  for _, c in ipairs(existing or {}) do
    local name = type(c.name) == "string" and c.name or ""
    if not (name:find("^" .. SWITCH .. "%d+$") or name:find("^" .. SLIDER .. "%d+$")) then
      result[#result + 1] = c
    end
  end
  for i, item in ipairs(spec) do
    local id, event = controlOf(item, i)
    if id then result[#result + 1] = { name = id, eventType = event, callback = callbackName(id, event) } end
  end
  return result
end

--- Make the UI have the value table for `spec`. Returns true if the layout
-- was saved, which restarts the QuickApp.
function Display.ensureLayout(quickApp, spec)
  local device = api.get("/devices/" .. tostring(quickApp.id))
  local props  = device and device.properties
  if type(props) ~= "table" or type(props.uiView) ~= "table" then return false end
  local layout = Display.layout(props.uiView, spec)
  if not layout then return false end
  Log.info("Rebuilding the value table for %s value(s); the QuickApp restarts", #spec)
  local body = { properties = { uiView = layout, uiCallbacks = Display.callbacks(props.uiCallbacks, spec) } }
  local _, status = api.put("/devices/" .. tostring(quickApp.id), body)
  if math.type(status) == "integer" and status < 300 then return true end
  Log.error("Cannot save the value table layout (HTTP %s); values are not shown", status)
  return false
end

-- Values -------------------------------------------------------------------------

--- spec: { name, control } per value. changed(name, value) is called when the
-- user moves a slider or flips a switch.
function Display.init(quickApp, spec, changed)
  qa, rows, texts, raw, shown, onChange = quickApp, spec, {}, {}, {}, changed
  for i, item in ipairs(spec) do
    local id, event = controlOf(item, i)
    if id then
      -- The HC3 calls ui<id><Event> on the QuickApp; every call is protected.
      QuickApp[callbackName(id, event)] = function(_, uiEvent)
        local value = type(uiEvent) == "table" and type(uiEvent.values) == "table" and uiEvent.values[1]
        Safe.call(id, onChange, item.name, value)
      end
    end
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
  raw[entry.name]   = value
end

local function update(id, property, value)
  local key = id .. "." .. property
  if shown[key] == value then return end
  shown[key] = value
  local ok, err = pcall(qa.updateView, qa, id, property, value)
  if not ok then Log.warn("Cannot update UI element '%s': %s", id, err) end
end

--- Write the elements whose content changed.
function Display.render()
  if not qa then return end
  for i, item in ipairs(rows) do
    local kind  = item.control and item.control.type
    local value = raw[item.name]
    update(NAME .. i, "text", I18n.t("value." .. item.name))
    if kind == "switch" then
      if value ~= nil then update(SWITCH .. i, "value", tostring(value) == "1" and "true" or "false") end
    else
      update(VALUE .. i, "text", texts[item.name] or "-")
      if kind == "slider" and value ~= nil then update(SLIDER .. i, "value", tostring(value)) end
    end
  end
end
