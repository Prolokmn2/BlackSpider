-- local test runner:  texlua tests/run.lua [target.lua] [spider]
local target = arg and arg[1] or "tests/sample1.lua"
BlackSpiderConfig = {
    SOURCE = "local", LOCAL_DIR = ".",
    TARGET_FILE = target, OUT_DIR = "tests/out",
    TIME_LIMIT = 20,
}
if arg and arg[2] == "spider" then BlackSpiderConfig.SPIDER = true end
dofile("loader.lua")
