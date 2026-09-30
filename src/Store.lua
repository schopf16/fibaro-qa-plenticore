-- Store: small persistent state in the QuickApp's internal storage, which is
-- not visible in the UI and survives restarts: child device IDs and the
-- reference values of the settings synchronisation.

App.Store = {}
local Store = App.Store

local qa = nil

function Store.init(quickApp)
  qa = quickApp
end

--- Stored table under `key`, or an empty table.
function Store.get(key)
  local read, raw = pcall(qa.internalStorageGet, qa, key)
  if not read or type(raw) ~= "string" or raw == "" then return {} end
  local decoded, value = pcall(json.decode, raw)
  if decoded and type(value) == "table" then return value end
  Log.warn("Internal storage '%s' is unreadable and is reset", key)
  return {}
end

function Store.set(key, value)
  local ok, err = pcall(qa.internalStorageSet, qa, key, json.encode(value))
  if not ok then Log.error("Cannot write internal storage '%s': %s", key, err) end
end
