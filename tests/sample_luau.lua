type Point = { x: number, y: number? }
export type Fn<T> = (a: T, b: string) -> T
local function add<T>(a: number, b: number): number
    return a + b
end
local count: number = 0
for i = 1, 10 do
    if i % 2 == 0 then continue end
    count += i
end
local name = "Bob"
local msg = `hello {name}, count={count + 1}!`
local v = if count > 5 then "big" else "small"
local n = (count :: number) * 0b101 + 1_000
local t = {1, 2, 3, ["k"] = {a = 1}}
local s = 0
for k, val in ipairs(t) do s += val end
print(msg, v, n, s, add(1, 2))
local big = 0
for i = 1, 300000 do big = big + (i % 7) end
print("loop", big)
