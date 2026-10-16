-- Native fuel helpers shared by fuel adapters (Integrations). Client + server safe.
Bridge.FuelCommon = {}
function Bridge.FuelCommon.Clamp(v)
    v = tonumber(v) or 100.0
    if v ~= v then v = 100.0 end
    return math.max(0.0, math.min(100.0, v + 0.0))
end
function Bridge.FuelCommon.Valid(veh)
    return type(veh) == 'number' and veh ~= 0 and DoesEntityExist(veh)
end
function Bridge.FuelCommon.Get(veh)
    if not Bridge.FuelCommon.Valid(veh) then return 0.0 end
    if IsDuplicityVersion() then return Entity(veh).state.fuel or 0.0 end
    return GetVehicleFuelLevel(veh)
end
function Bridge.FuelCommon.Set(veh, v)
    if not Bridge.FuelCommon.Valid(veh) then return false end
    v = Bridge.FuelCommon.Clamp(v)
    if not IsDuplicityVersion() then SetVehicleFuelLevel(veh, v) end
    return true
end
