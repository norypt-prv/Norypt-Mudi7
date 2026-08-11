-- tests/lua/test_imei_generate.lua
-- SPDX-License-Identifier: GPL-2.0-only
package.path = "files/lib/norypt-ghost/?.lua;" .. package.path
local luhn = require("luhn")
local fails = 0
local function ok(cond, msg) if not cond then fails = fails + 1; print("FAIL " .. msg) end end

-- Interpreter to spawn the generator with. tests/run.sh exports NG_LUA (Ubuntu
-- ships lua5.1, not a plain `lua`); arg[-1] is the running interpreter when the
-- test is invoked directly. run.sh also exports LUA_PATH so the child's
-- require("luhn") resolves off-device.
local LUA = os.getenv("NG_LUA") or arg[-1] or "lua"
local GEN = "files/lib/norypt-ghost/imei_generate.lua"

-- A verified TAC from the shipped catalog (Apple iPhone 15 Pro, A3102).
local TAC = "35937079"

local function gen()
    local h = io.popen(string.format('%q %s fromtac %s', LUA, GEN, TAC))
    if not h then return nil end
    local line = h:read("*l")
    h:close()
    return line
end

-- fromtac output is 15 digits, Luhn-valid, and starts with the given TAC.
local imei = gen()
ok(imei ~= nil, "generator produced output (check LUA_PATH / interpreter)")
if imei then
    ok(#imei == 15, "length 15 (got " .. #imei .. ": " .. imei .. ")")
    ok(imei:sub(1, 8) == TAC, "TAC preserved (got " .. imei:sub(1, 8) .. ")")
    ok(luhn.is_valid(imei), "Luhn valid (" .. imei .. ")")

    -- Distribution: repeated serials over one TAC should not collide trivially.
    local seen, dup = {}, 0
    for _ = 1, 200 do
        local v = gen()
        if v then
            if seen[v] then dup = dup + 1 end
            seen[v] = true
        end
    end
    ok(dup < 20, "serials reasonably distributed (dups=" .. dup .. ")")
end

if fails == 0 then print("lua imei tests OK") else os.exit(1) end
