-- main: entry points only. Every QuickApp method passes straight to Safe.call,
-- so no error can crash the QuickApp or escape its log tag (tools/qa.py checks).
-- Button handlers must be named ui<elementId><Event>: the HC3 assigns exactly
-- these names when the .fqa is imported.

function QuickApp:onInit()
  Safe.call("onInit", Boot.run, self, App)
end

--- fibaro.call(id, "set", "batteryMinSoc", 30)
function QuickApp:set(name, value)
  Safe.call("set", App.set, name, value)
end

function QuickApp:uibtnRefreshOnReleased(event)
  Safe.call("btnRefresh", App.refresh, event)
end
