-- Catalog: every value this QuickApp can read or write, with its source on
-- the inverter, unit and access. The README documents the same list.
--
-- kind "process": measured value, read-only.
-- kind "setting": inverter setting, read-write.
-- kind "info":    device information, read-only.

App.Catalog = {}
local Catalog = App.Catalog

local LOCAL   = "devices:local"
local AC      = "devices:local:ac"
local BATTERY = "devices:local:battery"
local METER   = "devices:local:powermeter"
local STAT    = "scb:statistic:EnergyFlow"

local INVERTER_STATES = {
  [0]  = "Off",
  [1]  = "Init",
  [2]  = "IsoMeas",
  [3]  = "GridCheck",
  [4]  = "StartUp",
  [6]  = "FeedIn",
  [7]  = "Throttled",
  [8]  = "ExtSwitchOff",
  [9]  = "Update",
  [10] = "Standby",
  [11] = "GridSync",
  [12] = "GridPreCheck",
  [13] = "GridSwitchOff",
  [14] = "Overheating",
  [15] = "Shutdown",
  [16] = "ImproperDcVoltage",
  [17] = "ESB",
  [18] = "Unknown",
}

local ENERGY_MANAGER_STATES = {
  [0]  = "Idle",
  [2]  = "EmergencyBatteryCharge",
  [8]  = "WinterModeStep1",
  [16] = "WinterModeStep2",
}

local BATTERY_CONTROL = {
  [0] = "internal",
  [1] = "digitalIO",
  [2] = "modbus",
}

local BATTERY_TYPES = {
  [0]     = "none",
  [2]     = "PIKO Battery Li",
  [4]     = "BYD",
  [8]     = "BMZ",
  [16]    = "AXIstorage Li SH",
  [64]    = "LG",
  [512]   = "Pylontech Force H",
  [1024]  = "AXIstorage Li SV",
  [4096]  = "Dyness Tower",
  [8192]  = "VARTA.wall",
  [16384] = "ZYC",
}

local POWER_METER  = "com.fibaro.powerMeter"
local ENERGY_METER = "com.fibaro.energyMeter"
local SENSOR       = "com.fibaro.multilevelSensor"

local list = {}

