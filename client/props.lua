-- Phase 1 client glue: apply server-spawned vehicle state (mdp_props state bag) and a simple km odometer.
-- mdp_props = { props = table|nil, engine = number, body = number, fuel = number, fuelOnClient = bool, mileage = km }
-- Only the network owner of the entity applies (retries until it has control, max ~10 s).
local applied = {} -- entity -> true (applied once per entity handle)

local function applyState(veh, v)
    if v.props then lib.setVehicleProperties(veh, v.props) end
    if v.engine then SetVehicleEngineHealth(veh, v.engine + 0.0) end
    if v.body then SetVehicleBodyHealth(veh, v.body + 0.0) end
    if v.fuelOnClient and v.fuel then
        -- LegacyFuel / cdn-fuel / native: set on the owning client (ox_fuel is set server-side)
        if Bridge.Fuel and Bridge.Fuel.Call then Bridge.Fuel.Call('SetFuel', false, veh, v.fuel + 0.0)
        else SetVehicleFuelLevel(veh, v.fuel + 0.0) end
    end
end

AddStateBagChangeHandler('mdp_props', nil, function(bagName, _, value)
    if type(value) ~= 'table' then return end
    CreateThread(function()
        local deadline = GetGameTimer() + 10000
        local veh = 0
        while GetGameTimer() < deadline do
            veh = GetEntityFromStateBagName(bagName)
            if veh ~= 0 and DoesEntityExist(veh) then
                if NetworkGetEntityOwner(veh) ~= PlayerId() then return end -- the owner applies
                if NetworkHasControlOfEntity(veh) then break end
                NetworkRequestControlOfEntity(veh)
            end
            Wait(100)
        end
        if veh == 0 or applied[veh] or not NetworkHasControlOfEntity(veh) then return end
        local ok, err = pcall(applyState, veh, value)
        if ok then applied[veh] = true else print('^3[mdp_garages] props apply failed: ' .. tostring(err) .. '^0') end
    end)
end)

-- Odometer: km driven per plate while we drive it; base = mdp_props.mileage from the server.
local Odo = { plate = nil, km = 0.0 }
CreateThread(function()
    local last
    while true do
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
            local plate = Utils.NormalizePlate(GetVehicleNumberPlateText(veh))
            if plate ~= Odo.plate then
                local bag = Entity(veh).state.mdp_props
                Odo.plate, Odo.km, last = plate, (type(bag) == 'table' and tonumber(bag.mileage)) or 0.0, nil
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
