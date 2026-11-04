-- BlackSpider :: util.lua  --  shared helpers, file IO, literal/json printers
return function(BS)
    local U = {}
    local floor = math.floor
    U.floor = floor
    U.unpack = table.unpack or unpack

    function U.pack(...) return { n = select("#", ...), ... } end
    function U.clone(t) local c = {}; for k, v in pairs(t) do c[k] = v end return c end
    function U.clear(t) for k in pairs(t) do t[k] = nil end end
    function U.count_nl(s) local _, c = s:gsub("\n", ""); return c end

    function U.short(v, n)
        local s = tostring(v)
        s = (s:gsub("[\r\n]", " "):gsub("[^%w%p ]", "."))
        n = n or 100
        return #s > n and (s:sub(1, n) .. "...") or s
    end

    function U.printable(s)
        if #s == 0 then return 0 end
        local _, c = s:gsub("[%w%p%s]", "")
        return c / #s
    end

    -- cheap content hash (first 20k bytes + length) used only for de-duplication
    function U.hash(s)
        local h1, h2 = 5381, 52711
        local n = math.min(#s, 20000)
        for i = 1, n do
            local b = s:byte(i)
            h1 = (h1 * 33 + b) % 4294967296
            h2 = (h2 * 131 + b) % 4294967291
        end
        return ("%08x%08x:%d"):format(h1, h2, #s)
    end

    local utf8char = (utf8 and utf8.char) or function() return "?" end
    function U.unescape(s)
        if not s:find("\\", 1, true) then return s end
        local o, i, len = {}, 1, #s
        while i <= len do
            local c = s:sub(i, i)
            if c ~= "\\" then
                local j = s:find("\\", i, true) or (len + 1)
                o[#o + 1] = s:sub(i, j - 1); i = j
            else
                local d = s:match("^%d%d?%d?", i + 1)
                if d then o[#o + 1] = string.char(tonumber(d) % 256); i = i + 1 + #d
                else
                    local nx = s:sub(i + 1, i + 1)
                    if nx == "x" then
                        local h = s:match("^%x%x", i + 2)
                        if h then o[#o + 1] = string.char(tonumber(h, 16)); i = i + 4 else i = i + 2 end
                    elseif nx == "z" then i = i + 2 + #s:match("^%s*", i + 2)
                    elseif nx == "u" then
                        local h = s:match("^{(%x+)}", i + 2)
                        if h then o[#o + 1] = utf8char(tonumber(h, 16)); i = i + 4 + #h else i = i + 2 end
                    elseif nx == "n" then o[#o + 1] = "\n"; i = i + 2
                    elseif nx == "t" then o[#o + 1] = "\t"; i = i + 2
                    elseif nx == "r" then o[#o + 1] = "\r"; i = i + 2
                    elseif nx == "a" then o[#o + 1] = "\a"; i = i + 2
                    elseif nx == "b" then o[#o + 1] = "\b"; i = i + 2
                    elseif nx == "f" then o[#o + 1] = "\f"; i = i + 2
                    elseif nx == "v" then o[#o + 1] = "\v"; i = i + 2
                    elseif nx == "\n" then o[#o + 1] = "\n"; i = i + 2
                    else o[#o + 1] = nx; i = i + 2 end
                end
            end
        end
        return table.concat(o)
    end

    -- Lua-ish literal (for reconstructed code)
    local function lit(v, d)
        d = d or 0
        local t = type(v)
        if t == "string" then
            local s = #v > 500 and (v:sub(1, 500) .. "...") or v
            return ((("%q"):format(s)):gsub("\\\n", "\\n"))
        elseif t == "table" then
            local mt = getmetatable(v)
            if mt and mt.__tostring then return tostring(v) end
            if d >= 4 then return "{...}" end
            local parts, len = {}, #v
            for i = 1, len do parts[#parts + 1] = lit(v[i], d + 1) end
            local keys = {}
            for k in pairs(v) do
                if not (type(k) == "number" and k >= 1 and k <= len and k == floor(k)) then keys[#keys + 1] = k end
            end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                if #parts >= 40 then parts[#parts + 1] = "..."; break end
                local ks = (type(k) == "string" and k:match("^[%a_][%w_]*$")) and k or ("[" .. lit(k, d + 1) .. "]")
                parts[#parts + 1] = ks .. " = " .. lit(v[k], d + 1)
            end
            return "{" .. table.concat(parts, ", ") .. "}"
        elseif t == "function" then return "function() end"
        else return tostring(v) end
    end
    U.lit = lit

    local JSONESC = { ['"'] = '\\"', ["\\"] = "\\\\", ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }
    local function json(v, d)
        d = d or 0
        local t = type(v)
        if t == "string" then
            return '"' .. (v:gsub('[%c"\\]', function(c) return JSONESC[c] or ("\\u%04x"):format(c:byte()) end)) .. '"'
        elseif t == "table" then
            local mt = getmetatable(v)
            if mt and mt.__tostring then return json(tostring(v), d) end
            if d > 8 then return "null" end
            local len, cnt = #v, 0
            for _ in pairs(v) do cnt = cnt + 1 end
            local parts = {}
            if len > 0 and cnt == len then
                for i = 1, len do parts[i] = json(v[i], d + 1) end
                return "[" .. table.concat(parts, ",") .. "]"
            end
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do parts[#parts + 1] = json(tostring(k)) .. ":" .. json(v[k], d + 1) end
            return "{" .. table.concat(parts, ",") .. "}"
        elseif t == "nil" then return "null"
        else return tostring(v) end
    end
    U.json = json

    -- ---------------------------------------------------------------- file IO
    -- captured once at load time (executor globals, or plain io on desktop Lua)
    local real_readfile, real_writefile = readfile, writefile
    local real_isfile, real_makefolder, real_isfolder = isfile, makefolder, isfolder

    function U.readf(p)
        if real_readfile then return real_readfile(p) end
        local f = assert(io.open(p, "rb")); local s = f:read("*a"); f:close(); return s
    end
    function U.exists(p)
        if real_isfile then local ok, r = pcall(real_isfile, p); return ok and r end
        if io and io.open then local f = io.open(p, "rb"); if f then f:close(); return true end end
        return false
    end
    function U.writef(p, s)
        if real_writefile then return pcall(real_writefile, p, s) end
        if io and io.open then
            local f = io.open(p, "wb")
            if f then f:write(s); f:close(); return true end
        end
        return false
    end
    -- executors have makefolder -> real sub folder; plain Lua gets flat files "<dir>_<name>"
    function U.outpath(name)
        local d = BS.config.OUT_DIR
        if real_makefolder then return d .. "/" .. name end
        return d .. "_" .. name
    end
    function U.ensure_dir()
        if real_makefolder then
            pcall(function()
                if not (real_isfolder and real_isfolder(BS.config.OUT_DIR)) then real_makefolder(BS.config.OUT_DIR) end
            end)
        end
    end

    return U
end
