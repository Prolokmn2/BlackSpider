-- ============================================================================================
--  BlackSpider  --  SETTINGS.  Edit the values, then run this file.
--    executor : paste this whole file (or loadstring it) and execute
--    desktop  : lua settings.lua                      (run inside the BlackSpider folder)
--               lua settings.lua file=x.lua splitter=true     (command line overrides settings)
-- ============================================================================================

-- ------------------------------------------------------------------ INPUT  (code > link > file)
local file         = "obfuscated.lua"   -- file in your workspace folder
local link         = ""                 -- url to download first (executor only)
local code         = ""                 -- raw code, or a  loadstring(game:HttpGet("..."))()  line
local raw_name     = "output.txt"       -- where the downloaded `link` is saved ("" = don't save)
local out_dir      = "BlackSpider_out"  -- every result is written here

-- ------------------------------------------------------------------ MODE
local splitter     = false   -- true = ONLY split the 1-line wall into readable code (nothing is executed)
local spider       = false   -- true = follow loadstring(game:HttpGet(url)) chains and analyse every page
local follow_loader= true    -- with spider=false: still follow ONE get (pasted loader line)
local emulate      = true    -- fire the callbacks the script registers (:Connect, .OnClientEvent ...)

-- ------------------------------------------------------------------ SPLITTER
local split_out    = "split.lua"
local split_math   = true    -- calculate constant maths  (0X2e+5, 3*7, bit32.bxor(1,2), "a".."b" ...)
local split_dead   = true    -- remove branches whose condition is constant (if 1==2 then ... end)
local split_rename = false   -- rename obfuscated variable names to guessed readable ones
local split_inline = false   -- inline single-assignment literal locals
local split_wrap   = 100     -- wrap tables / call arguments longer than this many chars (0 = never)
local split_indent = 4       -- spaces per indent level
local split_then_run = false -- after splitting, ALSO run the sandbox analysis

-- ------------------------------------------------------------------ SANDBOX
local time_limit   = 90      -- cpu seconds per script
local echo_print   = true    -- show the script's own print() in the console
local net_lock     = true    -- refuse attempts to overwrite the http guards
local host_lock    = true    -- neutralise the host's own request functions during a run
local max_events   = 6000
local max_strings  = 8000

-- ------------------------------------------------------------------ SPIDER LIMITS
local spider_depth = 3
local spider_pages = 25
local spider_bytes = 3000000
local spider_allow = {}      -- {"raw.githubusercontent.com"}  -> only these domains may be fetched
-- discord / ip-logger domains are always denied (see src/config.lua SPIDER_DENY)

-- ------------------------------------------------------------------ CODE CLEANER (normal run)
local fold         = true    -- constant folding
local rename       = true    -- readable names
local inline       = true    -- inline literal locals
local dead         = true    -- drop dead branches

-- ------------------------------------------------------------------ WHERE THE SOURCE COMES FROM
local source       = "auto"            -- "auto" | "local" | "github"
local local_dir    = nil               -- nil = auto ("." on desktop, "BlackSpider" in an executor)
local repo, branch = "prolokmn2/BlackSpider", "main"

-- ============================================================================================
--  nothing below needs editing
-- ============================================================================================
local cfg = {
    TARGET_FILE = file, TARGET_URL = link, TARGET_CODE = code, RAW_FILENAME = raw_name, OUT_DIR = out_dir,
    SPLITTER = splitter, SPIDER = spider, FOLLOW_LOADER = follow_loader, EMULATE = emulate,
    SPLIT_OUT = split_out, SPLIT_FOLD_MATH = split_math, SPLIT_DEAD = split_dead, SPLIT_RENAME = split_rename,
    SPLIT_INLINE = split_inline, SPLIT_MAX_LINE = split_wrap, SPLIT_INDENT = split_indent, SPLIT_THEN_RUN = split_then_run,
    TIME_LIMIT = time_limit, ECHO_PRINT = echo_print, NET_LOCK = net_lock, HOST_LOCK = host_lock,
    MAX_EVENTS = max_events, MAX_STRINGS = max_strings,
    SPIDER_MAX_DEPTH = spider_depth, SPIDER_MAX_PAGES = spider_pages, SPIDER_MAX_BYTES = spider_bytes, SPIDER_ALLOW = spider_allow,
    CLEAN_FOLD = fold, CLEAN_RENAME = rename, CLEAN_INLINE = inline, CLEAN_DEAD = dead,
    SOURCE = source, REPO = repo, BRANCH = branch,
}

-- command line overrides (desktop):  key=value  (keys = the lowercase names above)
local MAP = { file = "TARGET_FILE", link = "TARGET_URL", code = "TARGET_CODE", raw_name = "RAW_FILENAME", out_dir = "OUT_DIR",
    splitter = "SPLITTER", spider = "SPIDER", follow_loader = "FOLLOW_LOADER", emulate = "EMULATE", split_out = "SPLIT_OUT",
    split_math = "SPLIT_FOLD_MATH", split_dead = "SPLIT_DEAD", split_rename = "SPLIT_RENAME", split_inline = "SPLIT_INLINE",
    split_wrap = "SPLIT_MAX_LINE", split_indent = "SPLIT_INDENT", split_then_run = "SPLIT_THEN_RUN", time_limit = "TIME_LIMIT",
    echo_print = "ECHO_PRINT", net_lock = "NET_LOCK", host_lock = "HOST_LOCK", spider_depth = "SPIDER_MAX_DEPTH",
    spider_pages = "SPIDER_MAX_PAGES", fold = "CLEAN_FOLD", rename = "CLEAN_RENAME", inline = "CLEAN_INLINE", dead = "CLEAN_DEAD",
    source = "SOURCE" }
if type(arg) == "table" then
    for _, a in ipairs(arg) do
        local k, v = tostring(a):match("^([%w_]+)=(.*)$")
        if k and MAP[k] then
            if v == "true" then v = true elseif v == "false" then v = false elseif tonumber(v) then v = tonumber(v) end
            cfg[MAP[k]] = v
        elseif k then print("[settings] unknown option '" .. k .. "'") end
    end
end

-- local folder: desktop = current dir, executor = workspace/BlackSpider
if not local_dir then
    local_dir = "BlackSpider"
    if io and io.open and not (type(isfile) == "function") then
        local f = io.open("src/util.lua", "rb")
        if f then f:close(); local_dir = "." end
    end
end
cfg.LOCAL_DIR = local_dir

local genv = (type(getgenv) == "function" and getgenv()) or _G
genv.BlackSpiderConfig = cfg

if type(dofile) == "function" and not (type(isfile) == "function") then
    dofile(local_dir .. "/loader.lua")                      -- desktop
else
    local src
    if type(isfile) == "function" and isfile(local_dir .. "/loader.lua") then src = readfile(local_dir .. "/loader.lua") end
    src = src or game:HttpGet("https://raw.githubusercontent.com/" .. repo .. "/" .. branch .. "/loader.lua")
    loadstring(src)()
end
