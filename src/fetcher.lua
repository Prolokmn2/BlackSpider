-- BlackSpider :: fetcher.lua  --  downloads text with the EXECUTOR's own http function
-- (same lookup order as your FileSaver script). The real functions are captured once, here, before
-- the net guard replaces the host's globals during a run, and are only reachable through F.get().
return function(BS)
    local U = BS.util
    local F = {}

    local function find_request_function()
        if type(request) == "function" then return request end
        if type(http_request) == "function" then return http_request end
        if type(http) == "table" and type(http.request) == "function" then return http.request end
        if type(syn) == "table" and type(syn.request) == "function" then return syn.request end
        if type(fluxus) == "table" and type(fluxus.request) == "function" then return fluxus.request end
        return nil
    end

    F.req = find_request_function()
    F.httpget = nil
    do
        local ok, g = pcall(function() return game end)
        if ok and g ~= nil then
            local ok2 = pcall(function() return game.HttpGet end)
            if ok2 then F.httpget = function(url) return game:HttpGet(url) end end
        end
    end

    function F.available() return F.req ~= nil or F.httpget ~= nil end

    -- GET only. No headers are sent, nothing from the analysed script is forwarded.
    -- returns body | nil, error
    function F.get(url)
        if F.req then
            local ok, resp = pcall(F.req, { Url = url, Method = "GET" })
            if not ok then return nil, tostring(resp) end
            if type(resp) ~= "table" then return nil, "bad response" end
            local status = resp.StatusCode or resp.status_code
            local body = resp.Body or resp.body
            if status and status ~= 200 then return nil, "HTTP " .. tostring(status) end
            if type(body) ~= "string" then return nil, "no body" end
            return body
        elseif F.httpget then
            local ok, body = pcall(F.httpget, url)
            if ok and type(body) == "string" then return body end
            return nil, tostring(body)
        end
        return nil, "no http function in this environment (run inside an executor)"
    end

    return F
end
