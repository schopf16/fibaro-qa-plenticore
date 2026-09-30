-- App: reads the values selected in readValues/childValues, synchronises the
-- settings selected in writeValues, and keeps the status line up to date.
--
-- All project code lives in the global App table (App.Catalog, App.Kostal,
-- App.Sync, App.Vars, App.Children, App.Store, App.Crypto).

App = {}

App.STRINGS = Strings

local LIST_LENGTH = 2000

--- Project variables, added to Config.COMMON (logLevel, language).
App.CONFIG = {
  { name = "host", type = "host", required = true },
  { name = "password", type = "secret", required = true },
  { name = "pollIntervalSec", type = "integer", default = 30, min = 10, max = 3600 },
  { name = "readValues", type = "string", maxLength = LIST_LENGTH,
    default = "pvPower, homePower, gridPower, batteryPower, batterySoc, yieldDay" },
  { name = "writeValues", type = "string", maxLength = LIST_LENGTH, default = "batteryMinSoc, batterySmartControl" },
  { name = "childValues", type = "string", maxLength = LIST_LENGTH, default = "none" },
}

App.UI = {
  text = { btnRefresh = "ui.refresh" },
  statusLabel = "lblStatus",
}

local SETTINGS_SYNC_MS = 5 * 60 * 1000
local MAX_RETRY_MS = 10 * 60 * 1000

local state = {}

-- Lists ----------------------------------------------------------------------

local function isProcess(entry) return entry.kind == "process" end

--- Parse the three lists. Returns lists or nil, problems (list of text).
function App.parseLists(cfg)
  local problems, lists = {}, {}
  local specs = {
    { key = "read", variable = "readValues", accept = App.Catalog.readable },
    { key = "write", variable = "writeValues", accept = App.Catalog.writable },
    { key = "children", variable = "childValues", accept = App.Catalog.childCapable },
  }
  for _, spec in ipairs(specs) do
    local text = cfg[spec.variable]
    if text == nil or Util.trim(text):lower() == "none" then text = "" end
    local names, invalid = App.Catalog.parseList(text, spec.accept)
    lists[spec.key] = names
    if #invalid > 0 then problems[#problems + 1] = spec.variable .. ": " .. Util.join(invalid) end
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

-- Start ----------------------------------------------------------------------

