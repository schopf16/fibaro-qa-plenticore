-- Display: the listed values as a table in the QuickApp's user interface.
--
-- The HC3 shows a label on a single line, gives all elements of a row the same
-- width and ignores alignment, so every value has its own row: the name in
-- the selected language, and the value with its unit. A writable switch
-- setting shows a switch instead of the value; a writable setting with a range
-- gets a slider row below its value. The QuickApp builds its whole user
-- interface itself when the lists change or the layout was changed elsewhere,
-- e.g. by saving the code in the HC3 editor; saving the layout restarts it once.

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

-- The rows around the value table, as in qa.manifest.json.
local STATUS, REFRESH = "lblStatus", "btnRefresh"
local BUTTON_EVENTS   = { "onReleased", "onLongPressDown", "onLongPressReleased" }

local function statusRow()
  return row({ { name = STATUS, text = "Status", type = "label", style = { weight = "1.00" } } })
end

local function refreshRow()
  local bindings = {}
  for _, event in ipairs(BUTTON_EVENTS) do
    bindings[event] = { { type = "deviceAction", params = { actionName = "UIAction", args = { event, REFRESH } } } }
  end
  return row({ { name = REFRESH, text = "Refresh", type = "button", visible = true,
                 style = { weight = "1.00" }, eventBinding = bindings } })
end

--- The complete UI: status line, value table for `spec`, refresh button.
function Display.layout(spec)
  local result = { statusRow() }
  for _, r in ipairs(Display.tableRows(spec)) do result[#result + 1] = r end
  result[#result + 1] = refreshRow()
  return result
end

--- The same rows for the editor's copy of the layout (viewLayout), which the
-- HC3 editor turns back into the UI when the QuickApp's code is saved.
function Display.viewLayout(quickApp, layout)
  local items = {}
  for i, r in ipairs(layout) do
    local components = {}
    for j, c in ipairs(r.components) do
      local copy = {}
      for k, v in pairs(c) do if k ~= "eventBinding" then copy[k] = v end end
      components[j] = copy
    end
    items[i] = { type = r.type, style = r.style, components = components }
  end
  local title = "quickApp_device_" .. tostring(quickApp.id)
  return { ["$jason"] = { head = { title = title },
    body = { header = { style = { height = "0" }, title = title }, sections = { items = items } } } }
end

--- Names and types of the named elements in order. Unnamed elements (spacers
-- the HC3 editor adds) and the row types are ignored.
function Display.signature(list)
  local parts = {}
  for _, r in ipairs(type(list) == "table" and list or {}) do
    for _, c in ipairs(type(r) == "table" and type(r.components) == "table" and r.components or {}) do
      if type(c) == "table" and type(c.name) == "string" then parts[#parts + 1] = c.name .. ":" .. tostring(c.type) end
    end
  end
  return table.concat(parts, ",")
end

local function layoutItems(viewLayout)
  local jason = type(viewLayout) == "table" and viewLayout["$jason"]
  local body  = type(jason) == "table" and jason.body
  local sections = type(body) == "table" and body.sections
  return type(sections) == "table" and sections.items or nil
end

--- UI callbacks: the refresh button and one per switch and slider.
function Display.callbacks(spec)
  local result = { { name = REFRESH, eventType = "onReleased", callback = callbackName(REFRESH, "onReleased") } }
  for i, item in ipairs(spec) do
    local id, event = controlOf(item, i)
    if id then result[#result + 1] = { name = id, eventType = event, callback = callbackName(id, event) } end
  end
  return result
end

--- Make the UI and the editor's copy of it match `spec`. Returns true if the
-- layout was saved, which restarts the QuickApp.
function Display.ensureLayout(quickApp, spec)
  local path   = "/devices/" .. tostring(quickApp.id)
  local device = api.get(path)
  local props  = device and device.properties
  if type(props) ~= "table" then return false end
  local layout = Display.layout(spec)
  local wanted = Display.signature(layout)
  if Display.signature(props.uiView) == wanted and Display.signature(layoutItems(props.viewLayout)) == wanted then
    return false
  end
  Log.info("Rebuilding the user interface for %s value(s); the QuickApp restarts", #spec)
  local body = { properties = { uiView = layout, viewLayout = Display.viewLayout(quickApp, layout),
                                uiCallbacks = Display.callbacks(spec) } }
  local _, status = api.put(path, body)
  if not (math.type(status) == "integer" and status < 300) then
    Log.error("Cannot save the user interface layout (HTTP %s); values are not shown", status)
    return false
  end
  -- Restart only if the controller kept the layout, so a changed format cannot cause a restart loop.
  device = api.get(path)
  props  = device and device.properties
  if type(props) ~= "table" or Display.signature(props.uiView) ~= wanted then
    Log.error("The controller did not keep the user interface layout; values may not be shown")
    return false
  end
  return true
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

--- Remember a value for the next render. Text from the inverter is escaped,
-- because the HC3 renders labels as HTML.
function Display.set(entry, value)
  texts[entry.name] = Util.escapeHtml(Display.format(entry, value))
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
