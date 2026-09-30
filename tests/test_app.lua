-- Tests for the Plenticore QuickApp. Run with: python tools/run_tests.py
-- AES-GCM is verified byte for byte by the login test (payload and tag).
-- luacheck: globals QuickAppChild

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
  passphrase = "correct horse", rounds = 100, sessionToken = "session-token-42",
  clientNonce = "AQIDBAUGBwgJCgsM",
  serverNonce = "c2VydmVyLW5vbmNlLTEyMzQ1Ng==",
  salt = "MDEyMzQ1Njc4OWFiY2RlZg==",
  proof = "jhm+htiEcuFhtl9vx/hB2Uiyttaz11sEZXnmTfcc5Tk=",
  signature = "WTVBeJLnm0rM6uA06wAdECuAFrOz6vT5hKyOP0diQkg=",
  iv = "ZGVmZ2hpamtsbW5vcHFycw==",
  payload = "iAzwoLUvW+8K7bR35kvx9g==",
  tag = "aH3u10UW8wfjSyO8lHeBAg==",
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

test("three-way decision table", function()
  eq(Sync.decide("20", "20", "20"), "none")
  eq(Sync.decide("30", "20", "20"), "write", "changed locally")
  eq(Sync.decide("20", "40", "20"), "adopt", "changed on the inverter")
  eq(Sync.decide("30", "40", "20"), "conflict", "both changed: inverter wins")
  eq(Sync.decide("40", "40", "20"), "adopt", "both changed to the same value")
  eq(Sync.decide("", "40", "20"), "adopt", "empty variable")
  eq(Sync.decide("30", "40", nil), "adopt", "first run takes the inverter's value")
  eq(Sync.decide("30", nil, "20"), "none", "inverter value unknown")
end)

test("settings are normalized and validated against the inverter's limits", function()
  local minSoc = Catalog.get("batteryMinSoc")
  eq(Sync.normalize(minSoc, "50.0"), "50")
  eq(Sync.normalize(Catalog.get("activePowerLimitation"), "8499.9990234375"), "8499.999")
  local meta = { type = "byte", min = 5, max = 100 }
  eq(Sync.validate(minSoc, "30", meta), "30")
  eq(select(2, Sync.validate(minSoc, "150", meta)), "must be between 5 and 100")
  eq(select(2, Sync.validate(minSoc, "12.5", meta)), "must be a whole number")
  eq(select(2, Sync.validate(minSoc, "abc", meta)), "is not a number")
  local slots = Catalog.get("batteryTimeControlMon")
  eq(Sync.validate(slots, string.rep("0", 96)), string.rep("0", 96))
  ok(select(2, Sync.validate(slots, string.rep("0", 95))))
  ok(select(2, Sync.validate(slots, string.rep("3", 96))))
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

test("removing variables keeps configuration and restores masked passwords", function()
  controller()
  local qa = restart()
  qa.variables["password"] = "stored-value"
  DEVICES[100].properties = { quickAppVariables = {
    { name = "host", type = "string", value = "192.0.2.5" },
    { name = "password", type = "password", value = "****" },
    { name = "pvPower", type = "string", value = "1000" },
    { name = "batterySoc", type = "string", value = "50" },
  } }
  api.get = function(path) if path == "/devices/100" then return DEVICES[100], 200 end end
  local written
  api.put = function(_, body) written = body.properties.quickAppVariables; return {}, 200 end
  App.Vars.init(qa)
  App.Vars.removeUnlisted({ pvPower = true })
  local names = {}
  for _, v in ipairs(written) do names[#names + 1] = v.name end
  eq(names, { "host", "password", "pvPower" })
  eq(written[2].value, "stored-value")
end)
