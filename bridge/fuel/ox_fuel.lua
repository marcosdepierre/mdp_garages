-- ox_fuel adapter. Source: https://github.com/overextended/ox_fuel (README): no get/set exports,
-- read/write the replicated statebag Entity(veh).state.fuel.
local RES = 'ox_fuel'

Bridge.RegisterAdapter('fuel', RES, {
    GetFuel = function(veh)
        if not Bridge.FuelCommon.Valid(veh) then return 0.0 end
        local v = Entity(veh).state.fuel
        if type(v) == 'number' then return v end
        return Bridge.FuelCommon.Get(veh)
    end,
    SetFuel = function(veh, value)
        if not Bridge.FuelCommon.Valid(veh) then return false end
        value = Bridge.FuelCommon.Clamp(value)
        -- client: replicate=true requires network ownership; server: always authoritative
        local ok = pcall(function() Entity(veh).state:set('fuel', value, true) end)
        if not IsDuplicityVersion() then SetVehicleFuelLevel(veh, value) end
        return ok
    end,
})
