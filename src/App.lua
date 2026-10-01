-- App: reads the values listed in readValues and childValues, keeps the
-- settings listed in writeValues up to date and writes them on request, and
-- keeps the user interface up to date.
--
-- All project code lives in the global App table (App.Catalog, App.Kostal,
-- App.Sync, App.Values, App.Children, App.Display, App.Store, App.Crypto).

App = {}

App.STRINGS = Strings

-- Options of this QuickApp. Change a value here and save; the QuickApp restarts.
-- An invalid value is reported in the log and replaced by its default.
App.OPTIONS = {
  pollIntervalSec = 10,     -- seconds between two readings: 5 to 3600
  deadband        = true,   -- true: write values only when they change by more than
                            -- 10 W, 0.01 kWh or 1 %; false: on every change
  https           = true,   -- true: encrypted connection to the inverter (its self-signed
                            -- certificate is accepted); false: plain HTTP
  logLevel        = "info", -- "error", "warn", "info" or "debug" (for bug reports)
  language        = "auto", -- "auto" (controller language), "en", "de", "fr" or "it"
}

--- Project options, added to Config.OPTIONS (logLevel, language).
App.OPTION_SCHEMA = {
  { name = "pollIntervalSec", type = "integer", default = 10, min = 5, max = 3600 },
  { name = "deadband",        type = "boolean", default = true },
  { name = "https",           type = "boolean", default = true },
}

local LIST_LENGTH   = 2000
local DEFAULT_READ  = "pvPower, homePower, gridPower, batteryPower, batterySoc, yieldDay, yieldTotal, "
                   .. "homeFromGridTotal"
local DEFAULT_WRITE = "batteryMinSoc"
local DEFAULT_CHILD = "pvPower, gridPower, batteryPower, batterySoc, yieldTotal, homeFromGridTotal"

--- QuickApp variables (entered in the HC3).
App.CONFIG = {
  { name = "host",        type = "host",   required = true },
  { name = "password",    type = "secret", required = true },
  { name = "readValues",  type = "string", default = DEFAULT_READ,  maxLength = LIST_LENGTH },
  { name = "writeValues", type = "string", default = DEFAULT_WRITE, maxLength = LIST_LENGTH },
  { name = "childValues", type = "string", default = DEFAULT_CHILD, maxLength = LIST_LENGTH },
}

App.UI = {
  text        = { btnRefresh = "ui.refresh" },
  statusLabel = "lblStatus",
}

local SETTINGS_SYNC_MS = 5 * 60 * 1000
local MAX_RETRY_MS     = 10 * 60 * 1000
local VERIFY_DELAY_MS  = 2000
local VERIFY_ATTEMPTS  = 3

local LISTS = {
  { key = "read",     variable = "readValues",  accept = "readable" },
  { key = "write",    variable = "writeValues", accept = "writable" },
  { key = "children", variable = "childValues", accept = "childCapable" },
}

local state = {}

-- Lists --------------------------------------------------------------------------

--- Parse the three lists. Returns lists, or nil and the invalid entries per variable.
function App.parseLists(cfg)
  local lists, problems = {}, {}
  for _, spec in ipairs(LISTS) do
    local text = cfg[spec.variable] or ""
    if Util.trim(text):lower() == "none" then text = "" end
    local names, invalid = App.Catalog.parseList(text, App.Catalog[spec.accept])
    lists[spec.key] = names
    if #invalid > 0 then problems[#problems + 1] = { variable = spec.variable, names = invalid } end
  end
  if #problems > 0 then return nil, problems end
  return lists
end

