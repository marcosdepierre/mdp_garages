-- wasabi_carlock (escrow). Docs ✅ https://docs.wasabiscripts.com/advanced-series/wasabi-carlock/exports
-- Server: GiveKey(SERVER_ID, PLATE) -> plate · RemoveKey(SERVER_ID, PLATE) -> bool · HasKey(SERVER_ID, PLATE) -> bool
-- Client: GiveKey(PLATE), RemoveKey(PLATE), HasKey(PLATE)  (client HasKey: ⚠️ listed by third parties, not seen on docs page)
if not IsDuplicityVersion() then return end
local RES = 'wasabi_carlock'
local KC = function() return Bridge.KeysCommon end

local function args(src, vehicle)
    local plate = KC().ToPlate(vehicle)
    if type(src) ~= 'number' or src <= 0 or not plate then return nil end
    return plate
end

Bridge.RegisterAdapter('keys', RES, {
    GiveKeys = function(src, vehicle)
        local plate = args(src, vehicle); if not plate then return false end
        return exports[RES]:GiveKey(src, plate) ~= nil
    end,
    RemoveKeys = function(src, vehicle)
        local plate = args(src, vehicle); if not plate then return false end
        return exports[RES]:RemoveKey(src, plate) ~= false
    end,
    HasKeys = function(src, vehicle)
        local plate = args(src, vehicle); if not plate then return false end
        return exports[RES]:HasKey(src, plate) == true
    end,
})
