-- App: the logic of this QuickApp.
--
-- All project code lives in the global App table (add sub-tables such as
-- App.Parser for larger parts), so nothing collides with the library.
-- Keep parsing and calculations free of fibaro.* / api.* calls: that part
-- runs in the offline tests on Lua 5.3.

App = {}

App.STRINGS = Strings

--- Project variables, added to Config.COMMON (logLevel, language).
App.CONFIG = {
  { name = "pollIntervalSec", type = "integer", default = 300, min = 30, max = 86400 },
}

App.UI = {
  text = { btnRefresh = "ui.refresh" },
  statusLabel = "lblStatus",
}

local config = nil

--- Called once by Boot.run with a valid configuration.
function App.start(_qa, cfg)
  config = cfg
  Timer.every("poll", cfg.pollIntervalSec * 1000, App.poll, { runNow = true })
end

--- One polling cycle. Replace the body with the real work.
function App.poll()
  Log.debug("Polling (interval %s s)", config.pollIntervalSec)
  Ui.setStatus("status.updated", { time = os.date("%H:%M") })
end

--- Handler for the Refresh button.
function App.refresh()
  Log.info("Manual refresh")
  App.poll()
end