local function entriesOf(names, filter)
  local entries = {}
  for _, name in ipairs(names) do
    local entry = App.Catalog.get(name)
    if not filter or filter(entry) then entries[#entries + 1] = entry end
  end
  return entries
end

local function isProcess(entry) return entry.kind == "process" end
local function isFromSettings(entry) return entry.kind ~= "process" end -- settings and device information

--- The value table: readValues, then writeValues not already shown. Settings
-- in writeValues get their UI control (switch or slider), if they have one.
function App.tableSpec(lists)
  local spec, seen, writable = {}, {}, {}
  for _, name in ipairs(lists.write) do writable[name] = true end
  for _, list in ipairs({ lists.read, lists.write }) do
    for _, name in ipairs(list) do
      if not seen[name] then
        seen[name] = true
        local entry = App.Catalog.get(name)
        spec[#spec + 1] = { name = name, control = writable[name] and entry.control or nil }
      end
    end
  end
  return spec
end

-- Start --------------------------------------------------------------------------

--- Called once by Boot.run with a valid configuration.
function App.start(qa, cfg, options)
  -- The login (SHA-256, AES-GCM) needs 64-bit integers; stop visibly on a Lua with smaller ones.
  if math.maxinteger < 2 ^ 62 then
    Log.error("This controller's Lua has integers up to %s; the inverter login needs 64-bit integers",
      math.maxinteger)
    Ui.setStatus("status.unsupportedPlatform")
    return
  end

  local lists, problems = App.parseLists(cfg)
  if not lists then
    local variables = {}
    for i, problem in ipairs(problems) do
      variables[i] = problem.variable
      Log.error("%s: unknown or not allowed names: %s (the README lists all valid names)",
        problem.variable, Util.join(problem.names))
    end
    Ui.setStatus("lib.status.notConfigured", { names = Util.join(variables) })
    return
  end

  local spec = App.tableSpec(lists)
  if App.Display.ensureLayout(qa, spec) then return end

  App.Store.init(qa)
  App.Values.init(qa, options.deadband)
  if App.Values.removeObsolete(lists) then return end
  App.Children.sync(qa, lists.children)
  App.Display.init(qa, spec, App.set)

  state = {
    lists      = lists,
    readSet    = {},
    writeSet   = {},
    known      = {}, -- setting name -> last value read from the inverter
    intervalMs = options.pollIntervalSec * 1000,
    https      = options.https,
    deadband   = options.deadband,
    failures   = 0,
  }
  for _, name in ipairs(lists.read) do state.readSet[name] = true end
  for _, name in ipairs(lists.write) do state.writeSet[name] = true end
  for _, item in ipairs(spec) do
    if state.writeSet[item.name] and not item.control then
      Log.warn("writeValues: '%s' has no switch or slider in the QuickApp's user interface; "
        .. "change it with fibaro.call(id, \"set\", \"%s\", value)", item.name, item.name)
    end
  end
  Log.info("Reading %s value(s), %s writable setting(s), %s child device(s), every %s s",
    #lists.read, #lists.write, #lists.children, options.pollIntervalSec)

  state.client = App.Kostal.new({ host = cfg.host, password = cfg.password, https = options.https })
  Ui.setStatus("status.loggingIn")
  App.connect()
end

-- Failures -----------------------------------------------------------------------

local function stop(err)
  -- Retrying a rejected password could lock the account; wait for a new configuration.
  Log.error("%s; stopped until the QuickApp variables are saved again", err)
  Ui.setStatus("status.authFailed")
  state.online, state.stopped = false, true
  Timer.cancelAll()
end

local function onFailure(err, kind, retry)
  if kind == "auth" then return stop(err) end
  state.failures = state.failures + 1
  local delayMs = Timer.backoff(state.failures, state.intervalMs, math.max(state.intervalMs, MAX_RETRY_MS))
  if state.online ~= false then
    Log.warn("Inverter %s; retrying with back-off", err)
    if kind == "unreachable" and state.https then
      Log.info("If the inverter does not offer HTTPS, set https = false in App.OPTIONS")
    end
  else
    Log.debug("Still failing (%s); next attempt in %s s", err, delayMs // 1000)
  end
  state.online = false
  if kind == "unreachable" then
    Ui.setStatus("status.unreachable", { seconds = delayMs // 1000 })
  else
    Ui.setStatus("status.protocolError")
  end
  Timer.after("retry", delayMs, retry)
end

--- Log in and learn what the device offers, then start polling.
function App.connect()
  state.client:processdataIds(function(err, available, kind)
    if err then return onFailure(err, kind, App.connect) end
    state.available = available
    state.client:settingsMeta(function(err2, meta, kind2)
      if err2 then return onFailure(err2, kind2, App.connect) end
      state.meta = meta
      App.poll()
      App.syncSettings()
    end)
  end)
end

-- Process data -------------------------------------------------------------------

-- The query for all process values needed: listed values, children and the
-- two values of the status line.
local function processQuery()
  local query, entries, seen = {}, {}, {}
  local function request(module, id)
    local offered = state.available[module]
    if not (offered and offered[id]) then return false end
    query[module] = query[module] or {}
    table.insert(query[module], id)
    return true
  end
  local function add(entry)
    if seen[entry.name] then return end
    seen[entry.name] = true
    local offered = false
    for _, source in ipairs(entry.sum or { { entry.module, entry.id } }) do
      offered = request(source[1], source[2]) or offered
    end
    if offered then entries[#entries + 1] = entry end
  end
  for _, entry in ipairs(entriesOf(state.lists.read, isProcess)) do add(entry) end
  for _, entry in ipairs(entriesOf(state.lists.children)) do add(entry) end
  add(App.Catalog.get("pvPower"))
  add(App.Catalog.get("batterySoc"))
  return query, entries
end

--- One polling cycle.
function App.poll()
  if state.polling or state.stopped or not state.available then return end
  state.polling = true
  Timer.cancel("poll")
  local query, entries = processQuery()
  state.client:processdata(query, function(err, processdata, kind)
    state.polling = false
    if state.stopped then return end
    if err then return onFailure(err, kind, App.poll) end
    -- Scheduled first, so that an error while processing cannot stop polling.
    Timer.after("poll", state.intervalMs, App.poll)
    local values = {}
    for _, entry in ipairs(entries) do
      local value = App.Catalog.present(entry, App.Catalog.raw(entry, processdata))
      values[entry.name] = value
      if state.readSet[entry.name] then
        App.Values.set(entry, value)
        App.Display.set(entry, value)
      end
    end
    App.Values.flush()
    App.Children.update(values, state.existingIds, state.deadband)
    App.Display.render()
    if state.online ~= true then Log.info("Inverter online") end
    state.online, state.failures = true, 0
    Ui.setStatus("status.online", {
      pv   = values.pvPower or "-",
      soc  = values.batterySoc or "-",
      time = os.date("%H:%M"),
    })
  end)
end

-- Settings -----------------------------------------------------------------------

local function settingsQuery(entries)
  local query = {}
  for _, entry in ipairs(entries) do
    query[entry.module] = query[entry.module] or {}
    for _, id in ipairs(entry.ids or { entry.id }) do table.insert(query[entry.module], id) end
  end
  return query
end

local function remoteValue(remote, entry)
  local module = remote[entry.module] or {}
  if entry.ids then
    local parts = {}
    for i, id in ipairs(entry.ids) do parts[i] = module[id] or "" end
    return Util.trim(table.concat(parts, " "))
  end
  return module[entry.id]
end

local function metaOf(entry)
  return state.meta and state.meta[entry.module] and state.meta[entry.module][entry.id]
end

-- Publish a setting's current value (normalized text) everywhere.
local function showSetting(entry, text)
  local value = App.Sync.publishable(entry, text)
  App.Values.set(entry, value)
  App.Display.set(entry, value)
end

--- Read the listed settings and device information from the inverter. A
-- setting changed on the inverter (web UI, app) is adopted.
function App.syncSettings()
  if state.stopped or not state.meta then return end
  Timer.after("settings", SETTINGS_SYNC_MS, App.syncSettings)
  state.existingIds = App.Children.existingIds()

  local writeEntries = entriesOf(state.lists.write)
  local readEntries  = entriesOf(state.lists.read, isFromSettings)
  local all = {}
  for _, entry in ipairs(writeEntries) do all[#all + 1] = entry end
  for _, entry in ipairs(readEntries) do all[#all + 1] = entry end
  if #all == 0 then return end

  state.client:settings(settingsQuery(all), function(err, remote, kind)
    if err then
      -- While the inverter is offline, polling already reports it.
      if state.online == false then
        Log.debug("Reading settings failed: %s", err)
      else
        Log.warn("Reading settings failed: %s", err)
      end
      if kind == "auth" then stop(err) end
      return
    end
    for _, entry in ipairs(writeEntries) do
      local text   = App.Sync.normalize(entry, remoteValue(remote, entry))
      local before = state.known[entry.name]
      if before ~= nil and text ~= before then
        Log.info("'%s' was changed on the inverter: %s -> %s", entry.name, before, text)
      end
      state.known[entry.name] = text
      showSetting(entry, text)
    end
    for _, entry in ipairs(readEntries) do
      if not state.writeSet[entry.name] then
        local value = App.Catalog.present(entry, remoteValue(remote, entry))
        App.Values.set(entry, value)
        App.Display.set(entry, value)
      end
    end
    App.Values.flush()
    App.Display.render()
  end)
end

-- The inverter applies a written value with a short delay, so the read-back
-- is repeated a few times before a difference counts as rejected.
local function verify(entry, wanted, attempt)
  state.client:settings(settingsQuery({ entry }), function(err, remote, kind)
    if err then
      Log.error("Cannot read back '%s': %s", entry.name, err)
      if kind == "auth" then stop(err) end
      return
    end
    local actual = App.Sync.normalize(entry, remoteValue(remote, entry))
    if actual ~= wanted and attempt < VERIFY_ATTEMPTS then
      local again = function() verify(entry, wanted, attempt + 1) end
      return Timer.after("verify." .. entry.name, VERIFY_DELAY_MS, again)
    end
    if actual == wanted then
      Log.info("Setting '%s' changed to %s on the inverter", entry.name, wanted)
    else
      Log.error("The inverter kept '%s' at %s instead of %s", entry.name, actual, wanted)
    end
    state.known[entry.name] = actual
    showSetting(entry, actual)
    App.Values.flush()
    App.Display.render()
  end)
end

-- Actions ------------------------------------------------------------------------

--- Write a setting listed in writeValues: fibaro.call(id, "set", name, value),
-- or a switch or slider in the user interface.
function App.set(name, value)
  local entry = App.Catalog.get(tostring(name))
  if not (entry and state.writeSet and state.writeSet[entry.name]) then
    return Log.warn("set: '%s' is not listed in writeValues", tostring(name))
  end
  if not state.meta then
    return Log.warn("set: not connected to the inverter yet; '%s' was not changed", entry.name)
  end
  local valid, reason = App.Sync.validate(entry, value, metaOf(entry))
  if not valid then
    Log.warn("set: value %s for '%s' rejected: %s", tostring(value), entry.name, reason)
    -- Put a moved slider or flipped switch back to the inverter's value.
    showSetting(entry, state.known[entry.name])
    return App.Display.render()
  end
  if valid == state.known[entry.name] then
    return Log.debug("set: '%s' is already %s", entry.name, valid)
  end
  state.client:writeSettings({ [entry.module] = { [entry.id] = valid } }, function(err, kind)
    if err then
      Log.error("Writing '%s' failed: %s", entry.name, err)
      if kind == "auth" then stop(err) end
      showSetting(entry, state.known[entry.name])
      return App.Display.render()
    end
    verify(entry, valid, 1)
  end)
end

--- Handler for the Refresh button.
function App.refresh()
  Log.info("Manual refresh")
  App.poll()
  App.syncSettings()
end
