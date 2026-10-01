-- Kostal: client for the local REST API (/api/v1) of KOSTAL PLENTICORE and
-- PIKO IQ inverters.
--
-- Login (SCRAM-SHA256 + AES-256-GCM session): the password never leaves the
-- QuickApp. The PBKDF2 step (tens of thousands of rounds) runs in slices on
-- timers so the QuickApp stays responsive; its result is kept in memory for
-- later logins and never stored or logged.
--
-- With https, the connection is encrypted. The inverter's certificate is
-- self-signed, so it is accepted without verification: this protects against
-- reading the traffic, not against a device that impersonates the inverter.
-- The login itself detects such a device (server signature, minimum rounds).
--
-- All callbacks receive (err, data, kind). kind is nil on success, otherwise
-- "unreachable" (network), "auth" (credentials rejected) or "protocol".

App.Kostal = {}
local Kostal = App.Kostal
Kostal.__index = Kostal

local TIMEOUT_MS   = 10000
local PBKDF2_SLICE = 500
local MIN_ROUNDS   = 10000   -- the inverter uses 29000; fewer would make the proof easy to brute-force
local MAX_ROUNDS   = 1000000

local function httpTransport(method, url, headers, body, callback)
  net.HTTPClient():request(url, {
    options = { method = method, headers = headers, data = body, timeout = TIMEOUT_MS,
                checkCertificate = false },
    success = Safe.wrap("kostal.http", function(response) callback(response.status, response.data) end),
    error = Safe.wrap("kostal.http", function(message) callback(nil, nil, tostring(message)) end),
  })
end

--- opts: host, password, https, user ("user" = plant owner), transport, random (for tests).
function Kostal.new(opts)
  return setmetatable({
    base      = (opts.https and "https://" or "http://") .. opts.host .. "/api/v1/",
    password  = opts.password,
    user      = opts.user or "user",
    transport = opts.transport or httpTransport,
    random    = opts.random or App.Crypto.randomBytes,
    session   = nil,
    salted    = {}, -- salt|rounds -> PBKDF2 result, memory only
    loggingIn = false,
    waiting   = {}, -- callbacks waiting for the running login
  }, Kostal)
end

--- One HTTP call without login handling. callback(err, data, status)
function Kostal:call(method, path, body, callback)
  local headers = { ["Content-Type"] = "application/json", ["Accept"] = "application/json" }
  if self.session then headers["Authorization"] = "Session " .. self.session end
  local payload = body ~= nil and json.encode(body) or nil
  self.transport(method, self.base .. path, headers, payload, function(status, text, transportError)
    if not status then return callback("not reachable (" .. tostring(transportError) .. ")") end
    local data = nil
    if type(text) == "string" and text ~= "" then
      local ok, decoded = pcall(json.decode, text)
      if ok then data = decoded end
    end
    if status < 200 or status > 299 then return callback("HTTP " .. tostring(status), data, status) end
    callback(nil, data, status)
  end)
end

-- SCRAM values for one login. Pure function, tested against a reference.
function Kostal.scram(user, clientNonce, start, salted)
  local C = App.Crypto
  local clientKey = C.hmac(salted, "Client Key")
  local storedKey = C.sha256(clientKey)
  local authMsg = string.format("n=%s,r=%s,r=%s,s=%s,i=%d,c=biws,r=%s",
    user, clientNonce, start.nonce, start.salt, start.rounds, start.nonce)
  local signature = C.hmac(storedKey, authMsg)
  local proof = {}
  for i = 1, #clientKey do proof[i] = string.char(clientKey:byte(i) ~ signature:byte(i)) end
  return {
    proof           = C.b64encode(table.concat(proof)),
    serverSignature = C.hmac(C.hmac(salted, "Server Key"), authMsg),
    sessionKey      = C.hmac(storedKey, "Session Key" .. authMsg .. clientKey),
  }
end

-- Body of auth/create_session: the token encrypted with the session key.
function Kostal.sessionRequest(transactionId, sessionKey, token, iv)
  local C = App.Crypto
  local payload, tag = C.aesGcmEncrypt(sessionKey, iv, token)
  return {
    transactionId = transactionId,
    iv            = C.b64encode(iv),
    tag           = C.b64encode(tag),
    payload       = C.b64encode(payload),
  }
end

