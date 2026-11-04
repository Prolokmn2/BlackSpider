-- BlackSpider :: config.lua  --  defaults. Override any of these from your executor:
--
--   getgenv().BlackSpiderConfig = { TARGET_URL = "https://...", SPIDER = true }
--   loadstring(game:HttpGet("https://raw.githubusercontent.com/prolokmn2/BlackSpider/main/loader.lua"))()
--
return function(BS)
    local C = {
        -- ===================================================== INPUT
        -- priority: TARGET_CODE > TARGET_URL > TARGET_FILE
        TARGET_CODE  = "",                -- paste raw code, or a  loadstring(game:HttpGet("..."))()  line
        TARGET_URL   = "",                -- downloaded with the executor's request(), then analysed
        TARGET_FILE  = "obfuscated.lua",  -- file in the workspace folder
        RAW_FILENAME = "output.txt",      -- raw copy of the TARGET_URL download ("" = don't save)

        OUT_DIR = "BlackSpider_out",      -- every report/layer/page is written here

        -- ===================================================== SANDBOX LIMITS
        TIME_LIMIT  = 90,        -- CPU seconds per analysed script
        MAX_EVENTS  = 6000,
        MAX_STRINGS = 8000,
        MAX_WAITS   = 300,       -- task.wait() calls before a loop is broken
        ECHO_PRINT  = true,      -- show the analysed script's own print() in the console

        -- ===================================================== EMULATOR
        EMULATE        = true,   -- queue callbacks (:Connect, .OnClientEvent = f ...) and fire them afterwards
        EMULATE_ROUNDS = 3,      -- how many times per-frame events (Heartbeat...) fire

        -- ===================================================== NET GUARD
        NET_LOCK     = true,     -- refuse script attempts to overwrite/remove the http guards
        HOST_LOCK    = true,     -- neutralise the HOST's own request functions during a run (restored after)
        MAX_REQUESTS = 500,      -- stored request records (all attempts are still counted)

        -- ===================================================== SPIDER (crawl mode)
        -- When the analysed script does a GET (game:HttpGet / request GET), the spider downloads
        -- that url with the executor's request() and hands the real content back to the script,
        -- then analyses the downloaded script on its own (deobfuscated + report), and so on.
        -- Only GET is ever performed, no headers/body from the script are forwarded.
        SPIDER           = false,
        SPIDER_MAX_DEPTH = 3,
        SPIDER_MAX_PAGES = 25,
        SPIDER_MAX_BYTES = 3000000,
        SPIDER_ALLOW     = {},   -- if not empty: only these domains (and subdomains) may be fetched
        SPIDER_DENY      = {     -- never fetched
            "discord.com", "discordapp.com", "discord.gg",
            "iplogger.org", "grabify.link", "2no.co", "yip.su",
        },
        -- with SPIDER = false: still follow ONE get, so a pasted  loadstring(game:HttpGet(url))()  works
        FOLLOW_LOADER = true,

        -- ===================================================== CODE GUESSER (deobfuscator)
        CLEAN_FOLD   = true,     -- constant folding (string.char, "a".."b", math, bit32 ...)
        CLEAN_RENAME = true,     -- give obfuscated names readable ones
        CLEAN_INLINE = true,     -- inline single-assignment literal locals
        CLEAN_DEAD   = true,     -- drop branches whose condition is a constant
    }
    for k, v in pairs(BS.user_cfg or {}) do C[k] = v end

    -- fake identity + canaries: if one of these shows up in a request, the script is stealing it
    BS.FAKE = {
        executor = "Wave", exec_ver = "3.0.0",
        name   = "CanaryUser", userid = 1234567890,
        cookie = "_|WARNING:-DO-NOT-SHARE-THIS.CANARY_COOKIE_AAAA1111BBBB2222",
        hwid   = "CANARY-HWID-0000-1111-2222",
        ip     = "203.0.113.77",
    }
    return C
end
