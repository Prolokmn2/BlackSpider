-- BlackSpider :: compiler.lua  --  AST -> Lua closures. Executes the target step by step.
-- Besides running the program it records "dynamic folds" on the AST nodes: calls with constant
-- arguments to script-defined (decoder) functions and constant-key array lookups remember the value
-- they produced, so the guesser (guesser.lua) can later replace them with the decoded literal.
return function(BS)
    local U, NET, ST = BS.util, BS.net, BS.state
    local S, R = ST.S, ST.R
    local pack, unpack, floor = U.pack, U.unpack, math.floor
    local log, rec_string, rec_var = ST.log, ST.rec_string, ST.rec_var
    local invoke, invoke_t, rterr, argstr = ST.invoke, ST.invoke_t, ST.rterr, ST.argstr
    local interp, fcount, gseen = R.interp, R.fcount, R.gseen

    local M = {}
    local compile_expr, compile_multi, compile_stmt, compile_block, compile_stmts, compile_func, compile_list

    local function new_fs(parent) return { parent = parent, scope = { vars = {} }, nslots = 0, ups = {}, upmap = {} } end
    local function push_scope(fs) fs.scope = { vars = {}, parent = fs.scope } end
    local function pop_scope(fs) fs.scope = fs.scope.parent end
    local function declare(fs, name) fs.nslots = fs.nslots + 1; fs.scope.vars[name] = fs.nslots; return fs.nslots end
    local function find_local(fs, name)
        local s = fs.scope
        while s do
            local v = s.vars[name]
            if v then return v end
            s = s.parent
        end
    end
    local function resolve(fs, name)
        local slot = find_local(fs, name)
        if slot then return "local", slot end
        if not fs.parent then return "global" end
        local k, idx = resolve(fs.parent, name)
        if k == "global" then return "global" end
        local key = k .. idx
        local u = fs.upmap[key]
        if not u then
            u = #fs.ups + 1
            fs.ups[u] = { islocal = (k == "local"), idx = idx }
            fs.upmap[key] = u
        end
        return "up", u
    end

    local function is_multi(n) return n.k == "call" or n.k == "method" or n.k == "vararg" end
    local function isconst(n)
        local k = n.k
        if k == "str" or k == "num" then return true end
        if k == "paren" then return isconst(n.e) end
        if k == "un" then return n.op == "-" and isconst(n.a) end
        if k == "bin" then
            local op = n.op
            return (op == ".." or op == "+" or op == "-" or op == "*" or op == "/" or op == "%") and isconst(n.a) and isconst(n.b)
        end
        return false
    end

    local function name_guess(n)
        local k = n.k
        if k == "name" then return n.v
        elseif k == "index" then
            local o = name_guess(n.obj) or "?"
            return o .. "." .. (n.key.k == "str" and n.key.v or "?")
        elseif k == "call" then return (name_guess(n.fn) or "?") .. "()"
        elseif k == "method" then return (name_guess(n.obj) or "?") .. ":" .. n.name .. "()"
        elseif k == "paren" then return name_guess(n.e)
        elseif k == "str" then return "str"
        end
        return "?"
    end

    function compile_list(exprs, fs)
        local n = #exprs
        if n == 0 then return function() return {}, 0 end end
        local fns = {}
        for i = 1, n - 1 do fns[i] = compile_expr(exprs[i], fs) end
        local last = exprs[n]
        if is_multi(last) then
            local lm = compile_multi(last, fs)
            return function(fr)
                local t = {}
                for i = 1, n - 1 do t[i] = fns[i](fr) end
                local r = pack(lm(fr))
                for i = 1, r.n do t[n - 1 + i] = r[i] end
                return t, n - 1 + r.n
            end
        end
        fns[n] = compile_expr(last, fs)
        return function(fr)
            local t = {}
            for i = 1, n do t[i] = fns[i](fr) end
            return t, n
        end
    end

    local function compile_call_like(node, fs)
        local args = node.args
        local na = #args
        local multi = na > 0 and is_multi(args[na])
        local ln = node.line
        local isc = node.k == "call"
        local getf, gname
        if isc then
            local ff = compile_expr(node.fn, fs)
            gname = name_guess(node.fn)
            getf = function(fr) return ff(fr), nil end
        else
            local of, mname = compile_expr(node.obj, fs), node.name
            gname = name_guess(node.obj) .. ":" .. mname
            getf = function(fr)
                local s = of(fr)
                if s == nil then rterr("attempt to index a nil value (method '" .. mname .. "')", ln) end
                return s[mname], s
            end
        end
        local hs = not isc

        -- decoder-like call: constant arguments -> remember what a script-defined function returned
        if isc and na >= 1 then
            local allc = true
            for _, a in ipairs(args) do if not isconst(a) then allc = false; break end end
            if allc then
                local list = compile_list(args, fs)
                return function(fr)
                    local f = getf(fr)
                    local t, n = list(fr)
                    local r = pack(invoke_t(gname, f, false, nil, t, n))
                    if interp[f] then
                        local v, d = r[1], node.fold
                        if r.n == 1 and type(v) == "string" and #v <= 4000 then
                            if d == nil then node.fold = { val = v, ok = true }
                            elseif d.val ~= v then d.ok = false end
                        elseif d == nil then node.fold = { ok = false }
                        else d.ok = false end
                    end
                    return unpack(r, 1, r.n)
                end
            end
        end

        if multi or na > 3 then
            local list = compile_list(args, fs)
            return function(fr)
                local f, self = getf(fr)
                local t, n = list(fr)
                return invoke_t(gname, f, hs, self, t, n)
            end
        end
        local a1 = args[1] and compile_expr(args[1], fs)
        local a2 = args[2] and compile_expr(args[2], fs)
        local a3 = args[3] and compile_expr(args[3], fs)
        if na == 0 then
            return function(fr) local f, self = getf(fr); return invoke(gname, f, hs, self) end
        elseif na == 1 then
            return function(fr) local f, self = getf(fr); return invoke(gname, f, hs, self, a1(fr)) end
        elseif na == 2 then
            return function(fr)
                local f, self = getf(fr)
                local x = a1(fr)
                return invoke(gname, f, hs, self, x, a2(fr))
            end
        end
        return function(fr)
            local f, self = getf(fr)
            local x = a1(fr)
            local y = a2(fr)
            return invoke(gname, f, hs, self, x, y, a3(fr))
        end
    end

    function compile_multi(node, fs)
        local k = node.k
        if k == "call" or k == "method" then return compile_call_like(node, fs)
        elseif k == "vararg" then
            return function(fr) local va = fr.va; return unpack(va, 1, va.n) end
        end
        return compile_expr(node, fs)
    end

    local BIN = {
        ["+"] = function(a, b) return function(fr) return a(fr) + b(fr) end end,
        ["-"] = function(a, b) return function(fr) return a(fr) - b(fr) end end,
        ["*"] = function(a, b) return function(fr) return a(fr) * b(fr) end end,
        ["/"] = function(a, b) return function(fr) return a(fr) / b(fr) end end,
        ["%"] = function(a, b) return function(fr) return a(fr) % b(fr) end end,
        ["^"] = function(a, b) return function(fr) return a(fr) ^ b(fr) end end,
        ["//"] = function(a, b) return function(fr) return floor(a(fr) / b(fr)) end end,
        ["=="] = function(a, b) return function(fr) return a(fr) == b(fr) end end,
        ["~="] = function(a, b) return function(fr) return a(fr) ~= b(fr) end end,
        ["<"] = function(a, b) return function(fr) return a(fr) < b(fr) end end,
        ["<="] = function(a, b) return function(fr) return a(fr) <= b(fr) end end,
        [">"] = function(a, b) return function(fr) return a(fr) > b(fr) end end,
        [">="] = function(a, b) return function(fr) return a(fr) >= b(fr) end end,
        ["and"] = function(a, b) return function(fr) return a(fr) and b(fr) end end,
        ["or"] = function(a, b) return function(fr) return a(fr) or b(fr) end end,
    }

    local function compile_concat(node, fs)
        local ops = {}
        local function flat(n)
            if n.k == "bin" and n.op == ".." then flat(n.a); flat(n.b) else ops[#ops + 1] = n end
        end
        flat(node)
        local fns, n = {}, #ops
        for i = 1, n do fns[i] = compile_expr(ops[i], fs) end
        return function(fr)
            local vals = {}
            for i = 1, n do vals[i] = fns[i](fr) end
            local r = vals[n]
            for i = n - 1, 1, -1 do r = vals[i] .. r end
            if type(r) == "string" and #r >= 8 then rec_string("concat", r) end
            return r
        end
    end

    local function compile_table(node, fs)
        local items, n = node.items, #node.items
        local c = {}
        for i, it in ipairs(items) do
            if it.kind == "pos" then
                if i == n and is_multi(it.v) then c[i] = { "posm", compile_multi(it.v, fs) }
                else c[i] = { "pos", compile_expr(it.v, fs) } end
            else
                c[i] = { "kv", compile_expr(it.key, fs), compile_expr(it.v, fs) }
            end
        end
        return function(fr)
            local pos, np, kk, kv, nk = {}, 0, nil, nil, 0
            for i = 1, n do
                local ci = c[i]
                local kind = ci[1]
                if kind == "pos" then np = np + 1; pos[np] = ci[2](fr)
                elseif kind == "posm" then
                    local r = pack(ci[2](fr))
                    for j = 1, r.n do pos[np + j] = r[j] end
                    np = np + r.n
                else
                    nk = nk + 1
                    kk = kk or {}; kv = kv or {}
                    kk[nk] = ci[2](fr); kv[nk] = ci[3](fr)
                end
            end
            local t
            if np == 0 then t = {}
            elseif np <= 4000 then t = { unpack(pos, 1, np) }
            else t = {}; for i = 1, np do t[i] = pos[i] end end
            for i = 1, nk do t[kk[i]] = kv[i] end
            return t
        end
    end

    function compile_func(node, parent_fs, hint)
        local fs = new_fs(parent_fs)
        local pslots = {}
        for i, pn in ipairs(node.params) do pslots[i] = declare(fs, pn) end
        local body = compile_stmts(node.body, fs)
        local ups, np, isva = fs.ups, #pslots, node.vararg
        local hname = node.hint or hint or ("anon@" .. tostring(node.line))
        return function(fr)
            local up = {}
            for i = 1, #ups do
                local c = ups[i]
                if c.islocal then up[i] = fr[c.idx] else up[i] = fr.up[c.idx] end
            end
            local f = function(...)
                local nf = { up = up }
                if np > 0 then
                    local a = { ... }
                    for i = 1, np do nf[pslots[i]] = { a[i] } end
                end
                if isva then nf.va = pack(select(np + 1, ...)) end
                local c = (fcount[hname] or 0) + 1
                fcount[hname] = c
                if c <= 3 then log("fn-call", hname .. "(" .. argstr(...) .. ")") end
                local sig, r = body(nf)
                if sig == 2 then return unpack(r, 1, r.n) end
            end
            interp[f] = true
            return f
        end
    end

    function compile_expr(node, fs)
        local k = node.k
        if k == "nil" then return function() return nil end
        elseif k == "true" then return function() return true end
        elseif k == "false" then return function() return false end
        elseif k == "num" or k == "str" then local v = node.v; return function() return v end
        elseif k == "vararg" then return function(fr) return fr.va[1] end
        elseif k == "func" then return compile_func(node, fs)
        elseif k == "name" then
            local kind, idx = resolve(fs, node.v)
            if kind == "local" then return function(fr) return fr[idx][1] end
            elseif kind == "up" then return function(fr) return fr.up[idx][1] end end
            local nm, E = node.v, S.env
            return function()
                local v = E[nm]
                if not gseen[nm] then gseen[nm] = true; log("global-read", nm .. " (" .. type(v) .. ")") end
                return v
            end
        elseif k == "index" then
            local of, ln = compile_expr(node.obj, fs), node.line
            if node.key.k == "str" then
                local key = node.key.v
                return function(fr)
                    local o = of(fr)
                    if o == nil then rterr("attempt to index a nil value (field '" .. key .. "')", ln) end
                    return o[key]
                end
            end
            if node.key.k == "num" and node.obj.k == "name" then
                -- constant-array lookup (t[12]): remember the value for the guesser
                local kv = node.key.v
                return function(fr)
                    local o = of(fr)
                    if o == nil then rterr("attempt to index a nil value", ln) end
                    local v, d = o[kv], node.fold
                    if type(v) == "string" and #v <= 2000 and type(o) == "table" then
                        if d == nil then node.fold = { val = v, ok = true }
                        elseif d.val ~= v then d.ok = false end
                    elseif d == nil then node.fold = { ok = false }
                    else d.ok = false end
                    return v
                end
            end
            local kf = compile_expr(node.key, fs)
            return function(fr)
                local o = of(fr)
                if o == nil then rterr("attempt to index a nil value", ln) end
                return o[kf(fr)]
            end
        elseif k == "call" or k == "method" then
            local m = compile_call_like(node, fs)
            return function(fr) return (m(fr)) end
        elseif k == "paren" then return compile_expr(node.e, fs)
        elseif k == "table" then return compile_table(node, fs)
        elseif k == "ifexpr" then
            local conds, vals, n = {}, {}, #node.conds
            for i = 1, n do conds[i] = compile_expr(node.conds[i], fs); vals[i] = compile_expr(node.vals[i], fs) end
            local els = compile_expr(node.els, fs)
            return function(fr)
                for i = 1, n do if conds[i](fr) then return vals[i](fr) end end
                return els(fr)
            end
        elseif k == "bin" then
            if node.op == ".." then return compile_concat(node, fs) end
            return BIN[node.op](compile_expr(node.a, fs), compile_expr(node.b, fs))
        elseif k == "un" then
            local a = compile_expr(node.a, fs)
            if node.op == "-" then
                if node.a.k == "num" then local v = -node.a.v; return function() return v end end
                return function(fr) return -a(fr) end
            elseif node.op == "not" then return function(fr) return not a(fr) end
            else return function(fr) return #a(fr) end end
        end
        error("compile: unknown node " .. tostring(k))
    end

    function compile_stmts(stmts, fs)
        local fns, lines, n = {}, {}, 0
        for _, s in ipairs(stmts) do n = n + 1; fns[n] = compile_stmt(s, fs); lines[n] = s.line or 0 end
        if n == 0 then return function() end end
        local tick = ST.tick
        return function(fr)
            for i = 1, n do
                S.cur_line = lines[i]
                S.steps = S.steps + 1
                if S.steps > S.next_check then tick() end
                local sig, r = fns[i](fr)
                if sig then return sig, r end
            end
        end
    end

    function compile_block(stmts, fs)
        push_scope(fs)
        local f = compile_stmts(stmts, fs)
        pop_scope(fs)
        return f
    end

    local function make_setter(tg, fs)
        if tg.k == "name" then
            local kind, idx = resolve(fs, tg.v)
            if kind == "local" then return { t = "local", slot = idx, name = tg.v }
            elseif kind == "up" then return { t = "up", idx = idx, name = tg.v } end
            return { t = "global", name = tg.v }
        end
        local key = tg.key.k == "str" and tg.key.v or "[]"
        return { t = "index", of = compile_expr(tg.obj, fs), kf = compile_expr(tg.key, fs), ln = tg.line, name = key }
    end

    function compile_stmt(s, fs)
        local k = s.k
        if k == "local" then
            local exprs, names = s.exprs, s.names
            for i, e in ipairs(exprs) do if e.k == "func" then e.hint = names[i] end end
            local nn = #names
            if #exprs == 1 and nn == 1 then
                local ef = compile_expr(exprs[1], fs)
                local slot, nm = declare(fs, names[1]), names[1]
                return function(fr) local v = ef(fr); fr[slot] = { v }; rec_var(nm, v) end
            end
            local list = compile_list(exprs, fs)
            local slots = {}
            for i, nm in ipairs(names) do slots[i] = declare(fs, nm) end
            return function(fr)
                local t = list(fr)
                for i = 1, nn do local v = t[i]; fr[slots[i]] = { v }; rec_var(names[i], v) end
            end
        elseif k == "localfunc" then
            local slot = declare(fs, s.name)
            s.func.hint = s.name
            local mk = compile_func(s.func, fs)
            return function(fr) local cell = {}; fr[slot] = cell; cell[1] = mk(fr) end
        elseif k == "assign" then
            local targets, exprs = s.targets, s.exprs
            for i, e in ipairs(exprs) do if e.k == "func" then e.hint = name_guess(targets[i] or targets[1]) end end
            local nt = #targets
            local E = S.env
            if nt == 1 and #exprs == 1 then
                local tg = make_setter(targets[1], fs)
                local ef = compile_expr(exprs[1], fs)
                local nm = tg.name
                if tg.t == "local" then
                    local slot = tg.slot
                    return function(fr) local v = ef(fr); fr[slot][1] = v; rec_var(nm, v) end
                elseif tg.t == "up" then
                    local idx = tg.idx
                    return function(fr) local v = ef(fr); fr.up[idx][1] = v; rec_var(nm, v) end
                elseif tg.t == "global" then
                    return function(fr)
                        local v = ef(fr)
                        if NET.allow(E, nm, v) then E[nm] = v end
                        rec_var(nm, v)
                    end
                end
                local of, kf, ln = tg.of, tg.kf, tg.ln
                return function(fr)
                    local o = of(fr)
                    local key = kf(fr)
                    local v = ef(fr)
                    if o == nil then rterr("attempt to index a nil value (assignment to '" .. nm .. "')", ln) end
                    if (o == E or NET.fields[o]) and not NET.allow(o, key, v) then return end
                    o[key] = v
                    if type(v) == "string" then rec_var(nm, v) end
                end
            end
            local list = compile_list(exprs, fs)
            local sets = {}
            for i, tg in ipairs(targets) do sets[i] = make_setter(tg, fs) end
            return function(fr)
                local objs, keys = {}, {}
                for i = 1, nt do
                    local st = sets[i]
                    if st.t == "index" then objs[i] = st.of(fr); keys[i] = st.kf(fr) end
                end
                local t = list(fr)
                for i = nt, 1, -1 do
                    local st, v = sets[i], t[i]
                    if st.t == "local" then fr[st.slot][1] = v
                    elseif st.t == "up" then fr.up[st.idx][1] = v
                    elseif st.t == "global" then
                        if NET.allow(E, st.name, v) then E[st.name] = v end
                    else
                        if objs[i] == nil then rterr("attempt to index a nil value", st.ln) end
                        if not ((objs[i] == E or NET.fields[objs[i]]) and not NET.allow(objs[i], keys[i], v)) then
                            objs[i][keys[i]] = v
                        end
                    end
                    rec_var(st.name, v)
                end
            end
        elseif k == "callstat" then
            local m = compile_multi(s.e, fs)
            return function(fr) m(fr) end
        elseif k == "do" then return compile_block(s.body, fs)
        elseif k == "while" then
            local c = compile_expr(s.cond, fs)
            local b = compile_block(s.body, fs)
            return function(fr)
                while c(fr) do
                    local sig, r = b(fr)
                    if sig then
                        if sig == 1 then break elseif sig == 2 then return sig, r end
                    end
                end
            end
        elseif k == "repeat" then
            push_scope(fs)
            local b = compile_stmts(s.body, fs)
            local c = compile_expr(s.cond, fs)
            pop_scope(fs)
            return function(fr)
                repeat
                    local sig, r = b(fr)
                    if sig then
                        if sig == 1 then break elseif sig == 2 then return sig, r end
                    end
                until c(fr)
            end
        elseif k == "if" then
            local conds, blocks, nc = {}, {}, #s.conds
            for i = 1, nc do conds[i] = compile_expr(s.conds[i], fs); blocks[i] = compile_block(s.blocks[i], fs) end
            local els = s.els and compile_block(s.els, fs)
            return function(fr)
                for i = 1, nc do
                    if conds[i](fr) then return blocks[i](fr) end
                end
                if els then return els(fr) end
            end
        elseif k == "fornum" then
            local af, bf = compile_expr(s.a, fs), compile_expr(s.b, fs)
            local cf = s.c and compile_expr(s.c, fs)
            push_scope(fs)
            local slot = declare(fs, s.var)
            local body = compile_block(s.body, fs)
            pop_scope(fs)
            return function(fr)
                local a, b = af(fr), bf(fr)
                local c = cf and cf(fr) or 1
                for i = a, b, c do
                    fr[slot] = { i }
                    local sig, r = body(fr)
                    if sig then
                        if sig == 1 then break elseif sig == 2 then return sig, r end
                    end
                end
            end
        elseif k == "forin" then
            local list = compile_list(s.exprs, fs)
            push_scope(fs)
            local slots, nn = {}, #s.names
            for i, nm in ipairs(s.names) do slots[i] = declare(fs, nm) end
            local body = compile_block(s.body, fs)
            pop_scope(fs)
            return function(fr)
                local t = list(fr)
                local f, st, var = t[1], t[2], t[3]
                if f == nil then rterr("attempt to call a nil value (for iterator)") end
                while true do
                    if nn <= 2 then
                        local a1, a2 = f(st, var)
                        if a1 == nil then break end
                        var = a1
                        fr[slots[1]] = { a1 }
                        if nn == 2 then fr[slots[2]] = { a2 } end
                    else
                        local r = pack(f(st, var))
                        if r[1] == nil then break end
                        var = r[1]
                        for i = 1, nn do fr[slots[i]] = { r[i] } end
                    end
                    local sig, rr = body(fr)
                    if sig then
                        if sig == 1 then break elseif sig == 2 then return sig, rr end
                    end
                end
            end
        elseif k == "return" then
            local exprs = s.exprs
            if #exprs == 0 then return function() return 2, { n = 0 } end end
            if #exprs == 1 and not is_multi(exprs[1]) then
                local ef = compile_expr(exprs[1], fs)
                return function(fr) return 2, { n = 1, ef(fr) } end
            end
            local list = compile_list(exprs, fs)
            return function(fr) local t, n = list(fr); t.n = n; return 2, t end
        elseif k == "break" then return function() return 1 end
        elseif k == "continue" then return function() return 3 end
        end
        error("compile: unknown statement " .. tostring(k))
    end

    -- returns the runnable chunk and its AST (the guesser works on the AST)
    function M.load_interp(src, chunkname)
        local ok, ast, consts = pcall(BS.parser.parse, src)
        if not ok then return nil, tostring(ast) end
        for _, c in ipairs(consts or {}) do ST.scan_string("constant", c) end
        local ok2, mk = pcall(compile_func, ast, nil, chunkname or "chunk")
        if not ok2 then return nil, "compile: " .. tostring(mk) end
        return mk({ up = {} }), ast
    end

    return M
end
