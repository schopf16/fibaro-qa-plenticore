-- Tests for App. Run with: python tools/run_tests.py

test("poll interval is validated", function()
  local field = App.CONFIG[1]
  eq(Config.parse(field, "60"), 60)
  eq(select(2, Config.parse(field, "5")), "must be between 30 and 86400")
end)

test("start polls immediately and shows the status", function()
  local qa = FakeQA.new({ pollIntervalSec = "60" })
  ok(Boot.run(qa, App), "Boot.run failed")
  advance(0)
  ok(qa.properties.log:find("Updated at"), "status not shown: " .. tostring(qa.properties.log))
end)
