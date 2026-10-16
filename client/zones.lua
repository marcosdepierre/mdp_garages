-- Phase 1 client: ox_lib points at Config.Garages. [E] on foot opens the UI; [E] as driver stores the vehicle.
-- Feedback = NUI toasts (sonner + FeaturedIcon, design-system §9.2/§9.3) via exports GarageToast.
local GARAGE_INTERACT = 38 -- E
local RES = GetCurrentResourceName()
local busy = false -- one store/park request at a time (server also rate-limits 1/s)
local attempt = 0  -- token per request: timers / late responses only act on their own attempt
-- P1F-M2: ox_lib's lib.callback.await has NO per-call timeout (2nd arg = throttle delay; the only timeout is
-- the global convar 'ox:callbackTimeout', default 300 s). So we use the async form lib.callback(name, false, cb, ...)
-- with our own explicit timeout, and a safety backstop above it.
local CALLBACK_TIMEOUT_MS = 15000
local SAFETY_MS = 20000

local function toast(t) exports[RES]:GarageToast(t) end

--- Props via Integrations' Bridge.Props.Get (ox_lib props + fuel bridge); never lib.getVehicleProperties directly.
local function readVehicle(veh)
    local props = Bridge.Props and Bridge.Props.Get and Bridge.Props.Get(veh) or nil
    local fuel = (Bridge.Fuel and Bridge.Fuel.Call) and Bridge.Fuel.Call('GetFuel', nil, veh) or GetVehicleFuelLevel(veh)
    local plate = Utils.NormalizePlate(GetVehicleNumberPlateText(veh))
    return props, tonumber(fuel), MDPClientMileage(plate)
end

--- P1F-R3-M1: normalize a server callback result like serverCall in client/main.lua:
--- {ok, error?, data?} tables and Security rejections returned as (false, err) tuples; codes via Utils.ErrorCode.
local function normalize(res, err)
    if res == false then return { ok = false, error = Utils.ErrorCode(err) } end
    if type(res) ~= 'table' then return { ok = false, error = 'server_error' } end
    if res.ok == false then res.error = Utils.ErrorCode(res.error) end
    return res
end

--- Security F1 / P1F-M2: busy stays set while the request is alive and is ALWAYS released
--- (response, callback timeout, safety timer, or a Lua error). prepare() -> { event, payload, map(res) -> toast }.
local function guarded(toastId, prepare)
    if busy then return end
    busy = true
    attempt = attempt + 1
    local token = attempt
    local settled = false -- this attempt's outcome toast was already shown
    local function release() if attempt == token then busy = false end end
    local function fail(code)
        if not settled then settled = true; toast({ id = toastId, kind = 'error', error = code }) end
        release()
    end

    SetTimeout(SAFETY_MS, function() if busy and attempt == token then fail('timeout') end end) -- backstop: always unlocks

    local ok, spec = xpcall(prepare, debug.traceback)
    if not ok or type(spec) ~= 'table' then
        if not ok then print(('^1[mdp_garages] %s flow error:^7 %s'):format(toastId, tostring(spec))) end
        return fail('server_error')
    end
    -- callback timeout: tell the player (timeout toast) but keep busy so the request can't be re-sent while it may
    -- still be alive; only the response or the SAFETY_MS backstop releases it.
    SetTimeout(CALLBACK_TIMEOUT_MS, function()
        if not settled and attempt == token then settled = true; toast({ id = toastId, kind = 'error', error = 'timeout' }) end
    end)
    local sent, err = pcall(lib.callback, spec.event, false, function(res, rerr)
        local okm, t = pcall(spec.map, normalize(res, rerr))
        if not okm or type(t) ~= 'table' then t = { id = toastId, kind = 'error', error = 'server_error' } end
        -- P1F-R2-M1/L2: only this attempt's toast slot; a late result (success or error, after the 15 s timeout
        -- toast) replaces it, but never once a newer request has started (it would overwrite that one's toast).
        if attempt == token then settled = true; toast(t) end
        release()
    end, spec.payload)
    if not sent then
        print(('^1[mdp_garages] %s send error:^7 %s'):format(toastId, tostring(err)))
        fail('server_error')
    end
end

local function storeCurrent(garageId)
    local ped = PlayerPedId()
    local veh = GetVehiclePedIsIn(ped, false)
    if veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped then return end
    guarded('store', function()
    local props, fuel, mileage = readVehicle(veh)
    local label = GetLabelText(GetDisplayNameFromVehicleModel(GetEntityModel(veh)))
    local plate = Utils.NormalizePlate(GetVehicleNumberPlateText(veh))
    toast({ id = 'store', kind = 'loading', titleKey = 'storing', description = label .. ' · ' .. plate })
    return { event = 'mdp_garages:storeVehicle', payload = {
        netId = NetworkGetNetworkIdFromEntity(veh), garage_id = garageId, vclass = GetVehicleClass(veh),
        props = props, fuel = fuel, mileage = mileage, -- no plate: resolved server-side
    }, map = function(res)
        if res.ok then
            return { id = 'store', kind = 'success', title = _L('vehicle_stored'), description = label .. ' · ' .. plate }
        end
        return { id = 'store', kind = 'error', error = res.error or 'server_error' }
    end }
    end)
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
    guarded('park', function()
    local props, fuel, mileage = readVehicle(veh)
    toast({ id = 'park', kind = 'loading', titleKey = 'parking' })
    return { event = 'mdp_garages:parkWorld', payload = {
        netId = NetworkGetNetworkIdFromEntity(veh), vclass = GetVehicleClass(veh),
        props = props, fuel = fuel, mileage = mileage,
    }, map = function(res)
        if res.ok then return { id = 'park', kind = 'success', title = _L('vehicle_parked') } end
        -- world_limit: server also sends a notify with the limit; the toast shows the generic err_world_limit
        return { id = 'park', kind = 'error', error = res.error or 'server_error' }
    end }
    end)
end, false)
