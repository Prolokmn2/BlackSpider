-- BlackSpider :: netguard.lua  --  every http / websocket vector of the sandbox is hooked here.
-- The hooks only RECORD and return a fake response. The single exception is the spider gate
-- (see spider.lua): a plain GET of a script url, no headers/body of the analysed script are forwarded.
return function(BS)
    local U, C, ST = BS.util, BS.config, BS.state
    local S, R = ST.S, ST.R
    local log, behave, out, scan_string = ST.log, ST.behave, ST.out, ST.scan_string
    local short, json, lit = U.short, U.json, U.lit

    local NET = {
        attempts = 0, blocked = 0, fetched = 0, by_vector = {},
        tampers = {}, tamper_seen = {}, escapes = {}, escape_seen = {},
        guards = {}, sealed = {}, fields = {}, printed = 0, host_hits = 0,
    }

    function NET.reset()
        NET.attempts, NET.blocked, NET.fetched, NET.printed, NET.host_hits = 0, 0, 0, 0, 0
        for _, k in ipairs({ "by_vector", "tampers", "tamper_seen", "escapes", "escape_seen", "guards", "sealed", "fields" }) do
            U.clear(NET[k])
        end
    end

    local function net_say(msg)
        NET.printed = NET.printed + 1
        if NET.printed <= 60 then print("[NET-GUARD] " .. msg)
        elseif NET.printed == 61 then print("[NET-GUARD] (further guard messages go only to the report)") end
    end
    NET.say = net_say

    function NET.tamper(msg)
        if NET.tamper_seen[msg] or #NET.tampers >= 200 then return end
        NET.tamper_seen[msg] = true
        NET.tampers[#NET.tampers + 1] = { msg = msg, step = S.steps, line = S.cur_line }
        log("NET-TAMPER", msg)
        behave("-- NET-GUARD: " .. msg)
        net_say("TAMPER: " .. msg)
    end

    local function escape(what)
        if NET.escape_seen[what] or #NET.escapes >= 200 then return end
        NET.escape_seen[what] = true
        NET.escapes[#NET.escapes + 1] = { what = what, step = S.steps, line = S.cur_line }
        log("ESCAPE-BLOCKED", what)
        behave("-- BLOCKED sandbox escape attempt: " .. what)
        net_say("blocked escape attempt: " .. short(what, 120))
    end
    NET.escape = escape

    function NET.trap_fn(what)
        return function(...) escape(what .. "(" .. ST.argstr(...) .. ")"); return nil, "blocked by sandbox" end
    end
    function NET.trap(name)
        return setmetatable({}, {
            __index = function(_, k) local w = name .. "." .. tostring(k); escape(w); return NET.trap_fn(w) end,
            __newindex = function(_, k) escape(name .. "." .. tostring(k) .. " = ...") end,
            __call = function(_, ...) escape(name .. "(" .. ST.argstr(...) .. ")"); return nil end,
            __tostring = function() return name end,
        })
    end

    -- may the script write `key` into table `o`? (false = it would unhook a guard)
    function NET.allow(o, key, v)
        if not C.NET_LOCK then return true end
        local sealed = (o == S.env) and NET.sealed or NET.fields[o]
        if sealed then
            local g = sealed[key]
            if g ~= nil and v ~= g then
                NET.tamper(("script tried to overwrite/remove '%s' (%s) -> blocked, guard kept"):format(tostring(key), type(v) == "function" and "<function>" or short(v)))
                return false
            end
        end
        return true
    end

    -- re-check that every guard is still bound (catches rawset & friends) and restore it
    function NET.verify()
        local env = S.env
        if not env then return true end
        local ok = true
        for nm, g in pairs(NET.sealed) do
            if rawget(env, nm) ~= g then
                ok = false
                NET.tamper(("global '%s' was replaced/removed behind the guard -> restored"):format(tostring(nm)))
                rawset(env, nm, g)
            end
        end
        for t, fields in pairs(NET.fields) do
            for k, g in pairs(fields) do
                if rawget(t, k) ~= g then
                    ok = false
                    NET.tamper(("net field '%s' was replaced/removed behind the guard -> restored"):format(tostring(k)))
                    rawset(t, k, g)
                end
            end
        end
        return ok
    end

    -- ------------------------------------------------------------------ requests
    local function canary_hits(s)
        local hits = {}
        for k, v in pairs(BS.FAKE) do
            if k ~= "executor" and k ~= "exec_ver" and s:find(tostring(v), 1, true) then hits[#hits + 1] = k end
        end
        return hits
    end

    local function fake_response(url)
        if url and tostring(url):find("discord[a-z0-9]*%.com/api/webhooks") then
            return { Success = true, StatusCode = 204, StatusMessage = "No Content", Body = "", Headers = {} }
        end
        return { Success = true, StatusCode = 200, StatusMessage = "OK", Body = "{}", Headers = {} }
    end
    NET.fake_response = fake_response

    -- THE choke point: every hooked vector ends up here.
    -- returns a response table; resp.Fetched == true means the spider supplied real GET content.
    function NET.do_request(src, url, method, headers, body, extra, quiet)
        url, method = tostring(url), tostring(method or "GET")
        local h = type(headers) == "table" and json(headers) or tostring(headers or "{}")
        local b = type(body) == "string" and body or (body ~= nil and json(body) or "")
        local blob = url .. " " .. h .. " " .. b
        scan_string(src, blob)
        local flags = {}
        local is_hook = blob:find("discord[a-z0-9]*%.com/api/webhooks") ~= nil
        if is_hook then flags[#flags + 1] = "DISCORD-WEBHOOK" end
        local hits = canary_hits(blob)
        if #hits > 0 then flags[#flags + 1] = "EXFIL(canary: " .. table.concat(hits, ",") .. ")" end
        if method:upper() ~= "GET" and not url:find("roblox%.com") then flags[#flags + 1] = "OUTBOUND-" .. method:upper() end
        if extra then flags[#flags + 1] = extra end

        -- spider: a plain GET with no body may be answered with the real script content
        local resp
        if BS.spider and method:upper() == "GET" and body == nil and not extra and #hits == 0 and not is_hook then
            local content, why = BS.spider.gate(url, src)
            if content then
                resp = { Success = true, StatusCode = 200, StatusMessage = "OK", Body = content, Headers = {}, Fetched = true }
                flags[#flags + 1] = "SPIDER-FETCHED(" .. #content .. " bytes)"
            elseif why then
                flags[#flags + 1] = "NOT-FETCHED(" .. why .. ")"
            end
        end

        NET.attempts = NET.attempts + 1
        if resp then NET.fetched = NET.fetched + 1 else NET.blocked = NET.blocked + 1 end
        NET.by_vector[src] = (NET.by_vector[src] or 0) + 1
        if #R.requests < C.MAX_REQUESTS then
            R.requests[#R.requests + 1] = { src = src, url = url, method = method, headers = h, body = b,
                flags = flags, step = S.steps, fetched = resp and true or false }
        end
        local ftxt = #flags > 0 and ("   <" .. table.concat(flags, " | ") .. ">") or ""
        log(resp and "NET-FETCHED" or "NET-BLOCKED", src .. " " .. method .. " " .. short(url, 120))
        if not quiet then
            if src:sub(1, 5) == "game:" then
                behave(src .. "(" .. lit(url) .. ")")
            else
                local parts = { "Url = " .. lit(url), "Method = " .. lit(method) }
                if headers ~= nil then parts[#parts + 1] = "Headers = " .. lit(headers) end
                if body ~= nil then parts[#parts + 1] = "Body = " .. lit(body) end
                behave(src .. "({ " .. table.concat(parts, ", ") .. " })")
            end
        end
        out("http", ("%s %s%s\n      body: %s"):format(method, url, ftxt, short(b, 500)))
        net_say(("%s %s %s %s%s"):format(resp and "FETCHED(GET)" or "BLOCKED", src, method, short(url, 110), ftxt))
        return resp or fake_response(url)
    end

    -- wrap an implementation as a monitored hook. The wrapper never calls anything real.
    function NET.net_guard(name, impl)
        local g = function(...)
            local ok, r = pcall(impl, ...)
            if not ok then
                log("net-guard-error", name .. ": " .. short(r, 150))
                return fake_response("")
            end
            return r
        end
        NET.guards[g] = name
        R.native_names[g] = name
        return g
    end

    -- unknown vectors: a url passed to something that smells like a network call
    local HINTS = { "http", "request", "post", "get", "send", "fetch", "webhook", "download", "upload", "socket", "navigate" }
    function NET.net_hint(callee)
        local l = callee:lower()
        for _, w in ipairs(HINTS) do if l:find(w, 1, true) then return true end end
        return false
    end

    -- seal: from here on the guards are watched for overwrite/removal
    function NET.seal(env)
        for _, nm in ipairs({ "request", "http_request", "httprequest", "syn", "http", "fluxus", "WebSocket" }) do
            NET.sealed[nm] = env[nm]
        end
        NET.fields[env.syn] = { request = env.syn.request }
        NET.fields[env.http] = { request = env.http.request }
        NET.fields[env.fluxus] = { request = env.fluxus.request }
        NET.fields[env.WebSocket] = { connect = env.WebSocket.connect }
    end

    -- ------------------------------------------------------------------ host lock
    -- defence in depth: neutralise the HOST's own request functions while a script runs.
    -- (the spider keeps its own private reference, captured before this runs)
    local host_saved = {}
    function NET.host_lock()
        if not C.HOST_LOCK then return end
        local G = (type(getgenv) == "function" and getgenv()) or _G
        local function blocker(nm)
            return function()
                NET.host_hits = NET.host_hits + 1
                log("HOST-NET-BLOCKED", nm)
                return { Success = false, StatusCode = 0, StatusMessage = "blocked", Body = "", Headers = {} }
            end
        end
        for _, nm in ipairs({ "request", "http_request", "httprequest" }) do
            local cur = rawget(G, nm)
            if type(cur) == "function" then
                host_saved[#host_saved + 1] = { G, nm, cur }
                pcall(function() G[nm] = blocker(nm) end)
            end
        end
        for _, pr in ipairs({ { "syn", "request" }, { "http", "request" }, { "fluxus", "request" } }) do
            local t = rawget(G, pr[1])
            if type(t) == "table" and type(t[pr[2]]) == "function" then
                host_saved[#host_saved + 1] = { t, pr[2], t[pr[2]] }
                pcall(function() t[pr[2]] = blocker(pr[1] .. "." .. pr[2]) end)
            end
        end
    end
    function NET.host_unlock()
        for i = #host_saved, 1, -1 do
            local s = host_saved[i]
            pcall(function() s[1][s[2]] = s[3] end)
        end
        host_saved = {}
    end

    return NET
end
