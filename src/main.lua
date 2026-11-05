-- BlackSpider :: main.lua  --  analyse one script (analyze) / choose the input and start the crawl (start)
return function(BS)
    local U, C, ST, NET, EM = BS.util, BS.config, BS.state, BS.net, BS.emulator
    local S, R = ST.S, ST.R
    local clock = os.clock or os.time
    local M = {}

    -- run ONE script in a fresh sandbox and write its report. meta = { id, url, depth, prefix }
    function M.analyze(code, meta)
        meta = meta or { id = 0, depth = 0, prefix = "p0_" }
        ST.reset(); NET.reset(); EM.reset()
        S.prefix = meta.prefix or "p0_"
        BS.env.build()

        print(("[*] analysing %s  (%d bytes)"):format(meta.url or "(inline)", #code))
        local t0 = clock()
        local main, ast = BS.compiler.load_interp(code, "main")
        if not main then
            print("[-] parse/compile error in target: " .. tostring(ast))
            print("    (unsupported syntax? Lua 5.1 + continue/+=/ // and Luau types are handled; goto is not.)")
            return { status = "PARSE ERROR: " .. tostring(ast), requests = 0, fetched = 0, webhooks = 0, layers = 0 }
        end
        R.main_ast = ast
        print(("[+] parsed + compiled in %.2fs. Executing, every step is monitored..."):format(clock() - t0))
        print("[+] NET GUARD active: every http/websocket vector is hooked, nothing leaves the sandbox except spider GETs.")

        NET.host_lock()
        local t1 = clock()
        local ok, runerr = pcall(main)
        NET.verify()
        local eok, eerr = pcall(EM.run)
        if not eok then ST.log("emulate-error", U.short(eerr, 200)) end
        NET.verify()
        NET.host_unlock()

        return BS.report.write(meta, ok, runerr, clock() - t1)
    end

    function M.start()
        U.ensure_dir()
        print("==================== BlackSpider ====================")
        local code, url
        if C.TARGET_CODE ~= "" then
            code = C.TARGET_CODE
            print("[*] input: inline code / loadstring line")
        elseif C.TARGET_URL ~= "" then
            url = C.TARGET_URL
            print("[*] input: downloading " .. url)
            local body, err = BS.fetcher.get(url)
            if not body then
                print("[-] download failed: " .. tostring(err))
                print("    (some scripts are executor-only: run BlackSpider inside your executor)")
                return
            end
            if body == "" then print("[-] the downloaded body is empty"); return end
            if C.RAW_FILENAME ~= "" then
                U.writef(C.RAW_FILENAME, body)
                print("[+] raw download saved to " .. C.RAW_FILENAME)
            end
            code = body
        else
            print("[*] input: file " .. C.TARGET_FILE)
            local ok, src = pcall(U.readf, C.TARGET_FILE)
            if not ok or type(src) ~= "string" then print("[-] cannot read " .. C.TARGET_FILE); return end
            code = src
        end
        if C.SPLITTER then
            BS.splitter.run(code)
            if not C.SPLIT_THEN_RUN then return end
        end
        print(("[*] spider: %s"):format(C.SPIDER and ("ON (depth %d, max %d pages)"):format(C.SPIDER_MAX_DEPTH, C.SPIDER_MAX_PAGES)
            or (C.FOLLOW_LOADER and "off (follows one loader GET)" or "off")))
        BS.spider.crawl(code, { url = url })
    end

    return M
end
