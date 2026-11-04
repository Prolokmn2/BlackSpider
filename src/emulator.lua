-- BlackSpider :: emulator.lua  --  callbacks the script registers are queued, then fired with
-- realistic arguments after the main chunk finished (so code hidden behind events still runs).
return function(BS)
    local U, C, ST = BS.util, BS.config, BS.state
    local S, R = ST.S, ST.R
    local log, short = ST.log, U.short
    local clock = os.clock or os.time

    local M = { fired = 0, ctx = {} }   -- ctx.ghost / ctx.player are filled by env.build()
    local queue, queued = {}, {}
    local poked, poke_n = {}, 0
    M.queue = queue

    function M.reset()
        U.clear(queue); U.clear(queued); U.clear(poked)
        poke_n, M.fired = 0, 0
        M.ctx.ghost, M.ctx.player = nil, nil
    end

    function M.poke(f, ev)
        if type(f) ~= "function" then return end
        local ghost = M.ctx.ghost
        if C.EMULATE then
            if queued[f] then return end
            queued[f] = true
            local l = tostring(ev or "callback"):lower()
            queue[#queue + 1] = { f = f, ev = tostring(ev or "callback"), runs = 0,
                periodic = (l:find("heartbeat") or l:find("stepped") or l:find("renderstepped")) and true or false }
            log("queue", "callback for " .. tostring(ev))
            return
        end
        -- legacy mode: poke once, immediately, with junk arguments
        if poked[f] or poke_n > 200 or not ghost then return end
        poked[f] = true; poke_n = poke_n + 1
        log("poke", "calling callback " .. tostring(f))
        pcall(f, ghost("arg1"), ghost("arg2"), ghost("arg3"))
    end

    local function emu_args(ev)
        local ghost = M.ctx.ghost
        local l = ev:lower()
        if l:find("characteradded") or l:find("characterremoving") then return ghost("Character") end
        if l:find("player") and (l:find("added") or l:find("removing")) then return M.ctx.player end
        if l:find("chatted") then return "hello" end
        if l:find("inputbegan") or l:find("inputended") then return ghost("InputObject"), false end
        if l:find("heartbeat") or l:find("stepped") then return 0.016 end
        return ghost("arg1"), ghost("arg2"), ghost("arg3")
    end

    function M.run()
        if not C.EMULATE then return end
        print(("[*] emulator: %d queued callbacks"):format(#queue))
        local stop = false
        for round = 1, C.EMULATE_ROUNDS do
            local i = 1
            while i <= #queue do          -- callbacks can queue more callbacks
                local q = queue[i]; i = i + 1
                local limit = q.periodic and C.EMULATE_ROUNDS or 1
                if q.runs < limit and q.runs < round then
                    if clock() > S.deadline then
                        log("emulate", "time limit reached, emulator stopped")
                        stop = true; break
                    end
                    q.runs = q.runs + 1
                    M.fired = M.fired + 1
                    S.waits = 0            -- reset task.wait budget per callback
                    S.ctx = q.ev           -- behaviour recorded now belongs to this callback
                    log("emulate", ("firing %s (round %d)"):format(q.ev, round))
                    local cok, cerr = pcall(q.f, emu_args(q.ev))
                    S.ctx = nil
                    if not cok then log("emulate-error", q.ev .. ": " .. short(cerr, 200)) end
                    BS.net.verify()
                end
            end
            if stop then break end
        end
    end

    return M
end
