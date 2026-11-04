-- BlackSpider :: spider.lua  --  crawl mode.
-- While a script runs, every GET it does (game:HttpGet, request{Method="GET"}) passes through
-- spider.gate(). If allowed, the url is downloaded with the executor's request() (fetcher.lua),
-- the real content is handed back to the script (so loadstring(game:HttpGet(..))() keeps going)
-- and, with SPIDER = true, the downloaded script is queued and analysed on its own.
-- Only GET, only http(s), never private/loopback hosts, never discord webhooks, no headers forwarded.
return function(BS)
    local U, C = BS.util, BS.config
    local M = { pages = {}, queue = {}, qi = 1, cache = {}, by_hash = {}, fetches = 0, cur_depth = 0, cur_page = 0 }

    function M.reset()
        M.pages, M.queue, M.qi, M.cache, M.by_hash, M.fetches = {}, {}, 1, {}, {}, 0
        M.cur_depth, M.cur_page = 0, 0
    end

    local function private_ip(a, b)
        return a == 0 or a == 10 or a == 127 or a >= 224 or (a == 169 and b == 254)
            or (a == 192 and b == 168) or (a == 172 and b >= 16 and b <= 31) or (a == 100 and b >= 64 and b <= 127)
    end

    local function suffix_match(host, d)
        d = d:lower()
        return host == d or (#host > #d and host:sub(-(#d + 1)) == "." .. d)
    end

    function M.url_ok(url)
        url = tostring(url)
        if #url > 2000 or url:find("[%c%s]") then return false, "bad url" end
        local scheme, rest = url:match("^(https?)://(.+)$")
        if not scheme then return false, "not http(s)" end
        local hostport = rest:match("^([^/%?#]+)")
        if not hostport then return false, "no host" end
        local host = (hostport:gsub("^.*@", ""):gsub(":%d+$", "")):lower()
        if host == "" or host:find("^%[") then return false, "ipv6/empty host" end
        if host == "localhost" or host:find("%.local$") or host:find("%.internal$") or host:find("%.lan$") then
            return false, "private host"
        end
        if host:find("^%d+$") or host:find("^0x") then return false, "obfuscated ip" end
        local a, b = host:match("^(%d+)%.(%d+)%.%d+%.%d+$")
        if a and private_ip(tonumber(a), tonumber(b)) then return false, "private ip" end
        if url:find("/api/webhooks/", 1, true) then return false, "webhook" end
        for _, d in ipairs(C.SPIDER_DENY or {}) do
            if suffix_match(host, d) then return false, "denied domain " .. d end
        end
        local allow = C.SPIDER_ALLOW or {}
        if #allow > 0 then
            local ok = false
            for _, d in ipairs(allow) do if suffix_match(host, d) then ok = true; break end end
            if not ok then return false, "not in allow-list" end
        end
        return true
    end

    -- called by the net guard for every GET. returns content | nil, reason
    function M.gate(url, src)
        local max_pages = C.SPIDER and C.SPIDER_MAX_PAGES or (C.FOLLOW_LOADER and 1 or 0)
        local max_depth = C.SPIDER and C.SPIDER_MAX_DEPTH or 1
        if max_pages <= 0 then return nil, "fetching disabled" end
        if not BS.fetcher.available() then return nil, "no http function on host" end
        local ok, why = M.url_ok(url)
        if not ok then return nil, why end

        local cached = M.cache[url]
        if cached == nil then
            if M.cur_depth + 1 > max_depth then return nil, "max depth " .. max_depth end
            if M.fetches >= max_pages then return nil, "page budget " .. max_pages end
            M.fetches = M.fetches + 1
            print(("[SPIDER] GET %s  (from %s, depth %d)"):format(U.short(url, 140), src, M.cur_depth + 1))
            local body, err = BS.fetcher.get(url)
            if not body then
                M.cache[url] = false
                print("[SPIDER]   failed: " .. tostring(err))
                return nil, "fetch failed: " .. tostring(err)
            end
            if #body > C.SPIDER_MAX_BYTES then M.cache[url] = false; return nil, "too large" end
            M.cache[url] = body
            cached = body
            print(("[SPIDER]   ok, %d bytes"):format(#body))
            if C.SPIDER then
                local h = U.hash(body)
                if not M.by_hash[h] then
                    local pg = { id = #M.pages, url = url, depth = M.cur_depth + 1, parent = M.cur_page, body = body }
                    pg.prefix = "p" .. pg.id .. "_"
                    M.by_hash[h] = pg
                    M.pages[#M.pages + 1] = pg
                    M.queue[#M.queue + 1] = pg
                end
            end
        end
        if cached == false then return nil, "previously failed" end
        return cached
    end

    -- analyse the root, then every page the crawl discovered (breadth first)
    function M.crawl(code, rootmeta)
        M.reset()
        local root = { id = 0, url = rootmeta.url or "(inline)", depth = 0, parent = nil, body = code, prefix = "p0_" }
        M.pages[#M.pages + 1] = root   -- pages[1] is the root; ids of children start at 1 as well (see below)
        -- ids: root = 0, children = 1.. in discovery order. pages list index = id + 1.
        local function run(pg)
            M.cur_depth, M.cur_page = pg.depth, pg.id
            U.writef(U.outpath(pg.prefix .. "raw.lua"), pg.body)
            pg.result = BS.main.analyze(pg.body, pg)
        end
        run(root)
        while M.qi <= #M.queue do
            local pg = M.queue[M.qi]; M.qi = M.qi + 1
            if C.SPIDER then
                print(("[SPIDER] ---- analysing page %d (depth %d): %s"):format(pg.id, pg.depth, U.short(pg.url, 120)))
                run(pg)
            end
        end
        M.write_index()
    end

    function M.write_index()
        local lines = { "BlackSpider crawl index", ("pages: %d | fetches: %d"):format(#M.pages, M.fetches), "" }
        local children = {}
        for _, pg in ipairs(M.pages) do
            local par = pg.parent
            if par ~= nil then children[par] = children[par] or {}; table.insert(children[par], pg) end
        end
        local function node(pg, ind)
            local r = pg.result or {}
            lines[#lines + 1] = ("%s[%d] %s  (%d bytes, depth %d)"):format(ind, pg.id, pg.url, #pg.body, pg.depth)
            lines[#lines + 1] = ("%s     status: %s | requests: %d (fetched %d) | webhooks: %d | layers: %d | files: %sreport.txt")
                :format(ind, r.status or "not analysed", r.requests or 0, r.fetched or 0, r.webhooks or 0, r.layers or 0, pg.prefix)
            if r.verdict then lines[#lines + 1] = ind .. "     verdict: " .. r.verdict end
            for _, ch in ipairs(children[pg.id] or {}) do node(ch, ind .. "    ") end
        end
        node(M.pages[1], "")
        local txt = table.concat(lines, "\n")
        U.writef(U.outpath("index.txt"), txt)
        print("\n" .. txt)
    end

    return M
end
