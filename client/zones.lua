-- Phase 1 client glue: ox_lib points at Config.Garages. [E] on foot opens the UI; [E] as driver stores the vehicle.
local GARAGE_INTERACT = 38 -- E

local function storeCurrent(garageId)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end
    local props = lib.getVehicleProperties(veh)
    local fuel = (Bridge.Fuel and Bridge.Fuel.Call) and Bridge.Fuel.Call('GetFuel', nil, veh) or GetVehicleFuelLevel(veh)
    local plate = Utils.NormalizePlate(GetVehicleNumberPlateText(veh))
    local ok, res = pcall(lib.callback.await, 'mdp_garages:storeVehicle', false, {
        netId = NetworkGetNetworkIdFromEntity(veh), garage_id = garageId, vclass = GetVehicleClass(veh),
        props = props, fuel = tonumber(fuel), mileage = MDPClientMileage(plate),
    })
    if ok and type(res) == 'table' and res.ok then
        Bridge.Notify(_L('vehicle_stored'), 'success')
    else
        local code = Utils.ErrorCode(ok and type(res) == 'table' and res.error or 'server_error')
        Bridge.Notify(Utils.ErrorText(code), 'error')
    end
end

local function openGarage(id, g)
    exports[GetCurrentResourceName()]:OpenGarageUI('list', { garage = { id = id, label = g.label, kind = id:match('^(%a+):') } })
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
