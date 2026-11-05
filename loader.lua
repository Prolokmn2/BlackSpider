-- BlackSpider loader  (github.com/prolokmn2/BlackSpider)
--
--   getgenv().BlackSpiderConfig = {            -- optional, anything from src/config.lua
--       TARGET_URL = "https://example.com/script.lua",
--       SPIDER     = true,
--   }
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/prolokmn2/BlackSpider/main/loader.lua"))()
--
-- SOURCE: "auto" (local BlackSpider/ folder if present, else GitHub) | "github" | "local"
local genv = (type(getgenv) == "function" and getgenv()) or _G
local USER = genv.BlackSpiderConfig or rawget(_G, "BlackSpiderConfig") or {}

local REPO     = USER.REPO or "prolokmn2/BlackSpider"
local BRANCH   = USER.BRANCH or "main"
local SOURCE   = USER.SOURCE or "auto"
local LOCALDIR = USER.LOCAL_DIR or "BlackSpider"
local RAW      = "https://raw.githubusercontent.com/" .. REPO .. "/" .. BRANCH .. "/"

-- order matters: every module only uses modules loaded before it
local MODULES = { "util", "config", "lexer", "parser", "state", "netguard", "compiler", "emulator",
    "env", "fetcher", "spider", "guesser", "splitter", "report", "main" }
local ALIAS = { netguard = "net", compiler = "compiler", main = "main" }   -- BS.<alias or name>

local compile = loadstring or load

local function http_get(url)
    local ok, res = pcall(function() return game:HttpGet(url) end)
    if ok and type(res) == "string" and res ~= "" then return res end
    local rq = (type(request) == "function" and request) or (type(http_request) == "function" and http_request)
        or (type(http) == "table" and http.request) or (type(syn) == "table" and syn.request)
    if rq then
        local ok2, r = pcall(rq, { Url = url, Method = "GET" })
        if ok2 and type(r) == "table" and (r.StatusCode or 200) == 200 and type(r.Body) == "string" then return r.Body end
    end
end

local function read_local(path)
    if type(isfile) == "function" and type(readfile) == "function" then
        if isfile(path) then
            local ok, s = pcall(readfile, path)
            if ok then return s end
        end
        return nil
    end
    local f = io and io.open and io.open(path, "rb")
    if f then local s = f:read("*a"); f:close(); return s end
end

local function fetch_module(name)
    local rel = "src/" .. name .. ".lua"
    if SOURCE ~= "github" then
        local s = read_local(LOCALDIR .. "/" .. rel)
        if s then return s, "local" end
    end
    if SOURCE ~= "local" then
        local s = http_get(RAW .. rel)
        if s and s:sub(1, 3) ~= "404" then return s, "github" end
    end
end

local BS = { user_cfg = USER }
for _, name in ipairs(MODULES) do
    local src, where = fetch_module(name)
    if not src then error("[BlackSpider] cannot load module '" .. name .. "' (SOURCE=" .. SOURCE .. ", repo " .. REPO .. ")", 0) end
    local chunk, cerr = compile(src, "=BlackSpider/" .. name)
    if not chunk then error("[BlackSpider] syntax error in " .. name .. ": " .. tostring(cerr), 0) end
    local installer = chunk()
    local ok, mod = pcall(installer, BS)
    if not ok then error("[BlackSpider] module '" .. name .. "' failed to initialise: " .. tostring(mod), 0) end
    BS[ALIAS[name] or name] = mod
end

genv.BlackSpider = BS
BS.main.start()
return BS