--- Called once by Boot.run with a valid configuration.
function App.start(qa, cfg)
  local lists, problems = App.parseLists(cfg)
  if not lists then
    for _, problem in ipairs(problems) do
      Log.error("Unknown or not allowed value names in %s; the README lists all valid names", problem)
    end
    Ui.setStatus("lib.status.notConfigured", { names = "readValues / writeValues / childValues" })
    return
  end

  state = {
    qa = qa, lists = lists, intervalMs = cfg.pollIntervalSec * 1000, failures = 0, online = nil,
    readSet = {}, writeSet = {}, available = nil, meta = nil, existingIds = nil,
  }
  for _, name in ipairs(lists.read) do state.readSet[name] = true end
  for _, name in ipairs(lists.write) do state.writeSet[name] = true end

  App.Store.init(qa)
  App.Vars.init(qa)
  local keep = {}
  for name in pairs(state.readSet) do keep[name] = true end
  for name in pairs(state.writeSet) do keep[name] = true end
  App.Vars.removeUnlisted(keep)
  App.Children.sync(qa, lists.children)
  Log.info("Reading %s value(s), synchronising %s setting(s), %s child device(s)",
    #lists.read, #lists.write, #lists.children)

  state.client = App.Kostal.new({ host = cfg.host, password = cfg.password })
  Ui.setStatus("status.loggingIn")
  App.connect()
end

-- Failure handling -------------------------------------------------------------

local function onFailure(err, kind, retry)
  state.failures = state.failures + 1
  if kind == "auth" then
    -- Retrying a rejected password could lock the account; wait for a new configuration.
    Log.error("%s; stopped until the QuickApp variables are saved again", err)
    Ui.setStatus("status.authFailed")
    state.online, state.stopped = false, true
    Timer.cancelAll()
    return
  end
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
    local any = false
    for _, source in ipairs(entry.sum or { { entry.module, entry.id } }) do
      any = request(source[1], source[2]) or any
    end
    if any then entries[#entries + 1] = entry end
  end
  for _, entry in ipairs(entriesOf(state.lists.read, isProcess)) do add(entry) end
  for _, entry in ipairs(entriesOf(state.lists.children)) do add(entry) end
  add(App.Catalog.get("pvPower"))
  add(App.Catalog.get("batterySoc"))
  return query, entries
end

local function checkLocalChanges()
  local references = App.Sync.references()
  for _, entry in ipairs(entriesOf(state.lists.write)) do
    local localValue = App.Sync.normalize(entry, App.Vars.get(entry.name))
    if localValue ~= "" and references[entry.name] ~= nil and localValue ~= references[entry.name] then
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
      values[entry.name] = App.Catalog.present(entry, App.Catalog.raw(entry, processdata))
      if state.readSet[entry.name] then App.Vars.publish(entry, values[entry.name]) end
    end
    App.Children.update(values, state.existingIds)
    if state.online ~= true then Log.info("Inverter online") end
    state.online, state.failures = true, 0
    Ui.setStatus("status.online", {
      pv = values.pvPower or "-", soc = values.batterySoc or "-", time = os.date("%H:%M"),
    })
    checkLocalChanges()
    Timer.after("poll", state.intervalMs, App.poll)
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
    for _, id in ipairs(entry.ids) do parts[#parts + 1] = module[id] or "" end
    return Util.trim(table.concat(parts, " "))
  end
  return module[entry.id]
end

local function metaOf(entry)
  return state.meta and state.meta[entry.module] and state.meta[entry.module][entry.id]
end

local function verifyWrites(pending, references)
  local entries = {}
  for name in pairs(pending) do entries[#entries + 1] = App.Catalog.get(name) end
  state.client:settings(settingsQuery(entries), function(err, remote)
    if err then
      Log.error("Cannot read back written settings: %s", err)
    else
      for name, wanted in pairs(pending) do
        local entry = App.Catalog.get(name)
        local actual = App.Sync.normalize(entry, remoteValue(remote, entry))
        if actual == wanted then
          Log.info("Setting '%s' changed to %s on the inverter", name, wanted)
        else
          Log.error("The inverter kept '%s' at %s instead of %s", name, actual, wanted)
        end
        references[name] = actual
        App.Vars.set(name, actual)
      end
      App.Sync.saveReferences(references)
    end
    state.syncing = false
    if state.syncAgain then state.syncAgain = false; App.syncSettings() end
  end)
end

--- Three-way synchronisation of the listed settings and refresh of read-only
-- settings and device information.
function App.syncSettings()
  if state.stopped or not state.meta then return end
  if state.syncing then state.syncAgain = true; return end
  state.syncing = true
  Timer.cancel("settings")
  Timer.after("settings", SETTINGS_SYNC_MS, App.syncSettings)
  state.existingIds = App.Children.existingIds()

  local writeEntries = entriesOf(state.lists.write)
  local readEntries = entriesOf(state.lists.read, function(e) return e.kind ~= "process" end)
  local all = {}
  for _, entry in ipairs(writeEntries) do all[#all + 1] = entry end
  for _, entry in ipairs(readEntries) do all[#all + 1] = entry end
  if #all == 0 then state.syncing = false; return end

  state.client:settings(settingsQuery(all), function(err, remote)
    if err then
      state.syncing = false
      return Log.warn("Settings synchronisation failed: %s", err)
    end
    local references = App.Sync.references()
    local writes, pending = {}, {}
    for _, entry in ipairs(writeEntries) do
      local name = entry.name
      local remoteText = App.Sync.normalize(entry, remoteValue(remote, entry))
      local localText = App.Sync.normalize(entry, App.Vars.get(name))
      local action = App.Sync.decide(localText, remoteText, references[name])
      if action == "write" then
        local valid, reason = App.Sync.validate(entry, localText, metaOf(entry))
        if valid then
          writes[entry.module] = writes[entry.module] or {}
          writes[entry.module][entry.id] = valid
          pending[name] = valid
        else
          Log.warn("Value %s for '%s' rejected: %s; variable reset to the inverter's value %s",
            localText, name, reason, remoteText)
          App.Vars.set(name, remoteText)
        end
      elseif action == "adopt" or action == "conflict" then
        if action == "conflict" then
          Log.warn("'%s' was changed locally (%s) and on the inverter (%s); the inverter's value applies",
            name, localText, remoteText)
        elseif references[name] ~= nil then
          Log.info("'%s' was changed on the inverter: %s -> %s", name, references[name], remoteText)
        end
        references[name] = remoteText
        App.Vars.set(name, remoteText)
      end
    end
    for _, entry in ipairs(readEntries) do
      App.Vars.publish(entry, App.Catalog.present(entry, remoteValue(remote, entry)))
    end
    App.Sync.saveReferences(references)

    if next(writes) == nil then
      state.syncing = false
      if state.syncAgain then state.syncAgain = false; App.syncSettings() end
      return
    end
    state.client:writeSettings(writes, function(werr)
      if werr then
        Log.error("Writing settings failed: %s; variables reset to the inverter's values", werr)
        for name in pairs(pending) do
          local entry = App.Catalog.get(name)
          App.Vars.set(name, references[name] or App.Sync.normalize(entry, remoteValue(remote, entry)))
        end
        state.syncing = false
        return
      end
      verifyWrites(pending, references)
    end)
  end)
end

-- Actions ------------------------------------------------------------------------

--- fibaro.call(id, "set", name, value): change a setting listed in writeValues.
function App.set(name, value)
  if not state.writeSet or not state.writeSet[name] then
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
