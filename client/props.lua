-- Phase 1 client glue: km odometer only. Props are applied by Integrations' bridge/vehicle/props.lua
-- (state bag 'mdp:props' / Bridge.Props.RequestApply with confirm/timeout); there is no second applier here.
-- Odometer: km driven per plate while we drive it; base = state bag mdp:mileage (km) set by the server on spawn.
local Odo = { plate = nil, km = 0.0 }
CreateThread(function()
    local last
    while true do
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
            local plate = Utils.NormalizePlate(GetVehicleNumberPlateText(veh))
            if plate ~= Odo.plate then
                Odo.plate, Odo.km, last = plate, tonumber(Entity(veh).state['mdp:mileage']) or 0.0, nil
            end
            local pos = GetEntityCoords(veh)
            if last then
                local d = #(pos - last)
                if d < 200.0 then Odo.km = Odo.km + d / 1000.0 end -- ignore teleports
            end
            last = pos
            Wait(1000)
        else
            last = nil
            Wait(1500)
        end
    end
end)

--- Odometer value (km) for a plate, or nil if we did not drive it this session.
function MDPClientMileage(plate)
    if plate and plate == Odo.plate then return Odo.km end
    return nil
end
