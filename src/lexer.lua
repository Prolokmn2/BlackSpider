-- BlackSpider :: lexer.lua  --  Lua 5.1 + Luau-ish extras (0b, 1_000, `interp {x}`, ::, ?, |, &)
return function(BS)
    local U = BS.util
    local M = {}

    local KW = {}
    for w in ("and break do else elseif end false for function if in local nil not or repeat return then true until while"):gmatch("%a+") do KW[w] = true end
    M.KW = KW

    function M.lex(src)
        local T, V, L, nt = {}, {}, {}, 0
        local i, n, line = 1, #src, 1
        local function push(t, v) nt = nt + 1; T[nt] = t; V[nt] = v; L[nt] = line end
        if src:sub(1, 1) == "#" then i = (src:find("\n", 1, true)) or (n + 1) end
        while i <= n do
            local c = src:sub(i, i)
            if c == "\n" then line = line + 1; i = i + 1
            elseif c == " " or c == "\t" or c == "\r" then i = i + 1
            elseif c == "-" and src:sub(i + 1, i + 1) == "-" then
                local eq = src:match("^%-%-%[(=*)%[", i)
                if eq then
                    local _, e2 = src:find("]" .. eq .. "]", i, true)
                    if not e2 then error("unfinished long comment", 0) end
                    line = line + U.count_nl(src:sub(i, e2)); i = e2 + 1
                else
                    i = (src:find("\n", i, true)) or (n + 1)
                end
            elseif c:find("[%a_]") then
                local w = src:match("^[%a_][%w_]*", i); i = i + #w
                if KW[w] then push("kw", w) else push("name", w) end
            elseif c:find("%d") or (c == "." and src:find("^%.%d", i)) then
                local s, val = src:match("^0[xX][%x_]+", i), nil
                if s then
                    val = tonumber((s:gsub("_", "")))
                else
                    s = src:match("^0[bB][01_]+", i)
                    if s then
                        val = tonumber((s:sub(3):gsub("_", "")), 2)
                    else
                        s = src:match("^[%d_]*", i)
                        local p = i + #s
                        if src:sub(p, p) == "." and src:sub(p + 1, p + 1) ~= "." then
                            local frac = src:match("^%.%d*", p); s = s .. frac; p = p + #frac
                        end
                        local ex = src:match("^[eE][%+%-]?%d+", p)
                        if ex then s = s .. ex end
                        val = tonumber((s:gsub("_", "")))
                    end
                end
                i = i + #s
                push("number", val or 0)
            elseif c == '"' or c == "'" then
                local pat = (c == '"') and '[\\\n"]' or "[\\\n']"
                local j = i + 1
                while true do
                    j = src:find(pat, j)
                    if not j then error(("line %d: unfinished string"):format(line), 0) end
                    local d = src:sub(j, j)
                    if d == "\\" then j = j + 2
                    elseif d == "\n" then error(("line %d: unfinished string"):format(line), 0)
                    else break end
                end
                local raw = src:sub(i + 1, j - 1)
                push("string", U.unescape(raw))
                line = line + U.count_nl(raw); i = j + 1
            elseif c == "`" then
                -- Luau interpolated string: parts = { {str=...} | {code=...} ... }
                local parts, buf, j = {}, {}, i + 1
                while true do
                    local d = src:sub(j, j)
                    if d == "" then error(("line %d: unfinished interpolated string"):format(line), 0) end
                    if d == "`" then break
                    elseif d == "\\" then buf[#buf + 1] = U.unescape(src:sub(j, j + 1)); j = j + 2
                    elseif d == "{" then
                        parts[#parts + 1] = { str = table.concat(buf) }; buf = {}
                        local k, dep = j + 1, 1
                        while dep > 0 do
                            local ch = src:sub(k, k)
                            if ch == "" then error(("line %d: unfinished interpolation"):format(line), 0) end
                            if ch == "{" then dep = dep + 1 elseif ch == "}" then dep = dep - 1 end
                            k = k + 1
                        end
                        parts[#parts + 1] = { code = src:sub(j + 1, k - 2) }
                        j = k
                    else
                        if d == "\n" then line = line + 1 end
                        buf[#buf + 1] = d; j = j + 1
                    end
                end
                parts[#parts + 1] = { str = table.concat(buf) }
                push("interp", parts); i = j + 1
            elseif c == "[" and src:find("^%[=*%[", i) then
                local eq = src:match("^%[(=*)%[", i)
                local e, e2 = src:find("]" .. eq .. "]", i + #eq + 2, true)
                if not e then error(("line %d: unfinished long string"):format(line), 0) end
                local body = src:sub(i + #eq + 2, e - 1)
                if body:sub(1, 1) == "\n" then body = body:sub(2) elseif body:sub(1, 2) == "\r\n" then body = body:sub(3) end
                push("string", body)
                line = line + U.count_nl(src:sub(i, e2)); i = e2 + 1
            else
                local three, two = src:sub(i, i + 2), src:sub(i, i + 1)
                if three == "..." then push("op", "..."); i = i + 3
                elseif three == "..=" or three == "//=" then push("op", three); i = i + 3
                elseif two == "==" or two == "~=" or two == "<=" or two == ">=" or two == ".." or two == "//" or two == "::"
                    or two == "+=" or two == "-=" or two == "*=" or two == "/=" or two == "%=" or two == "^=" then
                    push("op", two); i = i + 2
                elseif c:find("[%+%-%*/%%%^#<>=%(%){}%[%];:,%.%?|&]") then push("op", c); i = i + 1
                else error(("line %d: unexpected character '%s'"):format(line, c), 0) end
            end
        end
        nt = nt + 1; T[nt] = "eof"; V[nt] = "<eof>"; L[nt] = line
        return T, V, L, nt
    end

    return M
end
