-- BlackSpider :: parser.lua  --  recursive descent parser -> AST (no nesting limit, recursion is in Lua)
-- Supports Lua 5.1 + continue, compound assignment (+= ..= etc), //, Luau type annotations (skipped),
-- `type X = ...`, `x :: T` casts, if-expressions, `interpolated {strings}`, 0b / 1_000 numbers.
-- Not supported: goto / labels.
return function(BS)
    local M = {}
    local lex = BS.lexer.lex

    local BINPRI = {
        ["or"] = { 1, 1 }, ["and"] = { 2, 2 },
        ["<"] = { 3, 3 }, [">"] = { 3, 3 }, ["<="] = { 3, 3 }, [">="] = { 3, 3 }, ["~="] = { 3, 3 }, ["=="] = { 3, 3 },
        [".."] = { 5, 4 }, ["+"] = { 6, 6 }, ["-"] = { 6, 6 },
        ["*"] = { 7, 7 }, ["/"] = { 7, 7 }, ["//"] = { 7, 7 }, ["%"] = { 7, 7 }, ["^"] = { 10, 9 },
    }
    local COMPOUND = { ["+="] = "+", ["-="] = "-", ["*="] = "*", ["/="] = "/", ["%="] = "%", ["^="] = "^", ["..="] = "..", ["//="] = "//" }

    function M.parse(src)
        local T, V, L = lex(src)
        local p = 1
        local parse_block, parse_expr, parse_subexpr, parse_statement, parse_suffixed, parse_table, parse_funcbody

        local function err(msg) error(("line %d: %s near '%s'"):format(L[p], msg, tostring(V[p])), 0) end
        local function is(t, v) return T[p] == t and (v == nil or V[p] == v) end
        local function accept(t, v) if is(t, v) then p = p + 1; return true end return false end
        local function expect(t, v)
            if not is(t, v) then err("expected '" .. tostring(v or t) .. "'") end
            local x = V[p]; p = p + 1; return x
        end
        local function block_end()
            local t, v = T[p], V[p]
            return t == "eof" or (t == "kw" and (v == "end" or v == "else" or v == "elseif" or v == "until"))
        end

        -- ---- Luau types: parsed and thrown away ------------------------------------------
        local function skip_balanced(open, close)
            local depth = 0
            repeat
                if T[p] == "op" and V[p] == open then depth = depth + 1
                elseif T[p] == "op" and V[p] == close then depth = depth - 1
                elseif T[p] == "eof" then err("unbalanced type") end
                p = p + 1
            until depth == 0
        end
        local skip_type
        local function skip_type_simple()
            local t, v = T[p], V[p]
            if t == "op" and v == "{" then skip_balanced("{", "}")
            elseif t == "op" and v == "(" then
                skip_balanced("(", ")")
                if is("op", "-") and T[p + 1] == "op" and V[p + 1] == ">" then p = p + 2; skip_type() end
            elseif t == "name" then
                p = p + 1
                if v == "typeof" and is("op", "(") then skip_balanced("(", ")")
                else
                    while is("op", ".") do p = p + 1; expect("name") end
                    if is("op", "<") then skip_balanced("<", ">") end
                end
            elseif t == "string" or (t == "kw" and (v == "nil" or v == "true" or v == "false")) then p = p + 1
            elseif t == "op" and v == "..." then p = p + 1; skip_type_simple()
            else err("type expected") end
            while is("op", "?") do p = p + 1 end
        end
        function skip_type()
            skip_type_simple()
            while is("op", "|") or is("op", "&") do p = p + 1; skip_type_simple() end
        end
        local function opt_type() if is("op", ":") then p = p + 1; skip_type() end end

        local function parse_exprlist()
            local l = { parse_expr() }
            while accept("op", ",") do l[#l + 1] = parse_expr() end
            return l
        end

        local function parse_callargs()
            if T[p] == "string" then local s = V[p]; p = p + 1; return { { k = "str", v = s } } end
            if T[p] == "interp" then local n = parse_subexpr(8); return { n } end
            if is("op", "{") then return { parse_table() } end
            expect("op", "(")
            local args = {}
            if not is("op", ")") then args = parse_exprlist() end
            expect("op", ")")
            return args
        end

        local function parse_primary()
            local t, v = T[p], V[p]
            if t == "name" then p = p + 1; return { k = "name", v = v, line = L[p - 1] }
            elseif t == "op" and v == "(" then
                p = p + 1
                local e = parse_expr(); expect("op", ")")
                return { k = "paren", e = e }
            end
            err("unexpected symbol")
        end

        function parse_suffixed()
            local e = parse_primary()
            while true do
                local t, v = T[p], V[p]
                if t == "op" and v == "." then
                    p = p + 1
                    local ln = L[p]; local k = expect("name")
                    e = { k = "index", obj = e, key = { k = "str", v = k }, line = ln }
                elseif t == "op" and v == "[" then
                    local ln = L[p]; p = p + 1
                    local k = parse_expr(); expect("op", "]")
                    e = { k = "index", obj = e, key = k, line = ln }
                elseif t == "op" and v == ":" then
                    p = p + 1
                    local ln = L[p]; local nm = expect("name")
                    e = { k = "method", obj = e, name = nm, args = parse_callargs(), line = ln }
                elseif (t == "op" and (v == "(" or v == "{")) or t == "string" or t == "interp" then
                    local ln = L[p]
                    e = { k = "call", fn = e, args = parse_callargs(), line = ln }
                else break end
            end
            return e
        end

        function parse_funcbody(is_method)
            local ln = L[p]
            if is("op", "<") then skip_balanced("<", ">") end
            expect("op", "(")
            local params, vararg = {}, false
            if is_method then params[1] = "self" end
            if not is("op", ")") then
                repeat
                    if accept("op", "...") then vararg = true; opt_type(); break end
                    params[#params + 1] = expect("name")
                    opt_type()
                until not accept("op", ",")
            end
            expect("op", ")")
            opt_type()
            local body = parse_block(); expect("kw", "end")
            return { k = "func", params = params, vararg = vararg, body = body, line = ln, method = is_method }
        end

        function parse_table()
            expect("op", "{")
            local items = {}
            while not is("op", "}") do
                if is("op", "[") then
                    p = p + 1
                    local k = parse_expr(); expect("op", "]"); expect("op", "=")
                    items[#items + 1] = { kind = "kv", key = k, v = parse_expr() }
                elseif T[p] == "name" and T[p + 1] == "op" and V[p + 1] == "=" then
                    local k = V[p]; p = p + 2
                    items[#items + 1] = { kind = "kv", key = { k = "str", v = k }, v = parse_expr() }
                else
                    items[#items + 1] = { kind = "pos", v = parse_expr() }
                end
                if not (accept("op", ",") or accept("op", ";")) then break end
            end
            expect("op", "}")
            return { k = "table", items = items }
        end

        local function parse_interp(parts, ln)
            local acc
            for _, part in ipairs(parts) do
                local node
                if part.str then
                    if part.str ~= "" then node = { k = "str", v = part.str } end
                else
                    local sub = M.parse("return " .. part.code)
                    local ex = sub.body[1] and sub.body[1].exprs and sub.body[1].exprs[1]
                    if not ex then error(("line %d: bad interpolation"):format(ln), 0) end
                    node = { k = "call", fn = { k = "name", v = "tostring", line = ln }, args = { ex }, line = ln }
                end
                if node then acc = acc and { k = "bin", op = "..", a = acc, b = node } or node end
            end
            return acc or { k = "str", v = "" }
        end

        local function parse_simple()
            local t, v = T[p], V[p]
            if t == "number" then p = p + 1; return { k = "num", v = v }
            elseif t == "string" then p = p + 1; return { k = "str", v = v }
            elseif t == "interp" then local ln = L[p]; p = p + 1; return parse_interp(v, ln)
            elseif t == "kw" and v == "nil" then p = p + 1; return { k = "nil" }
            elseif t == "kw" and v == "true" then p = p + 1; return { k = "true" }
            elseif t == "kw" and v == "false" then p = p + 1; return { k = "false" }
            elseif t == "op" and v == "..." then p = p + 1; return { k = "vararg" }
            elseif t == "op" and v == "{" then return parse_table()
            elseif t == "kw" and v == "function" then p = p + 1; return parse_funcbody(false)
            elseif t == "kw" and v == "if" then
                p = p + 1
                local conds, vals = {}, {}
                conds[1] = parse_expr(); expect("kw", "then"); vals[1] = parse_expr()
                while accept("kw", "elseif") do
                    conds[#conds + 1] = parse_expr(); expect("kw", "then"); vals[#vals + 1] = parse_expr()
                end
                expect("kw", "else")
                return { k = "ifexpr", conds = conds, vals = vals, els = parse_expr() }
            end
            return parse_suffixed()
        end

        function parse_subexpr(limit)
            local left
            local t, v = T[p], V[p]
            if (t == "kw" and v == "not") or (t == "op" and (v == "-" or v == "#")) then
                p = p + 1
                left = { k = "un", op = v, a = parse_subexpr(8) }
            else
                left = parse_simple()
            end
            while true do
                while is("op", "::") do p = p + 1; skip_type() end
                t, v = T[p], V[p]
                local op = ((t == "op") or (t == "kw" and (v == "and" or v == "or"))) and v or nil
                local pri = op and BINPRI[op]
                if not pri or pri[1] <= limit then break end
                p = p + 1
                local right = parse_subexpr(pri[2])
                left = { k = "bin", op = op, a = left, b = right }
            end
            return left
        end
        function parse_expr() return parse_subexpr(0) end

        function parse_block()
            local stmts = {}
            while not block_end() do
                local s = parse_statement()
                if s then
                    stmts[#stmts + 1] = s
                    if s.k == "return" then break end
                end
            end
            return stmts
        end

        function parse_statement()
            local ln = L[p]
            if accept("op", ";") then return nil end
            local t, v = T[p], V[p]
            if t == "kw" then
                if v == "if" then
                    p = p + 1
                    local conds, blocks, els = {}, {}, nil
                    conds[1] = parse_expr(); expect("kw", "then"); blocks[1] = parse_block()
                    while true do
                        if accept("kw", "elseif") then
                            conds[#conds + 1] = parse_expr(); expect("kw", "then"); blocks[#blocks + 1] = parse_block()
                        elseif accept("kw", "else") then
                            els = parse_block(); expect("kw", "end"); break
                        else expect("kw", "end"); break end
                    end
                    return { k = "if", conds = conds, blocks = blocks, els = els, line = ln }
                elseif v == "while" then
                    p = p + 1
                    local c = parse_expr(); expect("kw", "do")
                    local b = parse_block(); expect("kw", "end")
                    return { k = "while", cond = c, body = b, line = ln }
                elseif v == "do" then
                    p = p + 1
                    local b = parse_block(); expect("kw", "end")
                    return { k = "do", body = b, line = ln }
                elseif v == "for" then
                    p = p + 1
                    local n1 = expect("name"); opt_type()
                    if is("op", "=") then
                        p = p + 1
                        local a = parse_expr(); expect("op", ",")
                        local b = parse_expr()
                        local c = nil
                        if accept("op", ",") then c = parse_expr() end
                        expect("kw", "do")
                        local body = parse_block(); expect("kw", "end")
                        return { k = "fornum", var = n1, a = a, b = b, c = c, body = body, line = ln }
                    end
                    local names = { n1 }
                    while accept("op", ",") do names[#names + 1] = expect("name"); opt_type() end
                    expect("kw", "in")
                    local exprs = parse_exprlist(); expect("kw", "do")
                    local body = parse_block(); expect("kw", "end")
                    return { k = "forin", names = names, exprs = exprs, body = body, line = ln }
                elseif v == "repeat" then
                    p = p + 1
                    local b = parse_block(); expect("kw", "until")
                    return { k = "repeat", body = b, cond = parse_expr(), line = ln }
                elseif v == "function" then
                    p = p + 1
                    local target = { k = "name", v = expect("name"), line = ln }
                    local is_method = false
                    while is("op", ".") do
                        p = p + 1
                        target = { k = "index", obj = target, key = { k = "str", v = expect("name") }, line = ln }
                    end
                    if accept("op", ":") then
                        target = { k = "index", obj = target, key = { k = "str", v = expect("name") }, line = ln }
                        is_method = true
                    end
                    local f = parse_funcbody(is_method)
                    return { k = "assign", targets = { target }, exprs = { f }, line = ln, fstat = true }
                elseif v == "local" then
                    p = p + 1
                    if accept("kw", "function") then
                        local nm = expect("name")
                        return { k = "localfunc", name = nm, func = parse_funcbody(false), line = ln }
                    end
                    local names = {}
                    repeat
                        names[#names + 1] = expect("name")
                        opt_type()
                        if is("op", "<") then p = p + 1; expect("name"); expect("op", ">") end
                    until not accept("op", ",")
                    local exprs = {}
                    if accept("op", "=") then exprs = parse_exprlist() end
                    return { k = "local", names = names, exprs = exprs, line = ln }
                elseif v == "return" then
                    p = p + 1
                    local exprs = {}
                    if not block_end() and not is("op", ";") then exprs = parse_exprlist() end
                    accept("op", ";")
                    return { k = "return", exprs = exprs, line = ln }
                elseif v == "break" then
                    p = p + 1
                    return { k = "break", line = ln }
                end
            elseif t == "name" and v == "continue" and T[p + 1] == "kw"
                and (V[p + 1] == "end" or V[p + 1] == "else" or V[p + 1] == "elseif" or V[p + 1] == "until") then
                p = p + 1
                return { k = "continue", line = ln }
            elseif t == "name" and (v == "type" or v == "export") then
                local q = p
                if v == "export" and T[q + 1] == "name" and V[q + 1] == "type" then q = q + 1 end
                if T[q] == "name" and V[q] == "type" and T[q + 1] == "name" then
                    p = q + 2
                    if is("op", "<") then skip_balanced("<", ">") end
                    expect("op", "=")
                    skip_type()
                    return nil
                end
            end
            local e = parse_suffixed()
            if is("op", "=") or is("op", ",") then
                local targets = { e }
                while accept("op", ",") do targets[#targets + 1] = parse_suffixed() end
                expect("op", "=")
                local exprs = parse_exprlist()
                for _, tg in ipairs(targets) do
                    if tg.k ~= "name" and tg.k ~= "index" then err("cannot assign to this expression") end
                end
                return { k = "assign", targets = targets, exprs = exprs, line = ln }
            elseif T[p] == "op" and COMPOUND[V[p]] then
                local op = COMPOUND[V[p]]; p = p + 1
                local rhs = parse_expr()
                return { k = "assign", targets = { e }, exprs = { { k = "bin", op = op, a = e, b = rhs } }, line = ln, compound = true }
            end
            if e.k ~= "call" and e.k ~= "method" then err("syntax error") end
            return { k = "callstat", e = e, line = ln }
        end

        local body = parse_block()
        if T[p] ~= "eof" then err("unexpected symbol") end
        local consts = {}
        for k = 1, #T do if T[k] == "string" and #V[k] >= 8 then consts[#consts + 1] = V[k] end end
        return { k = "func", params = {}, vararg = true, body = body, line = 1 }, consts
    end

    return M
end
