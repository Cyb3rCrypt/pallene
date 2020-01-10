--
-- "is sound gradual typing dead" version of nqueens benchmark
--
local modname = arg[1]
local luaname = arg[2] or "injectLua"
local INJECT  = tonumber(arg[3]) or 0
local N       = tonumber(arg[4]) or 13

local prefix = string.match(modname, "^(.*)%.")

local luaVersion = require(prefix .. "." .. luaname)
local plnVersion = require(prefix .. ".injectPln")

for i, funcname in ipairs({ "isplaceok", "printsolution", "addqueen" }) do
    local mask = 1 << (i-1)
    local injector = "inject_"..funcname

    if (0 == INJECT & mask) then
        plnVersion[injector](luaVersion[funcname])
    else
        luaVersion[injector](plnVersion[funcname.."_pln"])
    end
end

plnVersion.nqueens(N)