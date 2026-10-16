-- cdn-fuel adapter (client). Verified exports: exports['cdn-fuel']:GetFuel(vehicle) -> number, exports['cdn-fuel']:SetFuel(vehicle, fuel)
-- Sources: https://github.com/CodineDev/cdn-fuel (fxmanifest, client/utils.lua)
if IsDuplicityVersion() then return end
local RES = 'cdn-fuel'

Bridge.RegisterAdapter('fuel', RES, {
    GetFuel = function(veh)
        if not FuelCommon.Valid(veh) then return 0.0 end
        local ok, v = pcall(function() return exports[RES]:GetFuel(veh) end)
        if ok and type(v) == 'number' then return v end
        return FuelCommon.Get(veh) -- native fallback
    end,
    SetFuel = function(veh, value)
        if not FuelCommon.Valid(veh) then return false end
        value = FuelCommon.Clamp(value)
        local ok = pcall(function() exports[RES]:SetFuel(veh, value) end)
        if not ok then return FuelCommon.Set(veh, value) end
        return true
    end,
})
