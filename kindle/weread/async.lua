-- 把会阻塞的活（联网、下载）放到子进程里做，主线程只轮询结果，界面不会卡住。
-- fn 在子进程里跑，返回值要能转成 JSON（table / 字符串 / 数字）；cb(result) 回到主线程调用，子进程失败时 result 为 nil。
-- 子进程里如果续了登录（Direct.refresh），会话写进了文件，所以结束后让主线程重新读一遍会话。
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local rapidjson = require("rapidjson")

local Async = {}

local seq = 0

function Async.run(fn, cb)
    seq = seq + 1
    local out = string.format("/tmp/weread-async-%d-%d.json", os.time(), seq)
    local pid = ffiutil.runInSubProcess(function()
        local ok, res = pcall(fn)
        local f = io.open(out, "wb")
        if f then
            f:write(rapidjson.encode({ ok = ok and res ~= nil, value = ok and res or nil }))
            f:close()
        end
    end)
    if not pid then
        if cb then cb(nil) end
        return
    end
    local function poll()
        if not ffiutil.isSubProcessDone(pid) then
            return UIManager:scheduleIn(0.1, poll)
        end
        local f = io.open(out, "rb")
        local data = f and f:read("*a")
        if f then f:close() end
        os.remove(out)
        require("weread/direct").reloadSession()
        local decoded = data and rapidjson.decode(data)
        if cb then cb(decoded and decoded.ok and decoded.value or nil) end
    end
    UIManager:scheduleIn(0.1, poll)
end

-- 先用上次存下的数据（立刻回调），再在子进程里取最新的，取到后再回调一次，同时存起来供下次用。
-- fn 返回 data, err, kind（和 Direct.* 一样）。cb(data, err, kind, from_cache)；
-- 取新数据失败而手上有缓存时不回调，界面继续用旧的；会话失效（kind == "relogin"）照常回调
function Async.swr(key, fn, cb)
    local path = require("weread/config").cacheDir() .. "/swr_" .. key .. ".json"
    local f = io.open(path, "rb")
    local cached = f and rapidjson.decode(f:read("*a"))
    if f then f:close() end
    if type(cached) ~= "table" then cached = nil end
    if cached then cb(cached, nil, nil, true) end
    Async.run(function()
        local data, err, kind = fn()
        return { data = data or false, err = err or false, kind = kind or false }
    end, function(res)
        if not res then
            if not cached then cb(nil, "网络连接失败，请确认 Kindle 已联网", nil, false) end
            return
        end
        if res.data then
            local out = io.open(path .. ".tmp", "wb")
            if out then
                out:write(rapidjson.encode(res.data))
                out:close()
                os.rename(path .. ".tmp", path)
            end
            cb(res.data, nil, nil, false)
        elseif res.kind == "relogin" or not cached then
            cb(nil, res.err or nil, res.kind or nil, false)
        end
    end)
end

return Async
