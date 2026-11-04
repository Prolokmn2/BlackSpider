-- BlackSpider :: env.lua  --  the sandbox global table: fake executor, ghost objects (game, Players...),
-- hooked http vectors (NET GUARD), escape tripwires, loadstring that dumps + executes every layer.
return function(BS)
    local U, C, ST, NET, EM = BS.util, BS.config, BS.state, BS.net, BS.emulator
    local S, R = ST.S, ST.R
    local FAKE = BS.FAKE
    local log, behave, out, scan_string, rec_string = ST.log, ST.behave, ST.out, ST.scan_string, ST.rec_string
    local short, lit, json, clone, floor = U.short, U.lit, U.json, U.clone, math.floor
    local do_request, net_guard = NET.do_request, NET.net_guard

    local M = {}

    -- ============================================================ ghost objects
    -- A ghost accepts anything (get/set/call) and records it. Results of calls become r<N> ghosts so
    -- the guesser can rebuild  `local frame = Instance.new("Frame")`  style code.
    local ghost
    function ghost(name, over, parent, key, pname)
        over = over or {}
        local kids, mt = {}, {}
        local g = {}
        mt.__index = function(self, k)
            log("get", name .. "." .. tostring(k))
            if over[k] ~= nil then return over[k] end
            local v = kids[k]
            if v == nil then
                local nm2 = name .. (type(k) == "string" and ("." .. k) or ("[" .. lit(k) .. "]"))
                v = ghost(nm2, nil, self, k, name)
                kids[k] = v
            end
            return v
        end
        mt.__newindex = function(_, k, v)
            log("set", name .. "." .. tostring(k) .. " = " .. short(v))
            behave(name .. "." .. tostring(k) .. " = " .. lit(v))
            over[k] = v
            if type(v) == "string" then scan_string(name, v); rec_string("set", v, tostring(k)) end
            if type(v) == "function" then EM.poke(v, name .. "." .. tostring(k)) end
        end
        mt.__call = function(self, ...)
            local n = select("#", ...)
            local a1 = ...
            local callee, first = name, 1
            if parent ~= nil and n >= 1 and rawequal(a1, parent) then callee = pname .. ":" .. tostring(key); first = 2 end
            local parts = {}
            for i = first, n do parts[#parts + 1] = lit((select(i, ...))) end
            local text = callee .. "(" .. table.concat(parts, ", ") .. ")"
            log("call", text)
            R.rid = R.rid + 1
            local rid = R.rid
            R.defs["r" .. rid] = text
            behave(text, rid)
            for i = 1, n do
                local a = select(i, ...)
                if type(a) == "string" then
                    scan_string(name, a); rec_string("arg", a, name)
                    -- NET GUARD: unknown vector that is handed a url -> record + block
                    if a:find("^https?://") and not a:find("roblox%.com") and NET.net_hint(callee) then
                        do_request(callee, a, "GET", nil, nil, "UNKNOWN-VECTOR", true)
                    end
                elseif type(a) == "function" then EM.poke(a, pname or name) end
            end
            return ghost("r" .. rid)
        end
        mt.__tostring = function() return name end
        mt.__concat = function(a, b) return tostring(a) .. tostring(b) end
        mt.__len = function() return 0 end
        mt.__unm = function() return 0 end
        for _, op in ipairs({ "__add", "__sub", "__mul", "__div", "__mod", "__pow" }) do mt[op] = function() return 1 end end
        mt.__lt = function() return false end
        mt.__le = function() return false end
        return setmetatable(g, mt)
    end
    M.ghost = ghost

    -- minimal bit32 shim when the host has none
    local function mk_bit32()
        local MOD = 2 ^ 32
        local b = {}
        local function norm(x) return floor(x) % MOD end
        local function op(a, c, f)
            a, c = norm(a), norm(c)
            local r, p = 0, 1
            for _ = 1, 32 do
                local x, y = a % 2, c % 2
                if f(x, y) then r = r + p end
                a, c, p = (a - x) / 2, (c - y) / 2, p * 2
            end
            return r
        end
        local function fold(init, f)
            return function(...)
                local r = init
                for i = 1, select("#", ...) do r = op(r, (select(i, ...)), f) end
                return r
            end
        end
        b.band = fold(0xFFFFFFFF, function(x, y) return x == 1 and y == 1 end)
        b.bor = fold(0, function(x, y) return x == 1 or y == 1 end)
        b.bxor = fold(0, function(x, y) return x ~= y end)
        b.bnot = function(x) return 0xFFFFFFFF - norm(x) end
        b.lshift = function(x, n) if n >= 32 then return 0 end return norm(norm(x) * 2 ^ n) end
        b.rshift = function(x, n) if n >= 32 then return 0 end return floor(norm(x) / 2 ^ n) end
        b.btest = function(...) return b.band(...) ~= 0 end
        b.lrotate = function(x, n) n = n % 32; return b.bor(b.lshift(x, n), b.rshift(x, 32 - n)) end
        b.rrotate = function(x, n) return b.lrotate(x, 32 - (n % 32)) end
        b.arshift = function(x, n)
            x = norm(x)
            local r = b.rshift(x, n)
            if x >= 2 ^ 31 and n > 0 then r = b.bor(r, b.lshift(0xFFFFFFFF, 32 - n)) end
            return r
        end
        return b
    end

    -- host globals are referenced directly, NOT through _G (in Roblox executors _G is a separate empty table)
    local HOST = {
        assert = assert, error = error, ipairs = ipairs, pairs = pairs, next = next, pcall = pcall, xpcall = xpcall,
        select = select, tonumber = tonumber, tostring = tostring, type = type, rawget = rawget, rawset = rawset,
        rawequal = rawequal, rawlen = rawlen, setmetatable = setmetatable, unpack = U.unpack, _VERSION = _VERSION,
    }
    local HOSTLIBS = { math = math, string = string, table = table, coroutine = coroutine, utf8 = utf8 }

    -- ============================================================ build a fresh environment
    function M.build()
        local env = {}
        S.env = env

        for k, v in pairs(HOST) do env[k] = v end
        for k, v in pairs(HOSTLIBS) do
            if type(v) == "table" then env[k] = clone(v) end   -- clones: the script can never touch the host's libs
        end
        if env.string then env.string.dump = nil end
        env.table.unpack = env.table.unpack or U.unpack
        env.table.getn = env.table.getn or function(t) return #t end
        env.table.pack = env.table.pack or U.pack
        env.math.pow = env.math.pow or function(a, b) return a ^ b end
        env.bit32 = (type(bit32) == "table") and clone(bit32) or mk_bit32()
        env.bit = (type(bit) == "table") and clone(bit) or {
            bxor = env.bit32.bxor, band = env.bit32.band, bor = env.bit32.bor, bnot = env.bit32.bnot,
            lshift = env.bit32.lshift, rshift = env.bit32.rshift,
            tobit = function(x) x = floor(x) % 2 ^ 32; if x >= 2 ^ 31 then x = x - 2 ^ 32 end return x end }

        -- the host's string metatable must not be reachable (it would expose the real `string` table)
        local STRMT = { __index = env.string, __metatable = "The metatable is locked" }
        local function safe_getmt(x) if type(x) == "string" then return STRMT end return getmetatable(x) end
        env.getmetatable = safe_getmt
        env.getrawmetatable = function(x) return safe_getmt(x) or {} end

        -- os: only time functions are real; everything dangerous is a tripwire
        env.os = { time = os.time, clock = os.clock or os.time, date = os.date,
            execute = NET.trap_fn("os.execute"), remove = NET.trap_fn("os.remove"), rename = NET.trap_fn("os.rename"),
            getenv = NET.trap_fn("os.getenv"), exit = NET.trap_fn("os.exit"), tmpname = NET.trap_fn("os.tmpname"),
            setlocale = NET.trap_fn("os.setlocale") }
        env.io, env.package, env.socket, env.ffi = NET.trap("io"), NET.trap("package"), NET.trap("socket"), NET.trap("ffi")
        env.dofile, env.loadfile = NET.trap_fn("dofile"), NET.trap_fn("loadfile")

        env._G, env._ENV, env.shared = env, env, ghost("shared")
        env.getgenv, env.getrenv, env.getfenv = function() return env end, function() return env end, function() return env end
        env.setfenv = function(f) return f end
        env.typeof = function(v) return type(v) end
        env.collectgarbage = function() return 0 end
        env.newproxy = function() return setmetatable({}, {}) end
        env.tick, env.time = os.time, os.clock or os.time
        env.debug = {
            traceback = function() return "stack traceback:\n\t[C]: in ?" end,
            getinfo = function() return { short_src = "[string]", source = "=[string]", what = "Lua", currentline = 1 } end,
            getregistry = NET.trap_fn("debug.getregistry"), getupvalue = function() return nil end,
            sethook = function() end, gethook = function() return nil end,
        }

        env.print = function(...)
            local t = {}
            for i = 1, select("#", ...) do t[i] = tostring((select(i, ...))) end
            local line = table.concat(t, "\t")
            out("print", line)
            log("print", short(line, 150))
            if C.ECHO_PRINT then print("   [script] " .. short(line, 160)) end
        end
        env.warn = function(...) env.print("[warn]", ...) end

        -- loadstring: every layer is dumped to disk AND executed by the sandbox interpreter
        local function sandbox_load(src, chunkname)
            if type(src) ~= "string" then return nil, "loadstring: not a string" end
            S.layer_count = S.layer_count + 1
            local n = S.layer_count
            local bytecode = src:sub(1, 4) == "\27Lua"
            local layer = { size = #src, bytecode = bytecode, text = (not bytecode) and src or nil, step = S.steps }
            R.layers[n] = layer
            local fname = S.prefix .. "layer_" .. n .. (bytecode and ".luac" or ".lua")
            U.writef(U.outpath(fname), src)
            log("loadstring", ("layer #%d (%d bytes%s) saved as %s"):format(n, #src,
                bytecode and ", BYTECODE" or "", fname))
            if bytecode then return nil, "bytecode cannot be interpreted" end
            scan_string("loadstring#" .. n, src)
            local f, ast = BS.compiler.load_interp(src, "layer" .. n)
            if not f then log("loadstring-FAILED", "layer #" .. n .. ": " .. short(ast, 200)); return nil, ast end
            layer.ast = ast
            return f
        end
        env.loadstring = sandbox_load
        env.load = function(src, ...) if type(src) == "function" then return nil, "unsupported" end return sandbox_load(src, ...) end
        env.require = function(x) log("require", short(x)); return ghost("require()") end

        local function run_now(f, ...) if type(f) == "function" then pcall(f, ...) end end
        local function wait()
            S.waits = S.waits + 1
            if S.waits > C.MAX_WAITS then error("sandbox: loop limit (task.wait called too often)", 0) end
            return 0
        end
        env.task = { spawn = function(f, ...) run_now(f, ...) end, defer = function(f, ...) run_now(f, ...) end,
            delay = function(_, f, ...) run_now(f, ...) end, wait = wait, cancel = function() end }
        env.wait, env.spawn, env.delay = wait, function(f) run_now(f) end, function(_, f) run_now(f) end

        env.identifyexecutor = function() return FAKE.executor, FAKE.exec_ver end
        env.getexecutorname = function() return FAKE.executor end
        env.gethwid = function() return FAKE.hwid end
        env.checkcaller, env.islclosure, env.isexecutorclosure = function() return true end, function() return true end, function() return true end
        env.newcclosure, env.clonefunction, env.cloneref = function(f) return f end, function(f) return f end, function(x) return x end

        -- hooking: a hook on one of OUR net guards is refused (the guard stays authoritative).
        -- Replacement functions are queued for the emulator so their code is still explored.
        env.hookfunction = function(a, b)
            local gn = type(a) == "function" and NET.guards[a]
            if gn then
                NET.tamper("hookfunction() on net guard '" .. gn .. "' ignored (original keeps monitoring)")
            else
                log("hookfunction", (type(a) == "function" and "<function>" or short(a)) .. " -> " .. (type(b) == "function" and "<function>" or short(b)))
            end
            behave("hookfunction(" .. (type(a) == "function" and "<function>" or short(a)) .. ", ...)")
            if C.EMULATE and type(b) == "function" then EM.poke(b, "hookfunction") end
            return a
        end
        env.hookmetamethod = function(o, m, f)
            log("hookmetamethod", short(o) .. "." .. short(m))
            behave("hookmetamethod(" .. short(o) .. ", " .. short(m) .. ", ...)")
            if C.EMULATE and type(f) == "function" then EM.poke(f, "hookmetamethod." .. tostring(m)) end
            return function() end
        end
        env.getnamecallmethod = function() return "" end
        env.setreadonly, env.make_writeable = function() end, function() end
        env.getgc, env.getconnections, env.getloadedmodules = function() return {} end, function() return {} end, function() return {} end
        env.setclipboard = function(s) log("setclipboard", short(s)); behave("setclipboard(" .. lit(s) .. ")"); out("clipboard", short(s, 300)); scan_string("setclipboard", s) end
        env.queue_on_teleport = function(s) log("queue_on_teleport", short(s)); behave("queue_on_teleport(" .. lit(s) .. ")"); out("teleport", short(s, 300)); scan_string("queue_on_teleport", s) end

        local vfs = {}
        env.writefile = function(p, s) log("writefile", short(p)); behave("writefile(" .. lit(p) .. ", " .. lit(s) .. ")"); out("file", "write " .. short(p) .. " (" .. #tostring(s) .. " bytes)"); vfs[p] = s; scan_string("writefile", s) end
        env.readfile = function(p) log("readfile", short(p)); behave("readfile(" .. lit(p) .. ")"); if vfs[p] then return vfs[p] end error("file not found") end
        env.isfile = function(p) log("isfile", short(p)); return vfs[p] ~= nil end
        env.isfolder, env.makefolder, env.listfiles = function() return false end, function() end, function() return {} end

        -- ---- NET GUARD hooks: executor-style request functions
        local function exec_request(src)
            return net_guard(src, function(o)
                o = o or {}
                return do_request(src, o.Url or o.url, o.Method or o.method, o.Headers or o.headers, o.Body or o.body)
            end)
        end
        env.request, env.http_request, env.httprequest = exec_request("request"), exec_request("http_request"), exec_request("httprequest")
        env.syn, env.http = { request = exec_request("syn.request") }, { request = exec_request("http.request") }
        env.fluxus = { request = exec_request("fluxus.request") }

        -- ---- NET GUARD hooks: websockets
        env.WebSocket = { connect = net_guard("WebSocket.connect", function(url)
            do_request("WebSocket.connect", url, "WS-CONNECT")
            return ghost("WebSocket", {
                Send = net_guard("WebSocket:Send", function(_, msg) do_request("WebSocket:Send", url, "WS-SEND", nil, msg) end),
                Close = function() end,
            })
        end) }

        -- ---- NET GUARD hooks: HttpService / game:Http*   (GET content may come from the spider)
        local function body_or(resp, dflt) if resp and resp.Fetched then return resp.Body end return dflt end
        local HttpService = ghost("HttpService", {
            RequestAsync = net_guard("HttpService:RequestAsync", function(_, o)
                o = o or {}
                return do_request("HttpService:RequestAsync", o.Url or o.url, o.Method or o.method, o.Headers or o.headers, o.Body or o.body)
            end),
            PostAsync = net_guard("HttpService:PostAsync", function(_, url, data, _, _, hdrs)
                do_request("HttpService:PostAsync", url, "POST", hdrs, data); return "{}"
            end),
            GetAsync = net_guard("HttpService:GetAsync", function(_, url, _, hdrs)
                return body_or(do_request("HttpService:GetAsync", url, "GET", hdrs), "{}")
            end),
            JSONEncode = function(_, v) return json(v) end,
            JSONDecode = function() return {} end,
            UrlEncode = function(_, s) return tostring(s) end,
            GenerateGUID = function() return "00000000-0000-0000-0000-000000000000" end,
        })
        local LocalPlayer = ghost("Players.LocalPlayer", { Name = FAKE.name, DisplayName = FAKE.name, UserId = FAKE.userid, AccountAge = 999 })
        local Players = ghost("Players", { LocalPlayer = LocalPlayer })
        EM.ctx.ghost, EM.ctx.player = ghost, LocalPlayer
        local services = { HttpService = HttpService, Players = Players }
        local function get_service(_, n)
            log("GetService", tostring(n))
            behave("game:GetService(" .. lit(n) .. ")")
            if not services[n] then services[n] = ghost("game:GetService(" .. lit(n) .. ")") end
            return services[n]
        end
        local game = ghost("game", {
            HttpGet = net_guard("game:HttpGet", function(_, url) return body_or(do_request("game:HttpGet", url, "GET"), "return nil") end),
            HttpGetAsync = net_guard("game:HttpGetAsync", function(_, url) return body_or(do_request("game:HttpGetAsync", url, "GET"), "return nil") end),
            HttpPost = net_guard("game:HttpPost", function(_, url, data) do_request("game:HttpPost", url, "POST", nil, data); return "{}" end),
            HttpPostAsync = net_guard("game:HttpPostAsync", function(_, url, data) do_request("game:HttpPostAsync", url, "POST", nil, data); return "{}" end),
            GetService = get_service, FindService = get_service,
            Players = Players, PlaceId = 1818, GameId = 1818, JobId = "canary-job-id",
        })
        env.game, env.Game = game, game
        for _, nme in ipairs({ "workspace", "Workspace", "script", "Instance", "Enum", "Vector3", "Vector2",
            "CFrame", "Color3", "UDim2", "UDim", "TweenInfo", "Drawing", "Random", "Ray", "BrickColor" }) do
            env[nme] = ghost(nme)
        end

        NET.seal(env)

        -- known native function names, so aliases like `local c = string.char` still show as string.char
        local nn = R.native_names
        for _, lib in ipairs({ "string", "table", "math", "bit32", "bit", "coroutine", "os", "utf8" }) do
            local t = env[lib]
            if type(t) == "table" then
                for k, v in pairs(t) do if type(v) == "function" and not nn[v] then nn[v] = lib .. "." .. tostring(k) end end
            end
        end
        for k, v in pairs(env) do if type(v) == "function" and not nn[v] then nn[v] = tostring(k) end end
        return env
    end

    return M
end
