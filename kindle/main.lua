#!./luajit
-- 微信读书 Kindle 版入口。由 weread.sh 在 KOReader 目录下用 KOReader 自带的 luajit 启动，
-- 复用 KOReader 的底层（屏幕、输入、字体、控件），界面全部是自己的。
io.stdout:setvbuf("line")
os.setlocale("C", "numeric")

local APP_DIR = os.getenv("WEREAD_DIR") or "/mnt/us/weread"
package.path = APP_DIR .. "/?.lua;" .. package.path

require("setupkoenv")

G_defaults = require("luadefaults"):open()
-- 用自己的设置文件，不碰 KOReader 的 settings.reader.lua
G_reader_settings = require("luasettings"):open(APP_DIR .. "/settings.lua")

local bb = require("ffi/blitbuffer")
bb:setUseCBB(true)
bb:enableCBB(true)

local Device = require("device")
local CanvasContext = require("document/canvascontext")
CanvasContext:init(Device)

local UIManager = require("ui/uimanager")
local App = require("weread/app")

App:start()
local exit_code = UIManager:run()

App.stop()
Device:exit()
os.exit(type(exit_code) == "number" and exit_code or 0, true)
