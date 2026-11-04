-- BlackSpider :: report.lua  --  verdict, summary and all output files of one analysed script
return function(BS)
    local U, C, ST, NET, EM, G = BS.util, BS.config, BS.state, BS.net, BS.emulator, BS.guesser
    local S, R = ST.S, ST.R
    local short = U.short
    local M = {}

    function M.write(meta, ok, runerr, elapsed)
        local P = S.prefix
        local status = ok and "COMPLETED" or ("STOPPED: " .. tostring(runerr))

        -- ---- finalise recorded data
        for _, e in ipairs(R.strings) do
            ST.scan_string(e.kind, e.text)
            if ST.keylike(e.text) and e.kind ~= "constant" then ST.add_key("KEY-LIKE-STRING", short(e.text, 100), e.kind .. " at step " .. e.step) end
        end
        do
            local xs = {}
            for val, cnt in pairs(R.xor_tally) do if cnt >= 8 then xs[#xs + 1] = { val, cnt } end end
            table.sort(xs, function(a, b) return a[2] > b[2] end)
            for i = 1, math.min(6, #xs) do ST.add_key("XOR-OPERAND", xs[i][1], ("used as xor operand %d times"):format(xs[i][2])) end
        end

        local webhooks, urls = {}, {}
        for _, u in ipairs(R.endpoint_order) do
            if R.endpoints[u].hook then webhooks[#webhooks + 1] = u else urls[#urls + 1] = u end
        end
        local exfil = false
        for _, r in ipairs(R.requests) do for _, f in ipairs(r.flags) do if f:find("EXFIL") or f:find("WEBHOOK") then exfil = true end end end

        local verdict
        if exfil then verdict = "LOGGER-LIKE. It sends data to a webhook/remote host."
        elseif NET.attempts > 0 then verdict = "makes outbound requests (see below). Check whether they are expected."
        elseif ok then verdict = "ran to the end without any outbound request in this fake environment."
        else verdict = "stopped early, the interesting part may not have run (see STOPPED + step log)." end

        local summary = {}
        local function Sx(s) summary[#summary + 1] = s end
        Sx("==================== BLACKSPIDER RESULT  [" .. (meta.url or "(inline)") .. "] ====================")
        Sx(("status : %s"):format(status))
        Sx(("steps  : %d statements in %.1fs | %d loadstring layers | %d requests blocked | %d fetched by spider | %d strings recovered")
            :format(S.steps, elapsed, #R.layers, NET.blocked, NET.fetched, #R.strings))
        if C.EMULATE then Sx(("emulator: %d callbacks queued, %d fired"):format(#EM.queue, EM.fired)) end
        Sx("VERDICT: " .. verdict)
        if #NET.tampers + #NET.escapes > 0 then
            Sx("NOTE: the script tried to tamper with the http hooks and/or probe for a sandbox escape (anti-analysis behaviour).")
        end

        Sx("\n---- NETWORK GUARD (every http/websocket vector is hooked) ----")
        Sx(("attempts: %d | blocked: %d | fetched by spider (GET only): %d"):format(NET.attempts, NET.blocked, NET.fetched))
        do
            local vn = {}
            for nm in pairs(NET.by_vector) do vn[#vn + 1] = nm end
            table.sort(vn, function(a, b) return NET.by_vector[a] > NET.by_vector[b] end)
            for _, nm in ipairs(vn) do Sx(("  %5d x %s"):format(NET.by_vector[nm], nm)) end
        end
        if NET.host_hits > 0 then Sx(("host request functions hit (and blocked): %d"):format(NET.host_hits)) end
        Sx("guard integrity: " .. (#NET.tampers == 0 and "INTACT, never touched" or ("INTACT (restored), %d tamper attempt(s) blocked"):format(#NET.tampers)))
        for i, t in ipairs(NET.tampers) do if i <= 20 then Sx(("  TAMPER  [step %d | line %d] %s"):format(t.step, t.line, t.msg)) end end
        Sx(("sandbox escape attempts blocked: %d"):format(#NET.escapes))
        for i, e in ipairs(NET.escapes) do if i <= 20 then Sx(("  ESCAPE  [step %d | line %d] %s"):format(e.step, e.line, short(e.what, 160))) end end

        Sx("\n---- RECOVERED: webhooks / urls ----")
        if #webhooks == 0 and #urls == 0 then Sx("(none found)") end
        for _, u in ipairs(webhooks) do Sx("WEBHOOK  " .. u .. "   <- " .. R.endpoints[u].how .. " @step " .. R.endpoints[u].step) end
        for i, u in ipairs(urls) do if i <= 25 then Sx("URL      " .. u .. "   <- " .. R.endpoints[u].how) end end

        Sx("\n---- RECOVERED: requests it tried to send ----")
        if #R.requests == 0 then Sx("(none)") end
        for i, r in ipairs(R.requests) do
            Sx(("#%d [%s] %s %s"):format(i, r.src, r.method, r.url))
            if #r.flags > 0 then Sx("    FLAGS: " .. table.concat(r.flags, " | ")) end
            Sx("    headers: " .. short(r.headers, 300))
            Sx("    body   : " .. short(r.body, 600))
        end

        Sx("\n---- RECOVERED: encryption key candidates ----")
        if #R.keycands == 0 then Sx("(none detected)") end
        for i, kc in ipairs(R.keycands) do if i <= 25 then Sx(("%-16s %s    (%s)"):format(kc.kind, short(kc.value, 100), kc.why)) end end

        Sx("\n---- RECOVERED: loadstring layers ----")
        if #R.layers == 0 then Sx("(none)") end
        for i, l in ipairs(R.layers) do
            Sx(("layer %d: %d bytes%s -> %slayer_%d.%s"):format(i, l.size, l.bytecode and " [bytecode]" or "", P, i, l.bytecode and "luac" or "lua"))
            if l.text then Sx("    " .. short(l.text, 200)) end
        end

        -- ---- the code guesser
        local asts, G_ = {}, { "-- BlackSpider GUESSED CODE for " .. (meta.url or "(inline)"), "" }
        local function clean(ast, label)
            local cok, txt = pcall(G.clean, ast, label)
            G_[#G_ + 1] = "-- ===== " .. label .. " ====="
            G_[#G_ + 1] = cok and txt or ("-- (cleaner failed: " .. tostring(txt) .. ")")
            G_[#G_ + 1] = ""
            asts[#asts + 1] = ast
        end
        if R.main_ast then clean(R.main_ast, "main chunk (static cleanup + runtime-decoded strings)") end
        for i, l in ipairs(R.layers) do
            if l.ast then clean(l.ast, ("loadstring layer %d (%d bytes)"):format(i, l.size))
            elseif l.text then
                G_[#G_ + 1] = ("-- ===== loadstring layer %d (%d bytes, could not be parsed, raw) ====="):format(i, l.size)
                G_[#G_ + 1] = l.text; G_[#G_ + 1] = ""
            end
        end
        G_[#G_ + 1] = "-- ===== reconstructed runtime behaviour (what the script did to the environment) ====="
        local tok, trace = pcall(G.trace)
        G_[#G_ + 1] = tok and trace or ("-- (trace failed: " .. tostring(trace) .. ")")
        G_[#G_ + 1] = ""
        local dok, dec = pcall(G.decoded, asts)
        G_[#G_ + 1] = "-- ===== strings decoded at runtime (line: value) ====="
        if dok then
            if #dec == 0 then G_[#G_ + 1] = "-- (none)" end
            for i, d in ipairs(dec) do if i <= 500 then G_[#G_ + 1] = ("-- line %d: %s"):format(d.line, short(d.val, 300)) end end
        end
        G_[#G_ + 1] = ""
        G_[#G_ + 1] = "-- ===== recovered string constants ====="
        for i, e in ipairs(R.strings) do
            if e.kind ~= "constant" and i <= 300 and e.len < 600 then
                G_[#G_ + 1] = ("-- [%s%s] %s"):format(e.kind, e.name and (" " .. e.name) or "", short(e.text, 300))
            end
        end
        local guessed_code = table.concat(G_, "\n")

        local O = { "BlackSpider: GUESSED OUTPUT (what this script would print / send / write)", "status: " .. status, "" }
        if #R.outputs == 0 then O[#O + 1] = "(nothing observable)" end
        for _, o in ipairs(R.outputs) do O[#O + 1] = ("[%s] %s"):format(o.kind, o.text) end
        local guessed_output = table.concat(O, "\n")

        Sx("\n---- GUESSED CODE (first 40 lines; full: " .. P .. "guessed_code.lua) ----")
        do
            local cnt = 0
            for l in (guessed_code .. "\n"):gmatch("(.-)\n") do
                if cnt >= 40 then Sx("..."); break end
                Sx(short(l, 220)); cnt = cnt + 1
            end
        end
        Sx("\n---- GUESSED OUTPUT (first 30 lines; full: " .. P .. "guessed_output.txt) ----")
        for i, o in ipairs(O) do if i <= 32 then Sx(short(o, 220)) end end

        -- ---- recovered + report files
        local RC = { "BlackSpider: RECOVERED", "" }
        RC[#RC + 1] = "=== WEBHOOKS / URLS ==="
        for _, u in ipairs(R.endpoint_order) do RC[#RC + 1] = (R.endpoints[u].hook and "WEBHOOK " or "URL     ") .. u .. "   <- " .. R.endpoints[u].how end
        RC[#RC + 1] = "\n=== KEY CANDIDATES ==="
        for _, kc in ipairs(R.keycands) do RC[#RC + 1] = ("%-16s %s   (%s)"):format(kc.kind, tostring(kc.value), kc.why) end
        RC[#RC + 1] = "\n=== REQUESTS ==="
        for i, r in ipairs(R.requests) do
            RC[#RC + 1] = ("#%d [%s] %s %s  %s"):format(i, r.src, r.method, r.url, table.concat(r.flags, " | "))
            RC[#RC + 1] = "   headers: " .. r.headers
            RC[#RC + 1] = "   body: " .. r.body
        end
        RC[#RC + 1] = "\n=== NET GUARD TAMPER / ESCAPE ATTEMPTS ==="
        for _, t in ipairs(NET.tampers) do RC[#RC + 1] = ("TAMPER [step %d line %d] %s"):format(t.step, t.line, t.msg) end
        for _, e in ipairs(NET.escapes) do RC[#RC + 1] = ("ESCAPE [step %d line %d] %s"):format(e.step, e.line, e.what) end
        RC[#RC + 1] = "\n=== VARIABLES holding strings (name = value) ==="
        for _, v in ipairs(R.vars) do RC[#RC + 1] = ("%s = %s"):format(v.name, short(v.value, 400)) end
        RC[#RC + 1] = "\n=== ALL RECOVERED STRINGS (in order of appearance) ==="
        for _, e in ipairs(R.strings) do
            RC[#RC + 1] = ("[step %d line %d %s%s] (%d bytes) %s"):format(e.step, e.line or 0, e.kind, e.name and (" " .. e.name) or "", e.len, short(e.text, 1200))
        end
        local recovered = table.concat(RC, "\n")

        local STL = { "\n=== CALL STATISTICS (native functions) ===" }
        local names = {}
        for nm in pairs(R.ccount) do names[#names + 1] = nm end
        table.sort(names, function(a, b) return R.ccount[a] > R.ccount[b] end)
        for i = 1, math.min(40, #names) do STL[#STL + 1] = ("%8d  %s"):format(R.ccount[names[i]], names[i]) end
        STL[#STL + 1] = "\n=== SCRIPT FUNCTION CALLS (count) ==="
        local fnames = {}
        for nm in pairs(R.fcount) do fnames[#fnames + 1] = nm end
        table.sort(fnames, function(a, b) return R.fcount[a] > R.fcount[b] end)
        for i = 1, math.min(40, #fnames) do STL[#STL + 1] = ("%8d  %s"):format(R.fcount[fnames[i]], fnames[i]) end
        STL[#STL + 1] = "\n=== STEP LOG (" .. #R.events .. " events) ==="
        for _, e in ipairs(R.events) do STL[#STL + 1] = e end

        U.writef(U.outpath(P .. "guessed_code.lua"), guessed_code)
        U.writef(U.outpath(P .. "guessed_output.txt"), guessed_output)
        U.writef(U.outpath(P .. "recovered.txt"), recovered)
        U.writef(U.outpath(P .. "report.txt"), table.concat(summary, "\n") .. "\n\n" .. recovered .. "\n" .. table.concat(STL, "\n"))

        Sx("\n---- saved to " .. C.OUT_DIR .. " ----")
        Sx(P .. "report.txt (everything), " .. P .. "guessed_code.lua, " .. P .. "guessed_output.txt, " .. P .. "recovered.txt, " .. P .. "layer_N.lua, " .. P .. "raw.lua")
        print(table.concat(summary, "\n"))

        return { status = status, requests = NET.attempts, fetched = NET.fetched, webhooks = #webhooks,
            layers = #R.layers, verdict = verdict }
    end

    return M
end
