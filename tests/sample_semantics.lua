local function counter() local c = 0 return function() c = c + 1 return c end end
local a, b = counter(), counter()
a() a() b()
assert(a() == 3 and b() == 2, "closures")
local function va(...) local n = select("#", ...) return n, ... end
local n, x, y = va(10, nil, 30)
assert(n == 3 and x == 10 and y == nil, "varargs")
local t = setmetatable({}, {__index = function(_, k) return k .. "!" end})
assert(t.foo == "foo!", "metatable")
local p, q = 1, 2
p, q = q, p
assert(p == 2 and q == 1, "swap")
local s = ("x"):rep(3) .. #"abc"
assert(s == "xxx3", "str")
local r = {}
for i = 1, 5 do r[#r + 1] = function() return i end end
assert(r[2]() == 2 and r[5]() == 5, "loop closures")
repeat local z = 5 until z == 5
local i = 0
while true do i = i + 1 if i > 3 then break end end
assert(i == 4)
-- hex-encoded second layer, decoded with gsub, run through loadstring (multi layer)
local hex = ("print('layer-two ok') return 42"):gsub(".", function(c) return ("%02x"):format(c:byte()) end)
local code = hex:gsub("%x%x", function(h) return string.char(tonumber(h, 16)) end)
local f = loadstring(code)
assert(f() == 42, "layer")
local env = getfenv()
assert(env.print ~= nil and typeof(env) == "table")
local ok, err = pcall(function() local q = nil; return q.x end)
assert(not ok, "pcall error")
print((function(...) return select("#", ...) end)(1, 2, 3))
print("ALL OK", math.floor(7 / 2), 7 // 2, 2 ^ 10, -3 % 5)
