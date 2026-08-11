-- tests/lua/test_imei_generate.lua
-- SPDX-License-Identifier: GPL-2.0-only
package.path = "files/lib/norypt-ghost/?.lua;" .. package.path
local luhn = require("luhn")
local fails = 0
local function ok(cond, msg) if not cond then fails = fails + 1; print("FAIL "..msg) end end

-- fromtac output is 15 digits, Luhn-valid, and starts with the given TAC.
local h = io.popen("lua files/lib/norypt-ghost/imei_generate.lua fromtac 86437503")
local imei = h:read("*l"); h:close()
ok(imei and #imei == 15, "length 15 (got "..tostring(imei)..")")
ok(imei:sub(1,8) == "86437503", "TAC preserved")
ok(luhn.is_valid(imei), "Luhn valid")

-- distribution: 200 serials over TAC should not collide trivially (sanity).
local seen, dup = {}, 0
for _=1,200 do
    local g = io.popen("lua files/lib/norypt-ghost/imei_generate.lua fromtac 86437503")
    local v = g:read("*l"); g:close()
    if seen[v] then dup = dup + 1 end; seen[v] = true
end
ok(dup < 20, "serials reasonably distributed (dups="..dup..")")

if fails == 0 then print("lua imei tests OK") else os.exit(1) end
