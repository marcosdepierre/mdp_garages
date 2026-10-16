-- Phase 1 client: odometer only.
-- Props/fuel/health are applied EXCLUSIVELY by Integrations (bridge/vehicle/props.lua, state bag 'mdp:props',
-- ack 'mdp_garages:server:propsApplied'). Do NOT add a props applier here (Senior + Integrations decision).

--- Base mileage (km) from the 'mdp:props' payload while it is still on the entity (it is cleared after apply).
local function baseMileage(veh)
    local bag = Entity(veh).state['mdp:props']
    if type(bag) == 'string' then
        local ok, dec = pcall(json.decode, bag); bag = ok and dec or nil
    end
    return type(bag) == 'table' and tonumber(bag.mileage) or nil
end

-- Remember the base mileage per netId as soon as the bag shows up (before Integrations clears it).
local baseByNet = {}
AddStateBagChangeHandler('mdp:props', nil, function(bagName, _, value)
    if value == nil then return end
    local veh = GetEntityFromStateBagName(bagName)
    if veh == 0 then return end
    local m = baseMileage(veh)
    if m then baseByNet[NetworkGetNetworkIdFromEntity(veh)] = m end
end)

-- Optional hook (Integrations, client-local): props applied for netId. Not awaited by any UI flow.
AddEventHandler('mdp_garages:client:propsApplied', function(netId, ok)
    -- Fires exactly once per vehicle with the FINAL result (Integrations 4bf7b64/ac77923; ok=false immediately
    -- on some failures or after ~10 s timeout). Informational only: the take-out success toast never waits on it.
end)

-- Odometer: km driven per plate while we drive it.
local Odo = { plate = nil, km = 0.0 }
CreateThread(function()
    local last
    while true do
        local ped = PlayerPedId()
        local veh = GetVehiclePedIsIn(ped, false)
        if veh ~= 0 and GetPedInVehicleSeat(veh, -1) == ped then
            local plate = Utils.NormalizePlate(GetVehicleNumberPlateText(veh))
            if plate ~= Odo.plate then
                local net = NetworkGetNetworkIdFromEntity(veh)
                Odo.plate, Odo.km, last = plate, baseByNet[net] or baseMileage(veh) or 0.0, nil
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

-- Despawn props snapshot (server/streamer.lua): the server sends a single-use token ONLY to the entity's network owner;
-- we reply with current props. The server checks owner + token + TTL and sanitizes.
RegisterNetEvent('mdp_garages:client:propsSnapshotReq', function(netId, token)
    local veh = NetworkGetEntityFromNetworkId(netId)
    if veh == 0 or not DoesEntityExist(veh) or NetworkGetEntityOwner(veh) ~= PlayerId() then return end
    local props = (Bridge.Props and Bridge.Props.Get) and Bridge.Props.Get(veh) or lib.getVehicleProperties(veh)
    if type(props) ~= 'table' then return end
    TriggerServerEvent('mdp_garages:server:propsSnapshot', { netId = netId, token = token, props = props })
end)
