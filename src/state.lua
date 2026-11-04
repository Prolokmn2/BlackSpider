-- BlackSpider :: state.lua  --  runtime state + everything the sandbox records while a script runs
return function(BS)
    local U, C = BS.util, BS.config
    local short, printable = U.short, U.printable
    local clock = os.clock or os.time
    local unpack, pack = U.unpack, U.pack

    local M = {}
    local S = { steps = 0, next_check = 20000, cur_line = 0, deadline = 0, last_print = 0,
        waits = 0, env = nil, layer_count = 0, ctx = nil, prefix = "p0_" }
    local R = {
        events = {}, evseen = {}, behavior = {}, outputs = {}, requests = {}, layers = {},
        strings = {}, strset = {}, vars = {}, varset = {}, endpoints = {}, endpoint_order = {},
        keycands = {}, keyset = {}, xor_tally = {}, ccount = {}, fcount = {}, gseen = {},
        defs = {}, rid = 0, last_concat = false, native_names = {}, main_ast = false,
        interp = setmetatable({}, { __mode = "k" }),
    }
    M.S, M.R = S, R
    local events, evseen, behavior, outputs = R.events, R.evseen, R.behavior, R.outputs
    local strings, strset, vars, varset = R.strings, R.strset, R.vars, R.varset
    local endpoints, endpoint_order, keycands, keyset = R.endpoints, R.endpoint_order, R.keycands, R.keyset
    local ccount, fcount, gseen, interp, native_names = R.ccount, R.fcount, R.gseen, R.interp, R.native_names

    function M.reset()
        for _, k in ipairs({ "events", "evseen", "behavior", "outputs", "requests", "layers", "strings", "strset",
            "vars", "varset", "endpoints", "endpoint_order", "keycands", "keyset", "xor_tally", "ccount", "fcount",
            "gseen", "defs", "native_names", "interp" }) do
            U.clear(R[k])
        end
        R.rid, R.last_concat, R.main_ast = 0, false, false
        S.steps, S.next_check, S.cur_line, S.waits, S.layer_count, S.ctx = 0, 20000, 0, 0, 0, nil
        S.deadline = clock() + C.TIME_LIMIT
        S.last_print = clock()
    end

    local function log(kind, msg)
        if #events >= C.MAX_EVENTS then return end
        local key = kind .. msg
        if evseen[key] then return end
        evseen[key] = true
        events[#events + 1] = ("[step %d | line %d] %s: %s"):format(S.steps, S.cur_line, kind, msg)
    end
    local function behave(text, def)
        if #behavior < 6000 then behavior[#behavior + 1] = { text = text, step = S.steps, line = S.cur_line, def = def, ev = S.ctx } end
    end
    local function out(kind, text)
        if #outputs < 3000 then outputs[#outputs + 1] = { kind = kind, text = text, step = S.steps } end
    end
    M.log, M.behave, M.out = log, behave, out

    local function scan_string(label, s)
        if type(s) ~= "string" or #s < 8 then return end
        for hook in s:gmatch("discord[a-z0-9]*%.com/api/webhooks/%d+/[%w%-_]+") do
            if not endpoints[hook] then
                endpoints[hook] = { how = label, hook = true, step = S.steps }
                endpoint_order[#endpoint_order + 1] = hook
            end
        end
        for url in s:gmatch("https?://[^%s\"'%)%]%,\\]+") do
            if not url:find("roblox%.com") and not url:find("rbxcdn%.com") and not endpoints[url] then
                endpoints[url] = { how = label, hook = false, step = S.steps }
                endpoint_order[#endpoint_order + 1] = url
            end
        end
    end
    M.scan_string = scan_string

    local function add_key(kind, value, why)
        local key = kind .. tostring(value)
        if keyset[key] or #keycands >= 300 then return end
        keyset[key] = true
        keycands[#keycands + 1] = { kind = kind, value = value, why = why, step = S.steps }
    end
    M.add_key = add_key

    local KEYNAME = { "key", "secret", "token", "pass", "seed", "salt", "nonce", "auth", "cookie", "hwid", "webhook", "cipher" }
    local function keyname(name)
        local l = tostring(name):lower()
        for _, k in ipairs(KEYNAME) do if l:find(k, 1, true) then return true end end
        return false
    end
    function M.keylike(s)
        return #s >= 16 and #s <= 72 and s:match("^[%w%+/=_%-]+$") and s:find("%d") and s:find("%a") and true or false
    end

    local function rec_string(kind, s, nm)
        local len = #s
        if len < 6 then return end
        local head = len > 200 and s:sub(1, 200) or s
        if printable(head) < 0.9 then return end
        local lc = R.last_concat
        if kind == "concat" and lc and len > lc.len and len - lc.len < 400 and head:sub(1, 16) == lc.head16 then
            lc.text = len > 4000 and s:sub(1, 4000) or s
            lc.len = len; lc.step = S.steps
            return
        end
        local key = len .. ":" .. head:sub(1, 100)
        if strset[key] then return end
        strset[key] = true
        if #strings >= C.MAX_STRINGS then return end
        local e = { kind = kind, name = nm, text = len > 4000 and s:sub(1, 4000) or s, len = len,
            step = S.steps, line = S.cur_line, head16 = head:sub(1, 16) }
        strings[#strings + 1] = e
        if kind == "concat" then R.last_concat = e end
        if nm and keyname(nm) then add_key("KEY-NAMED-VAR", short(s, 120), "variable '" .. nm .. "'") end
    end
    M.rec_string = rec_string

    function M.rec_var(name, v)
        if type(v) ~= "string" or #v < 4 then
            if type(v) == "number" and keyname(name) then add_key("KEY-NAMED-VAR", v, "variable '" .. tostring(name) .. "'") end
            return
        end
        local key = tostring(name) .. "=" .. #v .. v:sub(1, 40)
        if varset[key] then return end
        varset[key] = true
        if #vars < 4000 and printable(#v > 200 and v:sub(1, 200) or v) >= 0.9 then
            vars[#vars + 1] = { name = tostring(name), value = #v > 600 and (v:sub(1, 600) .. "...") or v, len = #v, step = S.steps }
            rec_string("var", v, tostring(name))
        end
    end

    function M.tick()
        S.next_check = S.steps + 20000
        local now = clock()
        if BS.net and BS.net.verify then BS.net.verify() end
        if now > S.deadline then
            S.next_check = S.steps
            error(("sandbox: TIME LIMIT reached (%ds) at step %d, line %d"):format(C.TIME_LIMIT, S.steps, S.cur_line), 0)
        end
        if now - S.last_print > 3 then
            S.last_print = now
            print(("[..] running: %d steps | line %d | %d strings | %d requests | %d layers")
                :format(S.steps, S.cur_line, #strings, BS.net and BS.net.attempts or 0, #R.layers))
        end
    end

    function M.rterr(msg, line) error(("[line %s] %s"):format(tostring(line or S.cur_line), msg), 0) end

    -- ------------------------------------------------------------ native call tracing
    local NOISY_PREFIX = { "string.", "table.", "math.", "bit32.", "bit.", "coroutine.", "os.", "utf8." }
    local NOISY_NAMES = { select = 1, type = 1, tostring = 1, tonumber = 1, unpack = 1, rawget = 1, rawset = 1,
        rawequal = 1, pairs = 1, ipairs = 1, next = 1, setmetatable = 1, getmetatable = 1, pcall = 1, error = 1, assert = 1 }
    local noisy_cache, keyfn_cache, xor_cache = {}, {}, {}
    local function is_noisy(name)
        local v = noisy_cache[name]
        if v == nil then
            v = NOISY_NAMES[name] ~= nil
            if not v then for _, p in ipairs(NOISY_PREFIX) do if name:sub(1, #p) == p then v = true; break end end end
            noisy_cache[name] = v
        end
        return v
    end
    local KEYFN = { "decrypt", "decode", "cipher", "crypt", "xor", "aes", "rc4", "hmac", "sha", "md5", "hash", "key", "b64", "base64" }
    local function argstr(...)
        local t = {}
        for i = 1, select("#", ...) do t[i] = short((select(i, ...)), 70) end
        return table.concat(t, ", ")
    end
    M.argstr = argstr

    local function call_native(name, f, ...)
        local nm = native_names[f] or name
        local c = (ccount[nm] or 0) + 1; ccount[nm] = c
        local r = pack(f(...))
        local r1 = r[1]
        if type(r1) == "string" and #r1 >= 6 then rec_string("call " .. nm, r1) end
        if c <= (is_noisy(nm) and 3 or 25) then
            log("call", nm .. "(" .. argstr(...) .. ") -> " .. short(r1, 90))
        end
        local isx = xor_cache[nm]
        if isx == nil then isx = nm:find("xor", 1, true) ~= nil; xor_cache[nm] = isx end
        if isx then
            local b = select(2, ...)
            if type(b) == "number" then R.xor_tally[b] = (R.xor_tally[b] or 0) + 1 end
        end
        local kf = keyfn_cache[nm]
        if kf == nil then
            kf = false
            local l = nm:lower()
            for _, k in ipairs(KEYFN) do if l:find(k, 1, true) then kf = true; break end end
            keyfn_cache[nm] = kf
        end
        if kf and c <= 50 then
            for i = 1, select("#", ...) do
                local a = select(i, ...)
                if type(a) == "string" and #a >= 3 and #a <= 200 then add_key("KEY-ARG", short(a, 120), "argument to " .. nm)
                elseif type(a) == "number" and (a > 255 or a < 0) then add_key("KEY-ARG", a, "argument to " .. nm) end
            end
        end
        return unpack(r, 1, r.n)
    end

    local rterr = M.rterr
    function M.invoke(gname, f, hs, self, ...)
        if interp[f] then
            if hs then return f(self, ...) end
            return f(...)
        end
        if f == nil then rterr("attempt to call a nil value (" .. gname .. ")") end
        if hs then return call_native(gname, f, self, ...) end
        return call_native(gname, f, ...)
    end
    function M.invoke_t(gname, f, hs, self, t, n)
        if interp[f] then
            if hs then return f(self, unpack(t, 1, n)) end
            return f(unpack(t, 1, n))
        end
        if f == nil then rterr("attempt to call a nil value (" .. gname .. ")") end
        if hs then return call_native(gname, f, self, unpack(t, 1, n)) end
        return call_native(gname, f, unpack(t, 1, n))
    end

    return M
end