local function add(entry)
  list[#list + 1] = entry
end

-- Instantaneous power in W.
local function power(name, module, id, rateType)
  add({ name = name, kind = "process", module = module, id = id, unit = "W", decimals = 0, deadband = 10,
        child = { type = POWER_METER, rateType = rateType } })
end

-- Energy in kWh (reported in Wh), for today and since commissioning.
local function energy(name, id, rateType)
  for _, period in ipairs({ "Day", "Total" }) do
    add({ name = name .. period, kind = "process", module = STAT, id = "Statistic:" .. id .. ":" .. period,
          unit = "kWh", scale = 0.001, decimals = 2, deadband = 0.01,
          child = { type = ENERGY_METER, rateType = rateType, storeEnergyData = period == "Total" } })
  end
end

local function percent(name, module, id)
  add({ name = name, kind = "process", module = module, id = id, unit = "%", decimals = 0, deadband = 1,
        child = { type = SENSOR } })
end

-- format: "number", "switch" (0/1) or "slots" (96 quarter hours).
local function setting(name, id, unit, format)
  add({ name = name, kind = "setting", module = LOCAL, id = id, unit = unit, format = format })
end

-- Measured values ------------------------------------------------------------

-- Dc_P includes the battery on hybrid inverters, so PV power is the sum of the strings.
add({ name = "pvPower", kind = "process", unit = "W", decimals = 0, deadband = 10,
      sum = { { "devices:local:pv1", "P" }, { "devices:local:pv2", "P" }, { "devices:local:pv3", "P" } },
      child = { type = POWER_METER, rateType = "production" } })

--    name               module               id            rateType
power("pv1Power",        "devices:local:pv1", "P",          "production")
power("pv2Power",        "devices:local:pv2", "P",          "production")
power("pv3Power",        "devices:local:pv3", "P",          "production")
power("acPower",         AC,                  "P",          "production")
power("homePower",       LOCAL,               "Home_P",     "consumption")
power("homeFromPv",      LOCAL,               "HomePv_P",   "consumption")
power("homeFromBattery", LOCAL,               "HomeBat_P",  "consumption")
power("homeFromGrid",    LOCAL,               "HomeGrid_P", "consumption")
power("gridPower",       METER,               "P",          "consumption")
power("batteryPower",    BATTERY,             "P",          nil)

percent("batterySoc", BATTERY, "SoC")

add({ name = "batteryCycles",      kind = "process", module = BATTERY, id = "Cycles",
      unit = "", decimals = 0, deadband = 1 })
add({ name = "inverterState",      kind = "process", module = LOCAL,   id = "Inverter:State",
      unit = "", enum = INVERTER_STATES })
add({ name = "energyManagerState", kind = "process", module = LOCAL,   id = "EM_State",
      unit = "", enum = ENERGY_MANAGER_STATES })

--     name                 statistic           rateType
energy("yield",             "Yield",            "production")
energy("home",              "EnergyHome",       "consumption")
energy("homeFromGrid",      "EnergyHomeGrid",   "consumption")
energy("homeFromPv",        "EnergyHomePv",     "consumption")
energy("homeFromBattery",   "EnergyHomeBat",    "consumption")
energy("batteryChargePv",   "EnergyChargePv",   "consumption")
energy("batteryChargeGrid", "EnergyChargeGrid", "consumption")
energy("batteryDischarge",  "EnergyDischarge",  "production")

percent("autarkyDay",         STAT, "Statistic:Autarky:Day")
percent("selfConsumptionDay", STAT, "Statistic:OwnConsumptionRate:Day")

-- Settings -------------------------------------------------------------------

--      name                         setting                               unit  format
setting("batteryMinSoc",             "Battery:MinSoc",                     "%",  "number")
setting("batteryMinHomeConsumption", "Battery:MinHomeComsumption",         "W",  "number")
setting("batterySmartControl",       "Battery:SmartBatteryControl:Enable", "",   "switch")
setting("batteryDynamicSoc",         "Battery:DynamicSoc:Enable",          "",   "switch")
setting("batteryStrategy",           "Battery:Strategy",                   "",   "number")
setting("batteryTimeControl",        "Battery:TimeControl:Enable",         "",   "switch")
for _, day in ipairs({ "Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun" }) do
  setting("batteryTimeControl" .. day, "Battery:TimeControl:Conf" .. day, "", "slots")
end
setting("activePowerLimitation",     "Inverter:ActivePowerLimitation",     "W",  "number")
setting("shadowManagement",          "Generator:ShadowMgmt:Enable",        "",   "number")

-- Device information ---------------------------------------------------------

add({ name = "model",                  kind = "info", module = LOCAL,
      ids = { "Branding:ProductName1", "Branding:ProductName2" } })
add({ name = "firmwareVersion",        kind = "info", module = LOCAL, id = "Properties:VersionMC" })
add({ name = "batteryType",            kind = "info", module = LOCAL, id = "Battery:Type",
      enum = BATTERY_TYPES })
add({ name = "batteryExternalControl", kind = "info", module = LOCAL, id = "Battery:ExternControl",
      enum = BATTERY_CONTROL })

-- Access -----------------------------------------------------------------------

Catalog.ALL = list

local byName = {}
for _, entry in ipairs(list) do byName[entry.name] = entry end

function Catalog.get(name)
  return byName[name]
end

function Catalog.readable(_entry) return true end
function Catalog.writable(entry) return entry.kind == "setting" end
function Catalog.childCapable(entry) return entry.child ~= nil end

--- Parse a comma-separated list of names. accept(entry) filters allowed entries.
-- Returns the names (unique, in order) and the names that were not accepted.
function Catalog.parseList(text, accept)
  local names, invalid, seen = {}, {}, {}
  for raw in tostring(text or ""):gmatch("[^,%s]+") do
    local entry = byName[raw]
    if entry and accept(entry) then
      if not seen[raw] then names[#names + 1], seen[raw] = raw, true end
    else
      invalid[#invalid + 1] = raw
    end
  end
  return names, invalid
end

--- The raw process value of an entry from processdata[module][id]; a sum adds
-- up the sources the device offers.
function Catalog.raw(entry, processdata)
  if entry.sum then
    local total, found = 0, false
    for _, source in ipairs(entry.sum) do
      local module = processdata[source[1]]
      local value  = module and module[source[2]]
      if type(value) == "number" then total, found = total + value, true end
    end
    return found and total or nil
  end
  local module = processdata[entry.module]
  return module and module[entry.id]
end

--- The public value of a raw value: scaled, rounded or mapped to text.
function Catalog.present(entry, raw)
  if raw == nil then return nil end
  if entry.enum then
    local code = math.tointeger(tonumber(raw))
    return entry.enum[code] or tostring(raw)
  end
  if type(raw) ~= "number" then return raw end
  local value = raw * (entry.scale or 1)
  if entry.decimals then
    local factor = 10 ^ entry.decimals
    value = math.floor(value * factor + 0.5) / factor
    if entry.decimals == 0 then value = math.tointeger(value) or value end
  end
  return value
end

--- True if a new value differs enough from the last published one.
function Catalog.changed(entry, old, new)
  if old == nil or type(old) ~= type(new) then return true end
  if type(new) == "number" and entry.deadband then return math.abs(new - old) >= entry.deadband end
  return old ~= new
end
