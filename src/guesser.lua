-- BlackSpider :: guesser.lua  --  the "code guesser" (deobfuscator).  Three layers:
--
--  1. G.clean(ast)   static pass over the parsed AST that rebuilds readable source:
--       * constant folding      "a".."b", 2*8, string.char(72,105), ("x"):reverse(), bit32.bxor(1,2) ...
--       * DYNAMIC folding       calls like decode("\x12\x7f") to script-defined decoder functions and
--                               lookups like T[41] into constant string arrays are replaced by the value
--                               they really produced while the sandbox ran the script
--       * literal inlining      local a = "https://x"  -> uses become the literal
--       * dead branch removal   if 1 == 2 then ... end
--       * renaming              IIlIlI / _0x3fa1 / v12 -> names derived from how the value is used
--                               (game:GetService("Players") -> Players, Instance.new("Frame") -> frame ...)
--       * pretty printing       a["b"] -> a.b, method calls, indentation, minimal parentheses
--  2. G.trace()      rebuilds the *runtime behaviour* (what the script did to the environment) as code,
--                    with aliases, `local x = Instance.new(..)` for objects that are used later and
--                    callbacks grouped under the event the emulator fired.  This is what saves you on
--                    VM-style obfuscators where the AST itself is just an interpreter.
--  3. G.decoded()    every string the dynamic folder decoded, with the source line.
return function(BS)
    local U, C, ST = BS.util, BS.config, BS.state
    local R = ST.R
    local KW = BS.lexer.KW
    local floor = math.floor
    local G = {}

    -- ============================================================ literals / helpers
    local function islit(n)
        local k = n.k
        return k == "str" or k == "num" or k == "true" or k == "false" or k == "nil"
    end
    local function litval(n)
        if n.k == "str" or n.k == "num" then return n.v
        elseif n.k == "true" then return true
        elseif n.k == "false" then return false end
        return nil
    end
    local function mklit(v)
        local t = type(v)
        if t == "string" then return { k = "str", v = v }
        elseif t == "number" then return { k = "num", v = v }
        elseif t == "boolean" then return { k = v and "true" or "false" } end
        return { k = "nil" }
    end
    local function truthy(n) return not (n.k == "nil" or n.k == "false") end
    local function finite(v) return v == v and v ~= math.huge and v ~= -math.huge end
    local function ident(s) return type(s) == "string" and s:find("^[%a_][%w_]*$") ~= nil and not KW[s] end

    local PURE = {}
    do
        local function add(path, f) if f then PURE[path] = f end end
        for _, n in ipairs({ "char", "reverse", "lower", "upper", "sub", "rep", "byte", "len", "format" }) do add("string." .. n, string[n]) end
        for _, n in ipairs({ "floor", "ceil", "abs", "max", "min", "sqrt", "fmod" }) do add("math." .. n, math[n]) end
        add("tostring", tostring); add("tonumber", tonumber); add("table.concat", table.concat)
        if type(bit32) == "table" then
            for _, n in ipairs({ "bxor", "band", "bor", "bnot", "lshift", "rshift", "arshift", "lrotate", "rrotate" }) do add("bit32." .. n, bit32[n]) end
        end
        if type(bit) == "table" then
            for _, n in ipairs({ "bxor", "band", "bor", "bnot", "lshift", "rshift" }) do add("bit." .. n, bit[n]) end
        end
    end

    -- ============================================================ pass 1: resolve scopes
    local function analyze_ast(root, st)
        local scope
        local function push() scope = { vars = {}, parent = scope } end
        local function pop() scope = scope.parent end
        local function lookup(name)
            local s = scope
            while s do
                local d = s.vars[name]
                if d then return d end
                s = s.parent
            end
        end
        local function declare(name, kind)
            local d = { orig = name, kind = kind, assigns = 0, uses = 0 }
            scope.vars[name] = d
            st.decls[#st.decls + 1] = d
            return d
        end
        local ex, stmts, stmt, fn

        local function args_escape(args)
            for _, a in ipairs(args) do
                ex(a)
                if a.k == "name" and a.decl then a.decl.escaped = true end
            end
        end
        function ex(e)
            local k = e.k
            if k == "name" then
                local d = lookup(e.v)
                e.decl = d
                if d then d.uses = d.uses + 1 else st.globals[e.v] = true end
            elseif k == "index" then ex(e.obj); ex(e.key)
            elseif k == "call" then ex(e.fn); args_escape(e.args)
            elseif k == "method" then ex(e.obj); args_escape(e.args)
            elseif k == "func" then fn(e)
            elseif k == "bin" then ex(e.a); ex(e.b)
            elseif k == "un" then ex(e.a)
            elseif k == "paren" then ex(e.e)
            elseif k == "table" then
                for _, it in ipairs(e.items) do
                    if it.kind == "kv" then ex(it.key) end
                    ex(it.v)
                end
            elseif k == "ifexpr" then
                for i = 1, #e.conds do ex(e.conds[i]); ex(e.vals[i]) end
                ex(e.els)
            end
        end
        function fn(e)
            push()
            e.pdecls = {}
            for i, pn in ipairs(e.params) do e.pdecls[i] = declare(pn, "param") end
            stmts(e.body)
            pop()
        end
        function stmts(list) for _, s in ipairs(list) do stmt(s) end end
        function stmt(s)
            local k = s.k
            if k == "local" then
                for _, e in ipairs(s.exprs) do ex(e) end
                s.decls = {}
                local ne = #s.exprs
                for i, nm in ipairs(s.names) do
                    local d = declare(nm, "local")
                    s.decls[i] = d
                    local e = s.exprs[i]
                    if e and (i < ne or not (e.k == "call" or e.k == "method" or e.k == "vararg")) then d.init = e end
                    if d.init and d.init.k == "table" and #d.init.items >= 3 then
                        local ok = true
                        for _, it in ipairs(d.init.items) do
                            if it.kind ~= "pos" or not (it.v.k == "str" or it.v.k == "num") then ok = false; break end
                        end
                        d.constarr = ok
                    end
                end
            elseif k == "localfunc" then
                s.decl = declare(s.name, "func"); s.decl.init = s.func
                ex(s.func)
            elseif k == "assign" then
                for _, e in ipairs(s.exprs) do ex(e) end
                for _, tg in ipairs(s.targets) do
                    if tg.k == "name" then
                        ex(tg)
                        if tg.decl then tg.decl.assigns = tg.decl.assigns + 1 end
                    else
                        ex(tg.obj); ex(tg.key)
                        if tg.obj.k == "name" and tg.obj.decl then tg.obj.decl.tablewrite = true end
                    end
                end
            elseif k == "callstat" then ex(s.e)
            elseif k == "do" then push(); stmts(s.body); pop()
            elseif k == "while" then ex(s.cond); push(); stmts(s.body); pop()
            elseif k == "repeat" then push(); stmts(s.body); ex(s.cond); pop()
            elseif k == "if" then
                for i = 1, #s.conds do ex(s.conds[i]); push(); stmts(s.blocks[i]); pop() end
                if s.els then push(); stmts(s.els); pop() end
            elseif k == "fornum" then
                ex(s.a); ex(s.b); if s.c then ex(s.c) end
                push(); s.vdecl = declare(s.var, "loop"); stmts(s.body); pop()
            elseif k == "forin" then
                for _, e in ipairs(s.exprs) do ex(e) end
                push()
                s.vdecls = {}
                for i, nm in ipairs(s.names) do s.vdecls[i] = declare(nm, "loop") end
                stmts(s.body); pop()
            elseif k == "return" then
                for _, e in ipairs(s.exprs) do ex(e) end
            end
        end
        fn(root)
    end

    -- ============================================================ module state for one clean() run
    local STATS, FOLD, INLINE, DEAD, RENAME
    local buf, ind, used, counters

    -- ============================================================ constant folding
    local function evalbin(op, a, b)
        local ta, tb = type(a), type(b)
        if op == "==" then return a == b, true end
        if op == "~=" then return a ~= b, true end
        if op == ".." then
            local function s(v)
                if type(v) == "string" then return v end
                if type(v) == "number" and v == floor(v) and math.abs(v) < 1e15 then return ("%d"):format(v) end
                return nil
            end
            local sa, sb = s(a), s(b)
            if sa and sb then return sa .. sb, true end
            return nil, false
        end
        if ta == "number" and tb == "number" then
            local ok, r
            if op == "+" then ok, r = true, a + b
            elseif op == "-" then ok, r = true, a - b
            elseif op == "*" then ok, r = true, a * b
            elseif op == "/" then if b ~= 0 then ok, r = true, a / b end
            elseif op == "%" then if b ~= 0 then ok, r = true, a % b end
            elseif op == "^" then ok, r = true, a ^ b
            elseif op == "//" then if b ~= 0 then ok, r = true, floor(a / b) end
            elseif op == "<" then ok, r = true, a < b
            elseif op == "<=" then ok, r = true, a <= b
            elseif op == ">" then ok, r = true, a > b
            elseif op == ">=" then ok, r = true, a >= b end
            if ok and (type(r) == "boolean" or finite(r)) then return r, true end
        elseif ta == "string" and tb == "string" then
            if op == "<" then return a < b, true elseif op == "<=" then return a <= b, true
            elseif op == ">" then return a > b, true elseif op == ">=" then return a >= b, true end
        end
        return nil, false
    end

    local function path_of(e)
        if e.k == "name" then
            local d = e.decl
            if d then
                if d.alias == nil then
                    d.alias = false
                    if d.assigns == 0 and d.init then d.alias = path_of(d.init) or false end
                end
                return d.alias or nil
            end
            return e.v
        elseif e.k == "index" and e.key.k == "str" then
            local b = path_of(e.obj)
            if b then return b .. "." .. e.key.v end
        end
    end
    local function path_raw(e)
        if e.k == "name" then return e.v
        elseif e.k == "index" and e.key.k == "str" then
            local b = path_raw(e.obj)
            if b then return b .. "." .. e.key.v end
        end
    end

    local function try_pure(node)
        local path, args
        if node.k == "call" then path = path_of(node.fn); args = node.args
        elseif node.k == "method" and node.obj.k == "str" then
            path = "string." .. node.name
            args = { node.obj }
            for _, a in ipairs(node.args) do args[#args + 1] = a end
        end
        if not path then return end
        local f = PURE[path]
        if not f then return end
        if path == "table.concat" then
            local t = args[1]
            if not t or t.k ~= "table" then return end
            local arr = {}
            for _, it in ipairs(t.items) do
                if it.kind ~= "pos" or not (it.v.k == "str" or it.v.k == "num") then return end
                arr[#arr + 1] = it.v.v
            end
            local sep = args[2]
            if sep and sep.k ~= "str" then return end
            local ok, r = pcall(f, arr, sep and sep.v)
            if ok and type(r) == "string" and #r <= 4000 then return r, true end
            return
        end
        local vals = { n = #args }
        for i, a in ipairs(args) do
            if not islit(a) then return end
            vals[i] = litval(a)
        end
        if path == "string.rep" then
            local s, n = vals[1], vals[2]
            if type(s) ~= "string" or type(n) ~= "number" or #s * n > 4096 then return end
        end
        local res = U.pack(pcall(f, U.unpack(vals, 1, vals.n)))
        if not res[1] or res.n ~= 2 then return end
        local r = res[2]
        if type(r) == "string" then if #r > 4000 then return end
        elseif type(r) == "number" then if not finite(r) then return end
        elseif type(r) ~= "boolean" then return end
        return r, true
    end

    local simp
    function simp(e)
        local k = e.k
        if k == "paren" then
            local inner = simp(e.e)
            if islit(inner) then return inner end
            if inner.k == "call" or inner.k == "method" or inner.k == "vararg" then return { k = "paren", e = inner } end
            return inner
        elseif k == "name" then
            local d = e.decl
            if d and d.inlined then return d.inlined end
            return e
        elseif k == "bin" then
            local a, b = simp(e.a), simp(e.b)
            local op = e.op
            if FOLD then
                if op == "and" then
                    if islit(a) then STATS.folded = STATS.folded + 1; if truthy(a) then return b else return a end end
                elseif op == "or" then
                    if islit(a) then STATS.folded = STATS.folded + 1; if truthy(a) then return a else return b end end
                elseif islit(a) and islit(b) then
                    local v, ok = evalbin(op, litval(a), litval(b))
                    if ok then STATS.folded = STATS.folded + 1; return mklit(v) end
                end
            end
            return { k = "bin", op = op, a = a, b = b }
        elseif k == "un" then
            local a = simp(e.a)
            if FOLD and islit(a) then
                if e.op == "not" then STATS.folded = STATS.folded + 1; return mklit(not truthy(a))
                elseif e.op == "-" and a.k == "num" then return mklit(-a.v)
                elseif e.op == "#" and a.k == "str" then STATS.folded = STATS.folded + 1; return mklit(#a.v) end
            end
            return { k = "un", op = e.op, a = a }
        elseif k == "call" or k == "method" then
            if FOLD and k == "call" and e.fold and e.fold.ok then
                STATS.folded = STATS.folded + 1
                STATS.decoded = (STATS.decoded or 0) + 1
                return mklit(e.fold.val)
            end
            local args = {}
            for i, a in ipairs(e.args) do args[i] = simp(a) end
            local node
            if k == "call" then node = { k = "call", fn = simp(e.fn), args = args, line = e.line }
            else node = { k = "method", obj = simp(e.obj), name = e.name, args = args, line = e.line } end
            if FOLD then
                local v, ok = try_pure(node)
                if ok then STATS.folded = STATS.folded + 1; return mklit(v) end
            end
            return node
        elseif k == "index" then
            if FOLD and e.obj.k == "name" and e.obj.decl and e.obj.decl.constarr then
                local d = e.obj.decl
                if e.fold and e.fold.ok then
                    STATS.folded = STATS.folded + 1
                    STATS.decoded = (STATS.decoded or 0) + 1
                    return mklit(e.fold.val)
                end
                if e.key.k == "num" and not d.tablewrite and not d.escaped then
                    local it = d.init.items[e.key.v]
                    if it then STATS.folded = STATS.folded + 1; return mklit(it.v.v) end
                end
            end
            return { k = "index", obj = simp(e.obj), key = simp(e.key), line = e.line }
        elseif k == "table" then
            local items = {}
            for i, it in ipairs(e.items) do
                if it.kind == "kv" then items[i] = { kind = "kv", key = simp(it.key), v = simp(it.v) }
                else items[i] = { kind = "pos", v = simp(it.v) } end
            end
            return { k = "table", items = items }
        elseif k == "ifexpr" then
            local conds, vals = {}, {}
            for i = 1, #e.conds do
                local c = simp(e.conds[i])
                if FOLD and islit(c) then
                    STATS.folded = STATS.folded + 1
                    if truthy(c) then
                        if #conds == 0 then return simp(e.vals[i]) end
                        return { k = "ifexpr", conds = conds, vals = vals, els = simp(e.vals[i]) }
                    end
                else
                    conds[#conds + 1] = c; vals[#vals + 1] = simp(e.vals[i])
                end
            end
            if #conds == 0 then return simp(e.els) end
            return { k = "ifexpr", conds = conds, vals = vals, els = simp(e.els) }
        end
        return e
    end

    -- ============================================================ naming
    local function is_clean(n)
        if #n < 3 then return false end
        if not n:find("[aeiouAEIOU]") then return false end
        if n:find("%d%d") then return false end
        if n:find("^[Il]+$") or n:find("[Il][Il][Il][Il]") then return false end
        if n:find("^_") and n:find("%x%x%x%x") then return false end
        if n:find("[Oo0][Oo0][Oo0][Oo0]") then return false end
        return true
    end

    local function sanitize(s)
        s = tostring(s):gsub("[^%w_]", "")
        if s == "" then return nil end
        if s:find("^%d") then s = "_" .. s end
        s = s:sub(1, 1):lower() .. s:sub(2)
        if KW[s] then s = s .. "_" end
        return s
    end

    local function hinted(e)
        if not e then return nil end
        if e.k == "paren" then e = e.e end
        local k = e.k
        if k == "call" then
            local p = path_raw(e.fn)
            if p == "require" then return "module" end
            if p == "loadstring" or p == "load" then return "chunk" end
            if p == "Instance.new" and e.args[1] and e.args[1].k == "str" then return sanitize(e.args[1].v) end
            if p == "getgenv" or p == "getfenv" then return "genv" end
            if p == "tick" or p == "os.time" or p == "os.clock" then return "now" end
            if p and p:find("^Vector[23]%.") then return "vec" end
            if p and p:find("^Color3%.") then return "color" end
            if p and p:find("^CFrame%.") then return "cframe" end
            if p == "setmetatable" then return "obj" end
            if p == "pcall" or p == "xpcall" then return "ok" end
        elseif k == "method" then
            local n, a = e.name, e.args[1]
            if (n == "GetService" or n == "FindFirstChild" or n == "WaitForChild" or n == "FindFirstChildOfClass"
                or n == "FindFirstChildWhichIsA") and a and a.k == "str" then return sanitize(a.v) end
            if n == "HttpGet" or n == "HttpGetAsync" then return "source" end
            if n == "JSONDecode" then return "data" elseif n == "JSONEncode" then return "json" end
            if n == "Clone" then return "clone" elseif n == "Connect" then return "conn" end
            if n == "GetChildren" then return "children" elseif n == "GetPlayers" then return "players" end
        elseif k == "table" then return "tbl"
        elseif k == "str" then
            local s = e.v
            if s:find("^https?://") then return s:find("webhook") and "webhook" or "url" end
            return "str"
        elseif k == "num" then return "num"
        elseif k == "func" then return "fn"
        elseif k == "index" and e.key.k == "str" and is_clean(e.key.v) then return sanitize(e.key.v)
        elseif k == "bin" and e.op == ".." then return "str"
        elseif k == "name" and e.decl == nil and is_clean(e.v) then return sanitize(e.v)
        end
        return nil
    end

    local LOOPNAMES = { "i", "j", "k", "l", "m", "n" }
    local function generic(kind)
        if kind == "param" then counters.arg = counters.arg + 1; return "arg" .. counters.arg
        elseif kind == "func" then counters.fn = counters.fn + 1; return "fn" .. counters.fn
        elseif kind == "loop" then
            counters.loop = counters.loop + 1
            local n = counters.loop
            if n <= #LOOPNAMES then return LOOPNAMES[n] end
            return "idx" .. n
        end
        counters.var = counters.var + 1
        return "var" .. counters.var
    end

    local function uniq(nm)
        local base, i = nm, 1
        while used[nm] do i = i + 1; nm = base .. i end
        used[nm] = true
        return nm
    end

    local function declname(d, hint)
        if d.new then return d.new end
        local nm
        if (not RENAME) or is_clean(d.orig) then nm = d.orig
        else
            local h = (type(hint) == "string") and hint or hinted(hint)
            nm = uniq(h or generic(d.kind))
            STATS.renamed = STATS.renamed + 1
        end
        d.new = nm
        return nm
    end

    -- ============================================================ printing
    local PP = { ["or"] = 1, ["and"] = 2, ["<"] = 3, [">"] = 3, ["<="] = 3, [">="] = 3, ["~="] = 3, ["=="] = 3,
        [".."] = 4, ["+"] = 5, ["-"] = 5, ["*"] = 6, ["/"] = 6, ["//"] = 6, ["%"] = 6, ["^"] = 8 }
    local RASSOC = { [".."] = true, ["^"] = true }

    local function strlit(s)
        local o = {}
        for i = 1, #s do
            local c = s:sub(i, i)
            local b = c:byte()
            if c == "\\" then o[#o + 1] = "\\\\"
            elseif c == '"' then o[#o + 1] = '\\"'
            elseif c == "\n" then o[#o + 1] = "\\n"
            elseif c == "\r" then o[#o + 1] = "\\r"
            elseif c == "\t" then o[#o + 1] = "\\t"
            elseif b < 32 or b > 126 then
                if s:sub(i + 1, i + 1):find("%d") then o[#o + 1] = ("\\%03d"):format(b) else o[#o + 1] = ("\\%d"):format(b) end
            else o[#o + 1] = c end
        end
        return '"' .. table.concat(o) .. '"'
    end

    local function numstr(v)
        if v ~= v then return "(0/0)" end
        if v == math.huge then return "math.huge" elseif v == -math.huge then return "-math.huge" end
        if v == floor(v) and math.abs(v) < 1e15 then return ("%d"):format(v) end
        return ("%.14g"):format(v)
    end

    local function emit(s) buf[#buf + 1] = string.rep("    ", ind) .. s end
    local pe, stmts, stmt

    local function binprec(n)
        if n.k == "bin" then return PP[n.op]
        elseif n.k == "un" or (n.k == "num" and n.v < 0) then return 7
        elseif n.k == "ifexpr" then return 0 end
        return 100
    end

    local function pfx(e)
        local s = pe(e)
        local k = e.k
        if k == "name" or k == "index" or k == "call" or k == "method" or k == "paren" then return s end
        return "(" .. s .. ")"
    end

    local function args_str(args)
        local t = {}
        for i, a in ipairs(args) do t[i] = pe(a) end
        return table.concat(t, ", ")
    end

    local function params_of(e, skipself)
        local ps = {}
        for i, pn in ipairs(e.params) do
            if not (skipself and i == 1) then ps[#ps + 1] = declname(e.pdecls[i], nil) end
        end
        if e.vararg then ps[#ps + 1] = "..." end
        return table.concat(ps, ", ")
    end

    local function body_text(e)
        local saved = buf
        buf = {}
        ind = ind + 1
        stmts(e.body)
        ind = ind - 1
        local s = table.concat(buf, "\n")
        buf = saved
        return s
    end

    function pe(e)
        local k = e.k
        if k == "nil" then return "nil"
        elseif k == "true" then return "true"
        elseif k == "false" then return "false"
        elseif k == "num" then return numstr(e.v)
        elseif k == "str" then return strlit(e.v)
        elseif k == "vararg" then return "..."
        elseif k == "name" then
            local d = e.decl
            if d and d.new then return d.new end
            return e.v
        elseif k == "paren" then return "(" .. pe(e.e) .. ")"
        elseif k == "index" then
            local o = pfx(e.obj)
            if e.key.k == "str" and ident(e.key.v) then return o .. "." .. e.key.v end
            return o .. "[" .. pe(e.key) .. "]"
        elseif k == "call" then return pfx(e.fn) .. "(" .. args_str(e.args) .. ")"
        elseif k == "method" then return pfx(e.obj) .. ":" .. e.name .. "(" .. args_str(e.args) .. ")"
        elseif k == "func" then
            local ps = params_of(e, false)
            local body = body_text(e)
            if body == "" then return "function(" .. ps .. ") end" end
            return "function(" .. ps .. ")\n" .. body .. "\n" .. string.rep("    ", ind) .. "end"
        elseif k == "un" then
            local s = pe(e.a)
            if binprec(e.a) < 7 then s = "(" .. s .. ")" end
            if e.op == "not" then return "not " .. s end
            if e.op == "-" and s:sub(1, 1) == "-" then s = "(" .. s .. ")" end
            return e.op .. s
        elseif k == "bin" then
            local op = e.op
            local p, ra = PP[op], RASSOC[op]
            local ls, rs = pe(e.a), pe(e.b)
            local lp, rp = binprec(e.a), binprec(e.b)
            local concat = (op == "..")
            if lp < p or (lp == p and ra and not concat) then ls = "(" .. ls .. ")" end
            if rp < p or (rp == p and not ra and not concat) then rs = "(" .. rs .. ")" end
            return ls .. " " .. op .. " " .. rs
        elseif k == "ifexpr" then
            local s = "if " .. pe(e.conds[1]) .. " then " .. pe(e.vals[1])
            for i = 2, #e.conds do s = s .. " elseif " .. pe(e.conds[i]) .. " then " .. pe(e.vals[i]) end
            return s .. " else " .. pe(e.els)
        elseif k == "table" then
            if #e.items == 0 then return "{}" end
            local parts = {}
            ind = ind + 1
            for i, it in ipairs(e.items) do
                if it.kind == "pos" then parts[i] = pe(it.v)
                elseif it.key.k == "str" and ident(it.key.v) then parts[i] = it.key.v .. " = " .. pe(it.v)
                else parts[i] = "[" .. pe(it.key) .. "] = " .. pe(it.v) end
            end
            ind = ind - 1
            local one = table.concat(parts, ", ")
            if #one <= 80 and not one:find("\n") then return "{" .. one .. "}" end
            local pad = string.rep("    ", ind + 1)
            return "{\n" .. pad .. table.concat(parts, ",\n" .. pad) .. "\n" .. string.rep("    ", ind) .. "}"
        end
        return "--[[?" .. tostring(k) .. "]]"
    end

    local function px(e) return pe(simp(e)) end

    local function emit_func(prefix, f, skipself)
        local ps = params_of(f, skipself)
        local body = body_text(f)
        if body == "" then emit(prefix .. "(" .. ps .. ") end")
        else
            emit(prefix .. "(" .. ps .. ")")
            buf[#buf + 1] = body
            emit("end")
        end
    end

    local function block(list)
        ind = ind + 1; stmts(list); ind = ind - 1
    end
    local function has_local(list)
        for _, s in ipairs(list) do if s.k == "local" or s.k == "localfunc" then return true end end
        return false
    end

    function stmts(list) for _, s in ipairs(list) do stmt(s) end end

    function stmt(s)
        local k = s.k
        if k == "local" then
            local exprs = {}
            for i, e in ipairs(s.exprs) do exprs[i] = simp(e) end
            if INLINE and #s.names == 1 and #exprs == 1 then
                local d, e = s.decls[1], exprs[1]
                if d.assigns == 0 and islit(e) and (e.k ~= "str" or #e.v <= 120) then
                    d.inlined = e
                    STATS.inlined = STATS.inlined + 1
                    return
                end
            end
            local names, strs = {}, {}
            for i, nm in ipairs(s.names) do
                local e = s.exprs[i]
                names[i] = declname(s.decls[i], e)
            end
            for i, e in ipairs(exprs) do strs[i] = pe(e) end
            emit("local " .. table.concat(names, ", ") .. (#strs > 0 and (" = " .. table.concat(strs, ", ")) or ""))
        elseif k == "localfunc" then
            local nm = declname(s.decl, s.func)
            emit_func("local function " .. nm, s.func, false)
        elseif k == "assign" then
            if s.fstat then
                local f, t = s.exprs[1], s.targets[1]
                local ts
                if t.k == "name" then ts = pe(simp(t))
                else ts = pe(simp(t.obj)) .. (f.method and ":" or ".") .. t.key.v end
                emit_func("function " .. ts, f, f.method)
                return
            end
            local ts, es = {}, {}
            for i, t in ipairs(s.targets) do ts[i] = px(t) end
            for i, e in ipairs(s.exprs) do es[i] = px(e) end
            emit(table.concat(ts, ", ") .. " = " .. table.concat(es, ", "))
        elseif k == "callstat" then
            emit(px(s.e))
        elseif k == "do" then
            emit("do"); block(s.body); emit("end")
        elseif k == "while" then
            local c = simp(s.cond)
            if DEAD and islit(c) and not truthy(c) then STATS.dead = STATS.dead + 1; return end
            emit("while " .. pe(c) .. " do"); block(s.body); emit("end")
        elseif k == "repeat" then
            emit("repeat"); block(s.body)
            emit("until " .. px(s.cond))
        elseif k == "if" then
            local list, has_else = {}, false
            for i, c in ipairs(s.conds) do
                local cs = simp(c)
                if DEAD and islit(cs) then
                    STATS.dead = STATS.dead + 1
                    if truthy(cs) then list[#list + 1] = { nil, s.blocks[i] }; has_else = true; break end
                else
                    list[#list + 1] = { cs, s.blocks[i] }
                end
            end
            if not has_else and s.els then list[#list + 1] = { nil, s.els } end
            if #list == 0 then return end
            if list[1][1] == nil then
                local b = list[1][2]
                if has_local(b) then emit("do"); block(b); emit("end") else stmts(b) end
                return
            end
            for i, it in ipairs(list) do
                if it[1] then emit((i == 1 and "if " or "elseif ") .. pe(it[1]) .. " then")
                else emit("else") end
                block(it[2])
            end
            emit("end")
        elseif k == "fornum" then
            local a, b = px(s.a), px(s.b)
            local c = s.c and px(s.c)
            local nm = declname(s.vdecl, nil)
            emit("for " .. nm .. " = " .. a .. ", " .. b .. (c and (", " .. c) or "") .. " do")
            block(s.body); emit("end")
        elseif k == "forin" then
            local es = {}
            for i, e in ipairs(s.exprs) do es[i] = px(e) end
            local e1 = s.exprs[1]
            local p1 = e1 and e1.k == "call" and path_raw(e1.fn)
            local names = {}
            for i, d in ipairs(s.vdecls) do
                local h
                if i == 1 then h = (p1 == "ipairs") and "i" or "k" elseif i == 2 then h = "v" end
                names[i] = declname(d, h)
            end
            emit("for " .. table.concat(names, ", ") .. " in " .. table.concat(es, ", ") .. " do")
            block(s.body); emit("end")
        elseif k == "return" then
            local es = {}
            for i, e in ipairs(s.exprs) do es[i] = px(e) end
            emit("return" .. (#es > 0 and (" " .. table.concat(es, ", ")) or ""))
        elseif k == "break" then emit("break")
        elseif k == "continue" then emit("continue")
        end
    end

    -- ============================================================ public: clean(ast)
    function G.clean(ast, label)
        STATS = { folded = 0, renamed = 0, dead = 0, inlined = 0, decoded = 0 }
        FOLD, INLINE, DEAD, RENAME = C.CLEAN_FOLD, C.CLEAN_INLINE, C.CLEAN_DEAD, C.CLEAN_RENAME
        local st = { decls = {}, globals = {} }
        analyze_ast(ast, st)
        used, counters = {}, { var = 0, arg = 0, fn = 0, loop = 0 }
        for _, d in ipairs(st.decls) do if is_clean(d.orig) then used[d.orig] = true end end
        for g in pairs(st.globals) do used[g] = true end
        buf, ind = {}, 0
        local ok, err = pcall(stmts, ast.body)
        local body = table.concat(buf, "\n")
        if not ok then body = body .. "\n-- (printer stopped: " .. tostring(err) .. ")" end
        local stats = STATS
        local head = ("-- BlackSpider cleaned %s | %d folded (%d decoded at runtime), %d renamed, %d inlined, %d dead branches")
            :format(label or "chunk", stats.folded, stats.decoded, stats.renamed, stats.inlined, stats.dead)
        return head .. "\n" .. body, stats
    end

    -- ============================================================ public: decoded()
    function G.decoded(asts)
        local out, seenval, seen = {}, {}, {}
        local stack = {}
        for _, a in ipairs(asts) do stack[#stack + 1] = a end
        local skip = { decl = true, decls = true, pdecls = true, vdecl = true, vdecls = true }
        while #stack > 0 do
            local n = table.remove(stack)
            if type(n) == "table" and not seen[n] then
                seen[n] = true
                if n.fold and n.fold.ok and n.fold.val then
                    local key = tostring(n.line) .. ":" .. n.fold.val
                    if not seenval[key] then
                        seenval[key] = true
                        out[#out + 1] = { line = n.line or 0, val = n.fold.val }
                    end
                end
                for k, v in pairs(n) do
                    if type(v) == "table" and not skip[k] then stack[#stack + 1] = v end
                end
            end
        end
        table.sort(out, function(a, b) if a.line ~= b.line then return a.line < b.line end return a.val < b.val end)
        return out
    end

    -- ============================================================ public: trace()
    function G.trace()
        local B = R.behavior
        if #B == 0 then return "-- (no calls to the environment were observed)" end
        local refs = {}
        for _, b in ipairs(B) do
            for id in b.text:gmatch("%f[%w_]r(%d+)%f[^%w_]") do refs[id] = (refs[id] or 0) + 1 end
        end
        local names, taken = {}, {}
        local function uniqn(nm)
            local base, i = nm, 1
            while taken[nm] do i = i + 1; nm = base .. i end
            taken[nm] = true
            return nm
        end
        local function nice(def)
            local inst = def:match('^Instance%.new%("([%w_]+)"')
            local nm
            if inst then nm = inst:sub(1, 1):lower() .. inst:sub(2)
            else
                nm = def:match('FindFirstChild%("([%w_]+)"') or def:match('WaitForChild%("([%w_]+)"')
                    or def:match('FindFirstChildOfClass%("([%w_]+)"')
                if nm then nm = nm:sub(1, 1):lower() .. nm:sub(2)
                else
                    local m = def:match("^[^%(]*[:%.]([%a_][%w_]*)%(")
                    if m then
                        m = m:gsub("^Get", ""):gsub("^Find", ""):gsub("^Create", "")
                        nm = (m ~= "" and (m:sub(1, 1):lower() .. m:sub(2))) or "obj"
                    else nm = "obj" end
                end
            end
            if KW[nm] then nm = nm .. "_" end
            return nm
        end
        for _, b in ipairs(B) do
            if b.def and refs[tostring(b.def)] then names[tostring(b.def)] = uniqn(nice(b.text)) end
        end

        local services, svc_order = {}, {}
        local function render(b)
            local t = b.text
            local only = t:match('^game:GetService%("([%w_]+)"%)$')
            if only then   -- bare service lookup: the header already declares it
                if not services[only] then services[only] = true; svc_order[#svc_order + 1] = only end
                return nil
            end
            t = (t:gsub('game:GetService%("([%w_]+)"%)', function(n)
                if not services[n] then services[n] = true; svc_order[#svc_order + 1] = n end
                return n
            end))
            t = (t:gsub("%f[%w_]r(%d+)%f[^%w_]", function(n) return names[n] or ("r" .. n) end))
            if b.def and names[tostring(b.def)] then t = "local " .. names[tostring(b.def)] .. " = " .. t end
            return t
        end

        local main, groups, gorder = {}, {}, {}
        for _, b in ipairs(B) do
            local line = render(b)
            if not line then
                -- skipped (service alias)
            elseif b.ev then
                if not groups[b.ev] then groups[b.ev] = {}; gorder[#gorder + 1] = b.ev end
                table.insert(groups[b.ev], "    " .. line)
            else
                main[#main + 1] = line
            end
        end
        local o = {}
        for _, n in ipairs(svc_order) do o[#o + 1] = ('local %s = game:GetService("%s")'):format(n, n) end
        if #svc_order > 0 then o[#o + 1] = "" end
        for _, l in ipairs(main) do o[#o + 1] = l end
        for _, ev in ipairs(gorder) do
            o[#o + 1] = ""
            o[#o + 1] = "-- callback " .. ev .. "  (fired by the emulator)"
            o[#o + 1] = "do"
            for _, l in ipairs(groups[ev]) do o[#o + 1] = l end
            o[#o + 1] = "end"
        end
        return table.concat(o, "\n")
    end

    return G
end
