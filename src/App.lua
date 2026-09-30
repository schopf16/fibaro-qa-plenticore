-- App: reads the values listed in readValues and childValues, synchronises
-- the settings listed in writeValues, and keeps the user interface up to date.
--
-- All project code lives in the global App table (App.Catalog, App.Kostal,
-- App.Sync, App.Vars, App.Children, App.Display, App.Store, App.Crypto).

App = {}

App.STRINGS = Strings

local LIST_LENGTH = 2000

--- Project variables, added to Config.COMMON (logLevel, language).
App.CONFIG = {
  { name = "host",            type = "host",    required = true },
  { name = "password",        type = "secret",  required = true },
  { name = "pollIntervalSec", type = "integer", default = 30, min = 10, max = 3600 },
  { name = "readValues",      type = "string",  maxLength = LIST_LENGTH,
    default = "pvPower, homePower, gridPower, batteryPower, batterySoc, yieldDay" },
  { name = "writeValues",     type = "string",  maxLength = LIST_LENGTH,
    default = "batteryMinSoc, batterySmartControl" },
  { name = "childValues",     type = "string",  maxLength = LIST_LENGTH,
    default = "none" },
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

-- Lists ------------------------------------------------------------------------

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
local function isSetting(entry) return entry.kind ~= "process" end

--- Names shown in the value list: readValues, then writeValues not already shown.
local function displayNames(lists)
  local names, seen = {}, {}
  for _, list in ipairs({ lists.read, lists.write }) do
    for _, name in ipairs(list) do
      if not seen[name] then names[#names + 1], seen[name] = name, true end
    end
  end
  return names
end

-- Start ------------------------------------------------------------------------

--- Called once by Boot.run with a valid configuration.
function App.start(qa, cfg)
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

  state = {
    lists      = lists,
    readSet    = {},
    writeSet   = {},
    intervalMs = cfg.pollIntervalSec * 1000,
    failures   = 0,
  }
  for _, name in ipairs(lists.read) do state.readSet[name] = true end
  for _, name in ipairs(lists.write) do state.writeSet[name] = true end

  App.Store.init(qa)
  App.Sync.init()
  App.Vars.init(qa)
  local keep = {}
  for name in pairs(state.readSet) do keep[name] = true end
  for name in pairs(state.writeSet) do keep[name] = true end
  App.Vars.removeUnlisted(keep)
  App.Children.sync(qa, lists.children)
  App.Display.init(qa, displayNames(lists))
  Log.info("Reading %s value(s), synchronising %s setting(s), %s child device(s)",
    #lists.read, #lists.write, #lists.children)

  state.client = App.Kostal.new({ host = cfg.host, password = cfg.password })
  Ui.setStatus("status.loggingIn")
  App.connect()
end

-- Failures ---------------------------------------------------------------------

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

-- Process data -----------------------------------------------------------------

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

-- A variable in writeValues that differs from its reference was changed on the HC3.
local function checkLocalChanges()
  local references = App.Sync.references()
  for _, entry in ipairs(entriesOf(state.lists.write)) do
    local localValue = App.Sync.normalize(entry, App.Vars.get(entry.name))
    local reference  = references[entry.name]
    if localValue ~= "" and reference ~= nil and localValue ~= reference then
      Log.debug("Local change of '%s' detected", entry.name)
      return App.syncSettings()
    end
  end
end

--- One polling cycle.
function App.poll()
  if state.polling or state.stopped or not state.available then return end
  state.polling = true
  Timer.cancel("poll")
  local query, entries = processQuery()
  state.client:processdata(query, function(err, processdata, kind)
    state.polling = false
    if err then return onFailure(err, kind, App.poll) end
    local values = {}
    for _, entry in ipairs(entries) do
      local value = App.Catalog.present(entry, App.Catalog.raw(entry, processdata))
      values[entry.name] = value
      if state.readSet[entry.name] then
        App.Vars.publish(entry, value)
        App.Display.set(entry, value)
      end
    end
    App.Children.update(values, state.existingIds)
    App.Display.render()
    if state.online ~= true then Log.info("Inverter online") end
    state.online, state.failures = true, 0
    Ui.setStatus("status.online", {
      pv   = values.pvPower or "-",
      soc  = values.batterySoc or "-",
      time = os.date("%H:%M"),
    })
    checkLocalChanges()
    Timer.after("poll", state.intervalMs, App.poll)
  end)
end

-- Settings ---------------------------------------------------------------------

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

local function showSetting(entry, value)
  App.Vars.set(entry.name, value)
  App.Display.set(entry, value)
end

local function finishSync()
  App.Display.render()
  state.syncing = false
  if state.syncAgain then
    state.syncAgain = false
    App.syncSettings()
  end
end

-- The inverter applies a written value with a short delay, so the read-back
-- is repeated a few times before a difference counts as rejected.
local function verifyWrites(pending, attempt)
  local entries = {}
  for name in pairs(pending) do entries[#entries + 1] = App.Catalog.get(name) end
  state.client:settings(settingsQuery(entries), function(err, remote, kind)
    if err then
      Log.error("Cannot read back written settings: %s", err)
      if kind == "auth" then stop(err) end
      return finishSync()
    end
    local references, open = App.Sync.references(), {}
    for name, wanted in pairs(pending) do
      local entry  = App.Catalog.get(name)
      local actual = App.Sync.normalize(entry, remoteValue(remote, entry))
      if actual == wanted then
        Log.info("Setting '%s' changed to %s on the inverter", name, wanted)
        references[name] = actual
        showSetting(entry, actual)
      elseif attempt < VERIFY_ATTEMPTS then
        open[name] = wanted
      else
        Log.error("The inverter kept '%s' at %s instead of %s", name, actual, wanted)
        references[name] = actual
        showSetting(entry, actual)
      end
    end
    App.Sync.saveReferences(references)
    if next(open) then
      return Timer.after("verify", VERIFY_DELAY_MS, function() verifyWrites(open, attempt + 1) end)
    end
    finishSync()
  end)
end

-- Compare one listed setting with the inverter. Returns the value to write, if any.
local function reconcile(entry, remote, references)
  local name       = entry.name
  local remoteText = App.Sync.normalize(entry, remoteValue(remote, entry))
  local localText  = App.Sync.normalize(entry, App.Vars.get(name))
  local action     = App.Sync.decide(localText, remoteText, references[name])

  if action == "write" then
    local valid, reason = App.Sync.validate(entry, localText, metaOf(entry))
    if valid then return valid end
    Log.warn("Value %s for '%s' rejected: %s; variable reset to the inverter's value %s",
      localText, name, reason, remoteText)
    showSetting(entry, remoteText)
  elseif action == "conflict" then
    Log.warn("'%s' was changed locally (%s) and on the inverter (%s); the inverter's value applies",
      name, localText, remoteText)
    references[name] = remoteText
    showSetting(entry, remoteText)
  elseif action == "adopt" then
    if references[name] ~= nil then
      Log.info("'%s' was changed on the inverter: %s -> %s", name, references[name], remoteText)
    end
    references[name] = remoteText
    showSetting(entry, remoteText)
  else
    App.Display.set(entry, remoteText)
  end
  return nil
end

--- Three-way synchronisation of the listed settings, and refresh of read-only
-- settings and device information.
function App.syncSettings()
  if state.stopped or not state.meta then return end
  if state.syncing then
    state.syncAgain = true
    return
  end
  state.syncing = true
  Timer.after("settings", SETTINGS_SYNC_MS, App.syncSettings)
  state.existingIds = App.Children.existingIds()

  local writeEntries = entriesOf(state.lists.write)
  local readEntries  = entriesOf(state.lists.read, isSetting)
  local all = {}
  for _, entry in ipairs(writeEntries) do all[#all + 1] = entry end
  for _, entry in ipairs(readEntries) do all[#all + 1] = entry end
  if #all == 0 then return finishSync() end

  state.client:settings(settingsQuery(all), function(err, remote, kind)
    if err then
      Log.warn("Settings synchronisation failed: %s", err)
      if kind == "auth" then stop(err) end
      return finishSync()
    end
    local references = App.Sync.references()
    local writes, pending = {}, {}
    for _, entry in ipairs(writeEntries) do
      local value = reconcile(entry, remote, references)
      if value then
        writes[entry.module] = writes[entry.module] or {}
        writes[entry.module][entry.id] = value
        pending[entry.name] = value
      end
    end
    for _, entry in ipairs(readEntries) do
      local value = App.Catalog.present(entry, remoteValue(remote, entry))
      App.Vars.publish(entry, value)
      App.Display.set(entry, value)
    end
    App.Sync.saveReferences(references)
    if next(writes) == nil then return finishSync() end

    state.client:writeSettings(writes, function(werr, wkind)
      if werr then
        Log.error("Writing settings failed: %s; variables reset to the inverter's values", werr)
        for name in pairs(pending) do
          local entry = App.Catalog.get(name)
          showSetting(entry, App.Sync.normalize(entry, remoteValue(remote, entry)))
        end
        if wkind == "auth" then stop(werr) end
        return finishSync()
      end
      verifyWrites(pending, 1)
    end)
  end)
end

-- Actions ----------------------------------------------------------------------

--- fibaro.call(id, "set", name, value): change a setting listed in writeValues.
function App.set(name, value)
  if not (state.writeSet and state.writeSet[name]) then
    return Log.warn("set: '%s' is not listed in writeValues", tostring(name))
  end
  App.Vars.set(name, tostring(value))
  App.syncSettings()
end

--- Handler for the Refresh button.
function App.refresh()
  Log.info("Manual refresh")
  App.poll()
  App.syncSettings()
end
