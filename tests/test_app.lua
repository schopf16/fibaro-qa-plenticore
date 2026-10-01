-- Tests for the Plenticore QuickApp. Run with: python tools/run_tests.py
-- AES-GCM is verified byte for byte by the login test (payload and tag).
-- luacheck: globals QuickAppChild QuickApp

-- Crypto -------------------------------------------------------------------

local C = App.Crypto

test("SHA-256 and HMAC match the standard test vectors", function()
  eq(C.hex(C.sha256("abc")), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
  eq(C.hex(C.hmac("Jefe", "what do ya want for nothing?")),
    "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
end)

test("PBKDF2 matches the reference, also when computed in slices", function()
  local expected = "c5e478d59288c841aa530db6845c4c8d962893a001ce4e11a4963873aa98134a"
  eq(C.hex(C.pbkdf2("password", "salt", 4096)), expected)
  local step = C.pbkdf2Stepper("password", "salt", 4096)
  local result
  repeat result = step(333) until result
  eq(C.hex(result), expected)
end)

test("Base64 round trip", function()
  for _, text in ipairs({ "", "f", "fo", "foo", "foob", "fooba", "foobar" }) do
    eq(C.b64decode(C.b64encode(text)), text)
  end
  eq(C.b64encode("foobar"), "Zm9vYmFy")
end)

-- Kostal login ---------------------------------------------------------------

-- Reference values computed with an independent Python implementation.
local V = {
  passphrase = "correct horse", rounds = 10000, sessionToken = "session-token-42",
  clientNonce = "AQIDBAUGBwgJCgsM",
  serverNonce = "c2VydmVyLW5vbmNlLTEyMzQ1Ng==",
  salt = "MDEyMzQ1Njc4OWFiY2RlZg==",
  proof = "SXMd4+oJ8Sv6Hd1VrJTVb+atv/NEyNk8PGA7LHso6yQ=",
  signature = "44O/5MPi2MiKz3/YFYaL5VveoQaeA7kNNqy75ID9MCI=",
  iv = "ZGVmZ2hpamtsbW5vcHFycw==",
  payload = "EniaLG9zBqVm2Vj8R/WMqg==",
  tag = "veN/AoHsUWwFuJ8Rjn8GSg==",
}

local function bytes(from, count)
  local out = {}
  for i = 0, count - 1 do out[#out + 1] = string.char(from + i) end
  return table.concat(out)
end

-- A fake inverter that checks every login step against the reference values.
local function fakeInverter(opts)
  opts = opts or {}
  local inverter = { calls = {}, logins = 0, sessionValid = true }
  inverter.transport = function(method, url, headers, body, callback)
    local path = url:match("/api/v1/(.*)$")
    local request = body and json.decode(body) or nil
    inverter.calls[#inverter.calls + 1] = method .. " " .. path
    if opts.unreachable then return callback(nil, nil, "timeout") end
    if path == "auth/start" then
      eq(request.nonce, V.clientNonce, "client nonce")
      local start = { nonce = V.serverNonce, salt = V.salt, rounds = V.rounds, transactionId = "tx1" }
      return callback(200, json.encode(start))
    elseif path == "auth/finish" then
      if opts.wrongPassword then return callback(400, "{}") end
      eq(request.proof, V.proof, "proof")
      local signature = opts.badSignature and V.proof or V.signature
      return callback(200, json.encode({ ["token"] = V.sessionToken, signature = signature }))
    elseif path == "auth/create_session" then
      eq(request.iv, V.iv, "iv")
      eq(request.payload, V.payload, "payload")
      eq(request.tag, V.tag, "tag")
      inverter.logins, inverter.sessionValid = inverter.logins + 1, true
      return callback(200, json.encode({ sessionId = "S" .. inverter.logins }))
    elseif path == "processdata" then
      if not inverter.sessionValid then return callback(401, "{}") end
      eq(headers.Authorization, "Session S" .. inverter.logins)
      return callback(200, json.encode({ { moduleid = "devices:local:battery",
        processdata = { { id = "SoC", value = 55.0 }, { id = "P", value = "bad" } } } }))
    end
    callback(404, "{}")
  end
  return inverter
end

local function newClient(inverter)
  local calls = 0
  return App.Kostal.new({
    host = "192.0.2.5", ["password"] = V.passphrase, transport = inverter.transport,
    random = function(n)
      calls = calls + 1
      return calls % 2 == 1 and bytes(1, n) or bytes(100, n)
    end,
  })
end

local function run(fn)
  local result
  fn(function(...) result = table.pack(...) end)
  for _ = 1, 100 do
    if result then break end
    advance(0)
  end
  ok(result, "callback never called")
  return table.unpack(result, 1, result.n)
end

test("login follows SCRAM and AES-GCM exactly and reads process data", function()
  local inverter = fakeInverter()
  local client = newClient(inverter)
  local err, values = run(function(done) client:processdata({ ["devices:local:battery"] = { "SoC", "P" } }, done) end)
  eq(err, nil)
  eq(values["devices:local:battery"].SoC, 55.0)
  eq(values["devices:local:battery"].P, nil, "non-numbers are dropped")
  eq(inverter.logins, 1)
  ok(not logText():find(V.passphrase, 1, true), "password in log")
end)

test("an expired session logs in again without repeating the key derivation", function()
  local inverter = fakeInverter()
  local client = newClient(inverter)
  run(function(done) client:processdata({ ["devices:local:battery"] = { "SoC" } }, done) end)
  inverter.sessionValid = false
  local err = run(function(done) client:processdata({ ["devices:local:battery"] = { "SoC" } }, done) end)
  eq(err, nil)
  eq(inverter.logins, 2)
  eq(pendingTimers(), 0, "second login must use the cached key")
end)

test("login errors are classified", function()
  local _, _, kind = run(function(done) newClient(fakeInverter({ wrongPassword = true })):processdata({}, done) end)
  eq(kind, "auth")
  _, _, kind = run(function(done) newClient(fakeInverter({ unreachable = true })):processdata({}, done) end)
  eq(kind, "unreachable")
  local err
  err, _, kind = run(function(done) newClient(fakeInverter({ badSignature = true })):processdata({}, done) end)
  eq(kind, "protocol")
  ok(err:find("signature", 1, true), err)
end)

-- Platform -------------------------------------------------------------------

test("a challenge with too few key derivation rounds is refused before any proof is sent", function()
  for _, rounds in ipairs({ 1, 9999 }) do
    local inverter = fakeInverter()
    local transport = inverter.transport
    inverter.transport = function(method, url, headers, body, callback)
      if url:find("auth/start", 1, true) then
        inverter.calls[#inverter.calls + 1] = method .. " auth/start"
        return callback(200, json.encode({ nonce = V.serverNonce, salt = V.salt, rounds = rounds, transactionId = "t" }))
      end
      return transport(method, url, headers, body, callback)
    end
    local err, _, kind = run(function(done) newClient(inverter):processdata({}, done) end)
    eq(kind, "protocol")
    ok(err:find("asked for " .. rounds .. " key derivation rounds", 1, true), err)
    eq(inverter.calls, { "POST auth/start" }, "no proof sent")
  end
end)

test("https connects to the same API over an encrypted connection", function()
  local urls = {}
  local client = App.Kostal.new({ host = "192.0.2.5", ["password"] = "x", https = true,
    transport = function(_, url, _, _, callback) urls[#urls + 1] = url; callback(nil, nil, "timeout") end })
  run(function(done) client:processdata({}, done) end)
  eq(urls[1], "https://192.0.2.5/api/v1/auth/start")
end)

test("random bytes do not depend on math.random and never repeat", function()
  math.randomseed(1)
  local a = C.randomBytes(16)
  math.randomseed(1)
  local b = C.randomBytes(16)
  ok(a ~= b, "same bytes after the same math.random seed")
  eq(#C.randomBytes(12), 12)
  eq(#C.randomBytes(45), 45)
  local seen = {}
  for _ = 1, 200 do
    local bytes16 = C.randomBytes(16)
    ok(not seen[bytes16], "repeated random bytes")
    seen[bytes16] = true
  end
  C.addEntropy("nonce from the inverter")
  eq(#C.randomBytes(16), 16)
end)

test("a Lua with 32-bit integers stops with a clear status instead of computing wrong values", function()
  local qa = FakeQA.new({})
  I18n.register(App.STRINGS)
  I18n.setLanguage("en")
  Ui.init(qa, App.UI)
  local real = math.maxinteger
  math.maxinteger = 2147483647 -- luacheck: ignore 122 (simulates a 32-bit Lua)
  local started, err = pcall(App.start, qa, { pollIntervalSec = 30 })
  math.maxinteger = real -- luacheck: ignore 122
  ok(started, err)
  eq(qa.properties.log, "Controller not supported - 64-bit Lua required")
  ok(logText():find("needs 64-bit integers", 1, true), logText())
end)

-- Catalog --------------------------------------------------------------------

local Catalog = App.Catalog

test("catalog names are unique and complete", function()
  local seen = {}
  for _, entry in ipairs(Catalog.ALL) do
    ok(not seen[entry.name], "duplicate " .. entry.name)
    seen[entry.name] = true
    ok(entry.kind == "process" or entry.kind == "setting" or entry.kind == "info", entry.name)
    ok(entry.sum or (entry.module and (entry.id or entry.ids)), entry.name)
  end
  ok(Catalog.get("batteryMinSoc") and Catalog.get("yieldTotal") and Catalog.get("inverterState"))
end)

test("lists accept only allowed names", function()
  local names, invalid = Catalog.parseList("pvPower, batterySoc,pvPower  yieldDay, nonsense", Catalog.readable)
  eq(names, { "pvPower", "batterySoc", "yieldDay" })
  eq(invalid, { "nonsense" })
  names, invalid = Catalog.parseList("batteryMinSoc, pvPower", Catalog.writable)
  eq(names, { "batteryMinSoc" })
  eq(invalid, { "pvPower" })
  names, invalid = Catalog.parseList("inverterState", Catalog.childCapable)
  eq(names, {})
  eq(invalid, { "inverterState" }, "text values cannot be children")
end)

test("values are scaled, rounded and mapped", function()
  eq(Catalog.present(Catalog.get("yieldTotal"), 20539280.4), 20539.28)
  eq(Catalog.present(Catalog.get("pvPower"), 1041.6), 1042)
  local pv = Catalog.get("pvPower")
  eq(Catalog.raw(pv, { ["devices:local:pv1"] = { P = 700.25 }, ["devices:local:pv2"] = { P = 300.25 } }), 1000.5)
  eq(Catalog.raw(pv, { ["devices:local"] = { Dc_P = 1041 } }), nil, "battery DC power is not PV power")
  eq(Catalog.present(Catalog.get("inverterState"), 6.0), "FeedIn")
  eq(Catalog.present(Catalog.get("batteryExternalControl"), "0"), "internal")
  eq(Catalog.changed(Catalog.get("pvPower"), 1000, 1005), false, "inside the dead band")
  eq(Catalog.changed(Catalog.get("pvPower"), 1000, 1010), true)
end)

-- Sync -----------------------------------------------------------------------

local Sync = App.Sync

test("settings are normalized and validated against the inverter's limits", function()
  local minSoc = Catalog.get("batteryMinSoc")
  eq(Sync.normalize(minSoc, "50.0"), "50")
  eq(Sync.normalize(Catalog.get("activePowerLimitation"), "8499.9990234375"), "8499.999")
  eq(Sync.normalize(Catalog.get("batterySmartControl"), true), "1", "a switch sends true/false")
  local meta = { type = "byte", min = 5, max = 100 }
  eq(Sync.validate(minSoc, "30", meta), "30")
  eq(Sync.validate(minSoc, 30, meta), "30")
  eq(select(2, Sync.validate(minSoc, "150", meta)), "must be between 5 and 100")
  eq(select(2, Sync.validate(minSoc, "12.5", meta)), "must be a whole number")
  eq(select(2, Sync.validate(minSoc, "abc", meta)), "is not a number")
  eq(Sync.normalize(minSoc, "1e20"), "100000000000000000000", "beyond the integer range")
  eq(Sync.normalize(minSoc, "-1e19"), "-10000000000000000000")
  eq(Sync.normalize(minSoc, "1e999"), "1e999", "infinity stays text")
  eq(select(2, Sync.validate(minSoc, "1e20", meta)), "must be between 5 and 100")
  eq(select(2, Sync.validate(minSoc, 1e20, meta)), "must be between 5 and 100")
  eq(select(2, Sync.validate(minSoc, "1e999", meta)), "is not a number")
  eq(select(2, Sync.validate(minSoc, "-1e999", meta)), "is not a number")
  eq(select(2, Sync.validate(minSoc, "nan", meta)), "is not a number")
  local slots = Catalog.get("batteryTimeControlMon")
  eq(Sync.validate(slots, string.rep("0", 96)), string.rep("0", 96))
  ok(select(2, Sync.validate(slots, string.rep("0", 95))))
  ok(select(2, Sync.validate(slots, string.rep("3", 96))))
  eq(Sync.publishable(minSoc, "30"), 30)
  eq(Sync.publishable(slots, string.rep("0", 96)), string.rep("0", 96))
end)

-- Options and lists --------------------------------------------------------------

test("options in the code are validated with clear messages", function()
  local schema = Config.merge(Config.OPTIONS, App.OPTION_SCHEMA)
  local options, problems = Config.loadOptions(schema, App.OPTIONS)
  eq(#problems, 0)
  eq(options.pollIntervalSec, 10)
  eq(options.deadband, true)
  options, problems = Config.loadOptions(schema, { pollIntervalSec = 2, deadband = "maybe" })
  eq(options.pollIntervalSec, 10)
  eq(options.deadband, true)
  eq(problems[1].reason, "must be between 5 and 3600")
  eq(problems[2].reason, "must be true or false")
end)

test("the value table lists readValues, then writeValues, with controls for writable settings", function()
  local lists = { read = { "pvPower", "batteryMinSoc" }, write = { "batteryMinSoc", "batterySmartControl",
    "batteryTimeControlMon" }, children = {} }
  local spec = App.tableSpec(lists)
  eq(#spec, 4)
  eq(spec[1], { name = "pvPower" })
  eq(spec[2].control.type, "slider", "listed in both: shown once, with its control")
  eq(spec[3].control.type, "switch")
  eq(spec[4].control, nil, "time control has no control")
  local readOnly = App.tableSpec({ read = { "batterySmartControl" }, write = {}, children = {} })
  eq(readOnly[1].control, nil, "read-only settings get no control")
end)

-- Values ---------------------------------------------------------------------------

local function valuesQA()
  local qa = FakeQA.new({})
  qa.id = 100
  return qa
end

test("all values are published in one JSON variable, only when they change", function()
  local qa = valuesQA()
  local writes = 0
  local setVariable = qa.setVariable
  function qa:setVariable(...) writes = writes + 1; return setVariable(self, ...) end
  App.Values.init(qa, true)
  App.Values.set(Catalog.get("pvPower"), 1000)
  App.Values.set(Catalog.get("batterySoc"), 50)
  App.Values.flush()
  eq(json.decode(qa.variables.values), { pvPower = 1000, batterySoc = 50 })
  App.Values.set(Catalog.get("pvPower"), 1005)
  App.Values.flush()
  eq(writes, 1, "5 W is inside the dead band")
  App.Values.set(Catalog.get("pvPower"), 1020)
  App.Values.flush()
  eq(writes, 2)
  eq(json.decode(qa.variables.values).pvPower, 1020)
end)

test("a change to or from zero is always published", function()
  local qa = valuesQA()
  App.Values.init(qa, true)
  App.Values.set(Catalog.get("pvPower"), 8)
  App.Values.flush()
  App.Values.set(Catalog.get("pvPower"), 0)
  App.Values.flush()
  eq(json.decode(qa.variables.values).pvPower, 0, "8 W -> 0 W")
  App.Values.set(Catalog.get("pvPower"), 3)
  App.Values.flush()
  eq(json.decode(qa.variables.values).pvPower, 3, "0 W -> 3 W")
  ok(Catalog.changed(Catalog.get("pvPower"), 5, 0))
  ok(not Catalog.changed(Catalog.get("pvPower"), 5, 9))
end)

test("without dead band every change is published", function()
  local qa = valuesQA()
  App.Values.init(qa, false)
  App.Values.set(Catalog.get("pvPower"), 1000)
  App.Values.flush()
  App.Values.set(Catalog.get("pvPower"), 1001)
  App.Values.flush()
  eq(json.decode(qa.variables.values).pvPower, 1001)
end)

-- Display --------------------------------------------------------------------

local Display = App.Display
QuickApp = QuickApp or {} -- main.lua is not loaded in the tests

test("every value has a name in all four languages", function()
  for _, entry in ipairs(Catalog.ALL) do
    local texts = App.STRINGS["value." .. entry.name]
    ok(texts, "no name for " .. entry.name)
    for _, lang in ipairs(I18n.LANGUAGES) do ok(texts[lang], entry.name .. " lacks " .. lang) end
  end
end)

test("values are shown with unit, switches as on/off, time control as windows", function()
  I18n.register(App.STRINGS)
  I18n.setLanguage("de")
  eq(Display.format(Catalog.get("pvPower"), 1042), "1042 W")
  eq(Display.format(Catalog.get("yieldDay"), 27.19), "27.19 kWh")
  eq(Display.format(Catalog.get("batterySmartControl"), "1"), "ein")
  eq(Display.format(Catalog.get("inverterState"), "FeedIn"), "FeedIn")
  eq(Display.format(Catalog.get("pvPower"), nil), "-")
  local monday = string.rep("0", 47) .. "2" .. string.rep("0", 48)
  eq(Display.format(Catalog.get("batteryTimeControlMon"), monday), "11:45-12:00 (2)")
  eq(Display.slots(string.rep("1", 8) .. string.rep("0", 84) .. string.rep("2", 4)), "00:00-02:00 (1), 23:00-24:00 (2)")
  eq(Display.slots(string.rep("0", 96)), "-")
end)

local SLIDER = { type = "slider", min = 5, max = 100, step = 1 }

test("the value table shows names, values, switches and sliders", function()
  I18n.register(App.STRINGS)
  I18n.setLanguage("fr")
  local qa = FakeQA.new({})
  local writes = 0
  local updateView = qa.updateView
  function qa:updateView(...) writes = writes + 1; return updateView(self, ...) end
  local spec = { { name = "pvPower" }, { name = "batterySmartControl", control = { type = "switch" } },
                 { name = "batteryMinSoc", control = SLIDER } }
  Display.init(qa, spec, function() end)
  Display.set(Catalog.get("pvPower"), 500)
  Display.set(Catalog.get("batterySmartControl"), 1)
  Display.set(Catalog.get("batteryMinSoc"), 30)
  Display.render()
  eq({ qa.views.lblName1.text, qa.views.lblValue1.text }, { "Puissance PV", "500 W" })
  eq(qa.views.swValue2.value, "true")
  eq({ qa.views.lblValue3.text, qa.views.sldValue3.value }, { "30 %", "30" })
  local first = writes
  Display.render()
  eq(writes, first, "unchanged elements are not written again")
  Display.set(Catalog.get("pvPower"), 520)
  Display.render()
  eq(writes, first + 1, "only the changed value label is written")
end)

test("text from the inverter is escaped before it is shown", function()
  local qa = FakeQA.new({})
  Display.init(qa, { { name = "model" } }, function() end)
  Display.set(Catalog.get("model"), '<img src=x onerror="alert(1)">')
  Display.render()
  eq(qa.views.lblValue1.text, "&lt;img src=x onerror=&quot;alert(1)&quot;&gt;")
end)

test("moving a slider or flipping a switch calls the handler with the setting and value", function()
  local calls = {}
  local spec = { { name = "batterySmartControl", control = { type = "switch" } },
                 { name = "batteryMinSoc", control = SLIDER } }
  Display.init(FakeQA.new({}), spec, function(name, value) calls[#calls + 1] = { name, value } end)
  QuickApp.uiswValue1OnToggled(nil, { elementName = "swValue1", values = { true } })
  QuickApp.uisldValue2OnChanged(nil, { elementName = "sldValue2", values = { 40 } })
  eq(calls, { { "batterySmartControl", true }, { "batteryMinSoc", 40 } })
end)

local function row(...)
  local components = {}
  for i, name in ipairs({ ... }) do components[i] = { name = name, type = "label" } end
  return { type = "horizontal", components = components }
end

local function rowNames(rows)
  local names = {}
  for i, r in ipairs(rows) do names[i] = r.components[1].name end
  return names
end

test("the layout has one row per value, a switch beside its name and a slider row below", function()
  local spec = { { name = "pvPower" }, { name = "batterySmartControl", control = { type = "switch" } },
                 { name = "batteryMinSoc", control = SLIDER } }
  local rows = Display.layout(spec)
  eq(rowNames(rows), { "lblStatus", "lblName1", "lblName2", "lblName3", "sldValue3", "btnRefresh" })
  eq(rows[3].components[2].type, "switch")
  eq({ rows[5].components[1].min, rows[5].components[1].max }, { "5", "100" })
  eq(rows[6].components[1].eventBinding.onReleased[1].params.args, { "onReleased", "btnRefresh" })
  eq(Display.callbacks(spec), {
    { name = "btnRefresh", eventType = "onReleased", callback = "uibtnRefreshOnReleased" },
    { name = "swValue2",   eventType = "onToggled",  callback = "uiswValue2OnToggled" },
    { name = "sldValue3",  eventType = "onChanged",  callback = "uisldValue3OnChanged" },
  })
end)

test("the editor's copy of the layout has the same elements without event bindings", function()
  local qa = FakeQA.new({})
  qa.id = 100
  local rows = Display.layout({ { name = "batteryMinSoc", control = SLIDER } })
  local items = Display.viewLayout(qa, rows)["$jason"].body.sections.items
  eq(Display.signature(items), Display.signature(rows))
  eq(items[#items].components[1].eventBinding, nil)
  ok(rows[#rows].components[1].eventBinding, "the UI itself keeps its bindings")
end)

test("spacers and row types of the editor do not count as a layout change", function()
  local editor = { { type = "vertical", components = { { name = "lblStatus", type = "label" }, { type = "space" } } } }
  eq(Display.signature(editor), Display.signature({ row("lblStatus") }))
end)

local function deviceWith(uiView, viewLayout)
  return { properties = { uiView = uiView, viewLayout = viewLayout } }
end

test("a layout the editor broke is rebuilt completely, and only once", function()
  local qa = FakeQA.new({})
  qa.id = 100
  local spec = { { name = "pvPower" } }
  local savedGet, savedPut = api.get, api.put
  local stored = deviceWith({ row("lblName1", "lblValue1") }, {})
  local puts = 0
  api.get = function() return stored, 200 end
  api.put = function(_, body) puts = puts + 1; stored = body; return {}, 200 end
  eq(Display.ensureLayout(qa, spec), true, "status line and refresh button were missing")
  eq(rowNames(stored.properties.uiView), { "lblStatus", "lblName1", "btnRefresh" })
  eq(Display.ensureLayout(qa, spec), false, "complete layout: no further restart")
  stored.properties.viewLayout = {}
  eq(Display.ensureLayout(qa, spec), true, "a stale editor copy is rewritten as well")
  eq(puts, 2)
  api.get, api.put = savedGet, savedPut
end)

test("a rejected or discarded layout is reported and does not restart the QuickApp", function()
  local qa = FakeQA.new({})
  qa.id = 100
  local savedGet, savedPut = api.get, api.put
  api.get = function() return deviceWith({ row("lblStatus"), row("btnRefresh") }), 200 end
  api.put = function() return nil, 500 end
  eq(Display.ensureLayout(qa, { { name = "pvPower" } }), false)
  ok(logText():find("Cannot save the user interface layout (HTTP 500)", 1, true), logText())
  api.put = function() return {}, 200 end
  eq(Display.ensureLayout(qa, { { name = "pvPower" } }), false, "the controller kept the old layout")
  ok(logText():find("did not keep the user interface layout", 1, true), logText())
  api.get, api.put = savedGet, savedPut
end)

-- Children ---------------------------------------------------------------------

-- A small model of the controller's device list.
local DEVICES, NEXT_ID, STORAGE

local function childObject(id)
  local child = { id = id }
  function child:getVariable(name) return (DEVICES[self.id] and DEVICES[self.id].vars[name]) or "" end
  function child:setVariable(name, value) DEVICES[self.id].vars[name] = value end
  function child:updateProperty(name, value) if DEVICES[self.id] then DEVICES[self.id][name] = value end end
  return child
end

local function controller()
  DEVICES, NEXT_ID = { [100] = { id = 100, roomID = 7, vars = {} } }, 200
  QuickAppChild = {}
  api.get = function(path)
    local parent = path:match("^/devices%?parentId=(%d+)$")
    if parent then
      local list = {}
      for _, device in pairs(DEVICES) do
        if device.parentId == tonumber(parent) then list[#list + 1] = device end
      end
      return list, 200
    end
    local id = path:match("^/devices/(%d+)$")
    if id then return DEVICES[tonumber(id)], 200 end
    return API[path], API[path] and 200 or 404
  end
  api.put = function(path, body)
    local device = DEVICES[tonumber(path:match("(%d+)$"))]
    for k, v in pairs(body.properties or {}) do device[k] = v end
    device.roomID = body.roomID or device.roomID
    return {}, 200
  end
  api.delete = function(path)
    DEVICES[tonumber(path:match("(%d+)$"))] = nil
    return {}, 200
  end
end

local function restart()
  local qa = FakeQA.new({})
  qa.id, qa.name, qa.storage = 100, "Plenticore", STORAGE
  function qa:internalStorageGet(key) return self.storage[key] end
  function qa:internalStorageSet(key, value) self.storage[key] = value end
  function qa:initChildDevices()
    self.childDevices = {}
    for id, device in pairs(DEVICES) do
      if device.parentId == self.id then self.childDevices[id] = childObject(id) end
    end
  end
  function qa:createChildDevice(options)
    NEXT_ID = NEXT_ID + 1
    DEVICES[NEXT_ID] = { id = NEXT_ID, parentId = self.id, name = options.name, type = options.type, vars = {} }
    self.childDevices[NEXT_ID] = childObject(NEXT_ID)
    return self.childDevices[NEXT_ID]
  end
  App.Store.init(qa)
  return qa
end

local function childIds()
  local ids = {}
  for id, device in pairs(DEVICES) do
    if device.parentId == 100 then ids[device.vars.key or ("?" .. id)] = id end
  end
  return ids
end

test("children are created once and keep their IDs across restarts", function()
  controller()
  STORAGE = {}
  App.Children.sync(restart(), { "pvPower", "yieldTotal" })
  local first = childIds()
  eq(DEVICES[first.yieldTotal].unit, "kWh")
  eq(DEVICES[first.yieldTotal].rateType, "production")
  eq(DEVICES[first.yieldTotal].storeEnergyData, true)
  eq(DEVICES[first.pvPower].roomID, 7, "created in the parent's room")
  DEVICES[first.pvPower].name = "renamed by the user"
  for _ = 1, 3 do App.Children.sync(restart(), { "pvPower", "yieldTotal" }) end
  eq(childIds(), first)
  eq(DEVICES[first.pvPower].name, "renamed by the user", "names are never changed")
end)

test("changing the list adds and deletes only the affected children", function()
  controller()
  STORAGE = {}
  App.Children.sync(restart(), { "pvPower", "yieldTotal" })
  local before = childIds()
  App.Children.sync(restart(), { "pvPower", "batterySoc" })
  local after = childIds()
  eq(after.pvPower, before.pvPower, "unchanged child keeps its ID")
  eq(after.yieldTotal, nil, "removed from the list: deleted")
  ok(after.batterySoc and after.batterySoc ~= before.yieldTotal, "added: new child")
end)

test("a lost ID mapping adopts existing children instead of duplicating them", function()
  controller()
  STORAGE = {}
  App.Children.sync(restart(), { "pvPower" })
  local before = childIds()
  STORAGE = {}
  App.Children.sync(restart(), { "pvPower" })
  eq(childIds(), before)
end)

test("a child deleted by hand is not recreated while running, but at the next start", function()
  controller()
  STORAGE = {}
  App.Children.sync(restart(), { "pvPower" })
  local id = childIds().pvPower
  DEVICES[id] = nil
  App.Children.update({ pvPower = 500 }, App.Children.existingIds())
  App.Children.update({ pvPower = 600 }, App.Children.existingIds())
  eq(childIds().pvPower, nil, "not recreated while running")
  local warnings = 0
  for _, entry in ipairs(LOGS) do if entry.message:find("was deleted", 1, true) then warnings = warnings + 1 end end
  eq(warnings, 1, "reported once")
  App.Children.sync(restart(), { "pvPower" })
  ok(childIds().pvPower and childIds().pvPower ~= id, "recreated at the next start")
end)

test("foreign children are never touched", function()
  controller()
  STORAGE = {}
  DEVICES[150] = { id = 150, parentId = 100, vars = {} }
  DEVICES[151] = { id = 151, parentId = 100, vars = { key = "somethingElse" } }
  App.Children.sync(restart(), { "pvPower" })
  ok(DEVICES[150] and DEVICES[151])
end)

local function variablesOn(list)
  DEVICES[100].properties = { quickAppVariables = list }
  api.get = function(path) if path == "/devices/100" then return DEVICES[100], 200 end end
  local puts = 0
  api.put = function(_, body)
    puts = puts + 1
    DEVICES[100].properties.quickAppVariables = body.properties.quickAppVariables
    return {}, 200
  end
  return function() return puts end
end

local function variableNames()
  local names = {}
  for _, v in ipairs(DEVICES[100].properties.quickAppVariables) do names[#names + 1] = v.name end
  return names
end

local LISTS_100 = { read = { "pvPower" }, write = { "batteryMinSoc" }, children = {} }

test("the migration removes only variables of 1.0.0, keeps the password, and runs once", function()
  controller()
  STORAGE = {}
  local qa = restart()
  qa.variables["password"] = "stored-value"
  local puts = variablesOn({
    { name = "host", type = "string", value = "192.0.2.5" },
    { name = "password", type = "password", value = "****" },
    { name = "pvPower", type = "string", value = "1000" },
    { name = "batteryMinSoc", type = "string", value = "5" },
    { name = "batterySoc", type = "string", value = "created by the user" },
    { name = "logLevel", type = "string", value = "info" },
    { name = "values", type = "string", value = "{}" },
  })
  App.Values.init(qa, true)
  eq(App.Values.removeObsolete(LISTS_100), true, "a restart follows")
  eq(variableNames(), { "host", "password", "batterySoc", "values" }, "batterySoc was not listed: kept")
  eq(DEVICES[100].properties.quickAppVariables[2].value, "stored-value")
  DEVICES[100].properties.quickAppVariables[#DEVICES[100].properties.quickAppVariables + 1] =
    { name = "pvPower", type = "string", value = "created by the user later" }
  App.Values.init(restart(), true)
  eq(App.Values.removeObsolete(LISTS_100), false, "runs only once")
  eq(puts(), 1)
end)

test("a new installation is not migrated, also not a variable the user created before the first start", function()
  controller()
  STORAGE = {}
  local puts = variablesOn({ { name = "host", type = "string", value = "192.0.2.5" },
                             { name = "pvPower", type = "string", value = "created by the user" } })
  App.Values.init(restart(), true)
  eq(App.Values.removeObsolete(LISTS_100), false)
  eq(puts(), 0)
end)

test("a migration without access to the variable list is tried again at the next start", function()
  controller()
  STORAGE = {}
  local qa = restart()
  local version1 = { { name = "pvPower", type = "string", value = "1000" },
                     { name = "language", type = "string", value = "auto" } }
  variablesOn(version1)
  api.get = function() return nil, 500 end
  App.Values.init(qa, true)
  eq(App.Values.removeObsolete(LISTS_100), false)
  variablesOn(version1)
  App.Values.init(restart(), true)
  eq(App.Values.removeObsolete(LISTS_100), true, "removed at the next start")
end)

test("a migration the controller does not keep is reported and does not restart", function()
  controller()
  STORAGE = {}
  local qa = restart()
  variablesOn({ { name = "host", type = "string", value = "192.0.2.5" },
                { name = "pvPower", type = "string", value = "1000" },
                { name = "logLevel", type = "string", value = "info" } })
  api.put = function() return {}, 200 end
  App.Values.init(qa, true)
  eq(App.Values.removeObsolete(LISTS_100), false)
  ok(logText():find("did not remove the variables", 1, true), logText())
  App.Values.init(restart(), true)
  eq(App.Values.removeObsolete(LISTS_100), false, "not tried again")
end)

-- Polling ----------------------------------------------------------------------------

test("an error while processing a reading does not stop polling", function()
  controller()
  STORAGE = {}
  local qa = restart()
  local everything = setmetatable({}, { __index = function() return setmetatable({}, {
    __index = function() return true end }) end })
  local readings = 0
  local savedNew, savedUpdate = App.Kostal.new, App.Children.update
  App.Kostal.new = function()
    return {
      processdataIds = function(_, callback) callback(nil, everything) end,
      settingsMeta   = function(_, callback) callback(nil, {}) end,
      settings       = function(_, _, callback) callback(nil, {}) end,
      processdata    = function(_, _, callback)
        readings = readings + 1
        Safe.call("kostal.http", callback, nil, {})
      end,
    }
  end
  local failed = false
  App.Children.update = function(...)
    if not failed then failed = true; error("unexpected data") end
    return savedUpdate(...)
  end
  App.start(qa, { host = "192.0.2.5", ["password"] = "x", readValues = "pvPower", writeValues = "none",
                  childValues = "none" }, { pollIntervalSec = 10, deadband = true, https = false })
  eq(readings, 1)
  ok(logText():find("unexpected data", 1, true), "the error is logged")
  advance(10000)
  eq(readings, 2, "the next reading still happens")
  App.Kostal.new, App.Children.update = savedNew, savedUpdate
  Timer.cancelAll()
end)