local function validStart(start)
  return type(start) == "table" and type(start.nonce) == "string" and type(start.salt) == "string"
    and type(start.transactionId) == "string" and math.type(start.rounds) == "integer"
end

-- PBKDF2 in slices, cached per salt and round count.
function Kostal:saltedPassword(salt, rounds, callback)
  local key = salt .. "|" .. rounds
  if self.salted[key] then return callback(self.salted[key]) end
  local step = App.Crypto.pbkdf2Stepper(self.password, App.Crypto.b64decode(salt), rounds)
  local started = os.clock()
  local function slice()
    local result = step(PBKDF2_SLICE)
    if not result then return Timer.after("kostal.pbkdf2", 0, slice) end
    local seconds = string.format("%.1f", os.clock() - started)
    Log.debug("Login: key derivation (%s rounds) took %s s CPU", rounds, seconds)
    self.salted[key] = result
    callback(result)
  end
  slice()
end

--- Log in and create a session. Concurrent calls wait for the same login.
function Kostal:login(callback)
  self.waiting[#self.waiting + 1] = callback
  if self.loggingIn then return end
  self.loggingIn, self.session = true, nil

  local function done(err, kind)
    self.loggingIn = false
    local waiting = self.waiting
    self.waiting = {}
    for _, cb in ipairs(waiting) do cb(err, nil, kind) end
  end
  local function failed(step, err, status)
    if not status then return done("login: inverter " .. err, "unreachable") end
    if status == 400 or status == 401 or status == 403 then
      return done("login rejected at " .. step .. " (" .. err .. ") - check the password", "auth")
    end
    done("login: " .. step .. " failed (" .. err .. ")", "protocol")
  end

  local clientNonce = App.Crypto.b64encode(self.random(12))
  Log.debug("Login: starting as %s", self.user)
  self:call("POST", "auth/start", { username = self.user, nonce = clientNonce }, function(err, start, status)
    if err then return failed("auth/start", err, status) end
    if not validStart(start) then return done("login: unexpected auth/start response", "protocol") end
    if start.rounds < MIN_ROUNDS or start.rounds > MAX_ROUNDS then
      -- Never send a proof for such a challenge: it would allow a fast offline password search.
      return done(string.format("login: the inverter asked for %d key derivation rounds (allowed %d to %d)"
        .. " - is another device at this address?", start.rounds, MIN_ROUNDS, MAX_ROUNDS), "protocol")
    end
    App.Crypto.addEntropy(start.nonce .. start.salt .. start.transactionId)
    self:saltedPassword(start.salt, start.rounds, function(salted)
      local scram = Kostal.scram(self.user, clientNonce, start, salted)
      local finish = { transactionId = start.transactionId, proof = scram.proof }
      self:call("POST", "auth/finish", finish, function(err2, fin, status2)
        if err2 then return failed("auth/finish", err2, status2) end
        if type(fin) ~= "table" or type(fin.token) ~= "string" or type(fin.signature) ~= "string" then
          return done("login: unexpected auth/finish response", "protocol")
        end
        if App.Crypto.b64decode(fin.signature) ~= scram.serverSignature then
          return done("login: the inverter's signature is wrong - is another device at this address?", "protocol")
        end
        App.Crypto.addEntropy(fin.token)
        local body = Kostal.sessionRequest(start.transactionId, scram.sessionKey, fin.token, self.random(16))
        self:call("POST", "auth/create_session", body, function(err3, session, status3)
          if err3 then return failed("auth/create_session", err3, status3) end
          if type(session) ~= "table" or type(session.sessionId) ~= "string" then
            return done("login: unexpected auth/create_session response", "protocol")
          end
          self.session = session.sessionId
          Log.info("Logged in to the inverter as %s", self.user == "user" and "plant owner" or self.user)
          done(nil)
        end)
      end)
    end)
  end)
end

--- A call that needs a session: logs in first, and once more after a 401.
function Kostal:request(method, path, body, callback)
  local function attempt(mayRelogin)
    self:call(method, path, body, function(err, data, status)
      if status == 401 and mayRelogin then
        Log.debug("Session expired; logging in again")
        self.session = nil
        return self:login(function(loginErr, _, kind)
          if loginErr then return callback(loginErr, nil, kind) end
          attempt(false)
        end)
      end
      if err then return callback(path .. ": " .. err, nil, status and "protocol" or "unreachable") end
      callback(nil, data)
    end)
  end
  if self.session then return attempt(true) end
  self:login(function(err, _, kind)
    if err then return callback(err, nil, kind) end
    attempt(false)
  end)
end

-- Call fn(moduleId, item) for every item of a module list response:
-- [{ moduleid = "...", <field> = { item, ... } }, ...]
local function eachItem(data, field, fn)
  for _, module in ipairs(data) do
    if type(module) == "table" and type(module.moduleid) == "string" and type(module[field]) == "table" then
      for _, item in ipairs(module[field]) do fn(module.moduleid, item) end
    end
  end
end

local function moduleList(query, idsField)
  local body = {}
  for moduleId, ids in pairs(query) do body[#body + 1] = { moduleid = moduleId, [idsField] = ids } end
  table.sort(body, function(a, b) return a.moduleid < b.moduleid end)
  return body
end

--- Read settings. query: { [moduleId] = { id, ... } }
-- callback(err, values, kind) with values[moduleId][id] = string.
function Kostal:settings(query, callback)
  self:request("POST", "settings", moduleList(query, "settingids"), function(err, data, kind)
    if err then return callback(err, nil, kind) end
    if type(data) ~= "table" then return callback("settings: unexpected response", nil, "protocol") end
    local values = {}
    eachItem(data, "settings", function(moduleId, item)
      if type(item) == "table" and type(item.id) == "string" and item.value ~= nil then
        values[moduleId] = values[moduleId] or {}
        values[moduleId][item.id] = tostring(item.value)
      end
    end)
    callback(nil, values)
  end)
end

--- Metadata of all settings. callback(err, meta, kind) with
-- meta[moduleId][id] = { type, min, max, access }.
function Kostal:settingsMeta(callback)
  self:request("GET", "settings", nil, function(err, data, kind)
    if err then return callback(err, nil, kind) end
    if type(data) ~= "table" then return callback("settings: unexpected response", nil, "protocol") end
    local meta = {}
    eachItem(data, "settings", function(moduleId, item)
      if type(item) == "table" and type(item.id) == "string" then
        meta[moduleId] = meta[moduleId] or {}
        meta[moduleId][item.id] = {
          type   = item.type,
          access = item.access,
          min    = tonumber(item.min),
          max    = tonumber(item.max),
        }
      end
    end)
    callback(nil, meta)
  end)
end

--- Write settings. values: { [moduleId] = { [id] = string } }. callback(err, kind)
function Kostal:writeSettings(values, callback)
  local body = {}
  for moduleId, settings in pairs(values) do
    local list = {}
    for id, value in pairs(settings) do list[#list + 1] = { id = id, value = tostring(value) } end
    table.sort(list, function(a, b) return a.id < b.id end)
    body[#body + 1] = { moduleid = moduleId, settings = list }
  end
  self:request("PUT", "settings", body, function(err, _, kind) callback(err, kind) end)
end

--- Process data identifiers the device offers. callback(err, ids, kind)
-- with ids[moduleId][id] = true.
function Kostal:processdataIds(callback)
  self:request("GET", "processdata", nil, function(err, data, kind)
    if err then return callback(err, nil, kind) end
    if type(data) ~= "table" then return callback("processdata: unexpected response", nil, "protocol") end
    local ids = {}
    eachItem(data, "processdataids", function(moduleId, id)
      ids[moduleId] = ids[moduleId] or {}
      ids[moduleId][id] = true
    end)
    callback(nil, ids)
  end)
end

--- Read process data. query: { [moduleId] = { id, ... } }
-- callback(err, values, kind) with values[moduleId][id] = number.
function Kostal:processdata(query, callback)
  self:request("POST", "processdata", moduleList(query, "processdataids"), function(err, data, kind)
    if err then return callback(err, nil, kind) end
    if type(data) ~= "table" then return callback("processdata: unexpected response", nil, "protocol") end
    local values = {}
    eachItem(data, "processdata", function(moduleId, item)
      local number = type(item) == "table" and type(item.id) == "string" and item.value
      if type(number) == "number" and number == number then
        values[moduleId] = values[moduleId] or {}
        values[moduleId][item.id] = number
      end
    end)
    callback(nil, values)
  end)
end
