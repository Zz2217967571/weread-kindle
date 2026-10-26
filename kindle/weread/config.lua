-- App 的目录位置。
local Config = {}

function Config.appDir()
    return os.getenv("WEREAD_DIR") or "/mnt/us/weread"
end

function Config.cacheDir()
    local dir = Config.appDir() .. "/cache"
    local lfs = require("libs/libkoreader-lfs")
    if lfs.attributes(dir, "mode") ~= "directory" then lfs.mkdir(dir) end
    return dir
end

return Config
