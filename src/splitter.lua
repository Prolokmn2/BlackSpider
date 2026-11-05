-- BlackSpider :: splitter.lua  --  static "unwall" mode. Parses the script with BlackSpider's own parser
-- (no nesting limit) and prints it again: one statement per line, indented, long tables / argument
-- lists wrapped, hex / binary / underscored numbers as decimal, constant maths calculated.
-- Nothing is executed, so it is safe on any file and instant on huge Luraph one-liners.
return function(BS)
    local U, C, ST = BS.util, BS.config, BS.state
    local M = {}

    local function context(code, msg)
        local ln = tonumber(tostring(msg):match("line (%d+)"))
        if not ln then return "" end
        local i, cur = 1, 1
        while cur < ln do
            local j = code:find("\n", i, true)
            if not j then break end
            i, cur = j + 1, cur + 1
        end
        local j = code:find("\n", i, true) or (#code + 1)
        local l = code:sub(i, j - 1)
        return ("    line %d is %d chars long, begins: %s"):format(ln, #l, U.short(l, 120))
    end

    -- returns text | nil, err
    function M.split(code, label)
        ST.reset()
        local ok, ast = pcall(BS.parser.parse, code)
        if not ok then return nil, tostring(ast) end
        local cok, txt, stats = pcall(BS.guesser.clean, ast, label or "split")
        if not cok then return nil, "printer failed: " .. tostring(txt) end
        return txt, stats
    end

    function M.run(code)
        print(("[*] SPLITTER: %d bytes in, parsing (nothing is executed)..."):format(#code))
        local t0 = (os.clock or os.time)()
        local txt, stats = M.split(code, "split")
        if not txt then
            print("[-] splitter: " .. tostring(stats))
            local c = context(code, stats)
            if c ~= "" then print(c) end
            return false
        end
        local name = C.SPLIT_OUT ~= "" and C.SPLIT_OUT or "split.lua"
        U.writef(U.outpath(name), txt)
        local _, lines = txt:gsub("\n", "\n")
        print(("[+] splitter: %d bytes -> %d bytes, %d lines in %.2fs"):format(#code, #txt, lines + 1, (os.clock or os.time)() - t0))
        print(("    folded %d constants | dead branches removed %d | inlined %d | renamed %d"):format(
            stats.folded, stats.dead, stats.inlined, stats.renamed))
        print("[+] written to " .. U.outpath(name))
        return true
    end

    return M
end
