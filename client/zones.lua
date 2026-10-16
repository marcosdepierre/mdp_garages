-- Phase 1 client: ox_lib points at Config.Garages. [E] on foot opens the UI; [E] as driver stores the vehicle.
-- Feedback = NUI toasts (sonner + FeaturedIcon, design-system §9.2/§9.3) via exports GarageToast.
local GARAGE_INTERACT = 38 -- E
local RES = GetCurrentResourceName()
local busy = false -- one store/park request at a time (server also rate-limits 1/s)

local function toast(t) exports[RES]:GarageToast(t) end

--- Props via Integrations' Bridge.Props.Get (ox_lib props + fuel bridge); never lib.getVehicleProperties directly.
local function readVehicle(veh)
    local props = Bridge.Props and Bridge.Props.Get and Bridge.Props.Get(veh) or nil
    local fuel = (Bridge.Fuel and Bridge.Fuel.Call) and Bridge.Fuel.Call('GetFuel', nil, veh) or GetVehicleFuelLevel(veh)
    local plate = Utils.NormalizePlate(GetVehicleNumberPlateText(veh))
    return props, tonumber(fuel), MDPClientMileage(plate)
end

--- lib.callback -> {ok, error?} (pcall-safe)
local function call(name, payload)
    local ok, res = pcall(lib.callback.await, name, false, payload)
    if not ok or type(res) ~= 'table' then return { ok = false, error = 'server_error' } end
    return res
end

local function storeCurrent(garageId)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end
    if busy then return end
    busy = true
    local props, fuel, mileage = readVehicle(veh)
    local label = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    local plate = Utils.NormalizePlate(GetVehicleNumberPlateText(veh))
    toast({ id = 'store', kind = 'loading', titleKey = 'storing', description = label .. ' · ' .. plate })
    local res = call('mdp_garages:storeVehicle', {
        netId = NetworkGetNetworkIdFromEntity(veh), garage_id = garageId, vclass = GetVehicleClass(veh),
        props = props, fuel = fuel, mileage = mileage, -- no plate: resolved server-side
    })
    if res.ok then
        toast({ id = 'store', kind = 'success', title = _L('vehicle_stored'), description = label .. ' · ' .. plate })
    else
        toast({ id = 'store', kind = 'error', error = res.error or 'server_error' })
    end
    busy = false
end

--- Open without vehicles: the NUI shows LoadingIndicator and calls the 'getVehicles' NUI callback itself
--- (EmptyState error + Retry on failure). See web/src/App.tsx.
local function openGarage(id, g)
    exports[RES]:OpenGarageUI('list', { garage = { id = id, label = g.label, kind = id:match('^(%a+):') } })
end

CreateThread(function()
    for id, g in pairs(Config.Garages or {}) do
        if g.coords then
            local point = lib.points.new({ coords = g.coords, distance = math.max(g.radius or 3.0, 3.0) + 2.0 })
            function point:onEnter() lib.showTextUI(_L('prompt_garage')) end
            function point:onExit() lib.hideTextUI() end
            function point:nearby()
                if IsControlJustReleased(0, GARAGE_INTERACT) then
                    if IsPedInAnyVehicle(PlayerPedId(), false) then storeCurrent(id) else openGarage(id, g) end
                end
            end
        end
    end
end)

--- /mdp_park: park the vehicle you just left where it stands (must be out of it, within 5 m, owner/key holder).
RegisterCommand('mdp_park', function()
    local ped = PlayerPedId()
    if IsPedInAnyVehicle(ped, false) then return toast({ id = 'park', kind = 'error', error = 'occupied' }) end
    local veh = GetVehiclePedIsIn(ped, true) -- last vehicle
    if veh == 0 or not DoesEntityExist(veh) then return toast({ id = 'park', kind = 'error', error = 'not_found' }) end
    if busy then return end
    busy = true
    local props, fuel, mileage = readVehicle(veh)
    toast({ id = 'park', kind = 'loading', titleKey = 'parking' })
    local res = call('mdp_garages:parkWorld', {
        netId = NetworkGetNetworkIdFromEntity(veh), vclass = GetVehicleClass(veh),
        props = props, fuel = fuel, mileage = mileage,
    })
    if res.ok then
        toast({ id = 'park', kind = 'success', title = _L('vehicle_parked') })
    else
        -- world_limit: server also sends a notify with the limit; the toast shows the generic err_world_limit
        toast({ id = 'park', kind = 'error', error = res.error or 'server_error' })
    end
    busy = false
end, false)
