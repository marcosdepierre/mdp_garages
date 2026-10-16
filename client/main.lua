-- NUI plumbing (contract: see docs/architecture.md "NUI contract")
local nuiOpen = false

local function closeNui(sendClose)
    if sendClose then SendNUIMessage({ action = 'close' }) end
    SetNuiFocus(false, false)
    nuiOpen = false
end

--- Open the garage UI. view = 'list' | 'detail'
function OpenGarageUI(view, data)
    SendNUIMessage({ action = 'open', view = view or 'list', data = data or {} })
    SetNuiFocus(true, true)
    nuiOpen = true
end

function UpdateGarageUI(data, view)
    SendNUIMessage({ action = 'update', data = data, view = view })
end

function CloseGarageUI() closeNui(true) end

RegisterNUICallback('close', function(_, cb)
    closeNui(false)
    cb({ ok = true })
end)

-- Validated proxies to server lib.callback. Prices never come from NUI.
RegisterNUICallback('getVehicles', function(req, cb)
    local gid = type(req) == 'table' and req.garage_id or nil
    if not Utils.IsValidGarageId(gid) then return cb({ ok = false, error = 'invalid_garage' }) end
    local ok, res = pcall(lib.callback.await, 'mdp_garages:getVehicles', false, { garage_id = gid })
    if not ok or type(res) ~= 'table' then return cb({ ok = false, error = 'server_error' }) end
    cb(res)
end)

RegisterNUICallback('takeOut', function(req, cb)
    if type(req) ~= 'table' then return cb({ ok = false, error = 'invalid_request' }) end
    local plate = Utils.NormalizePlate(req.plate)
    if not Utils.IsValidPlate(plate) or not Utils.IsValidGarageId(req.garage_id) then
        return cb({ ok = false, error = 'invalid_request' })
    end
    local ok, res = pcall(lib.callback.await, 'mdp_garages:takeOut', false, { plate = plate, garage_id = req.garage_id })
    if not ok or type(res) ~= 'table' then return cb({ ok = false, error = 'server_error' }) end
    if res.ok then closeNui(true) end
    cb(res)
end)

-- Escape safety net: NUI handles ESC itself and calls 'close'; this catches lost focus states.
CreateThread(function()
    while true do
        if nuiOpen then
            DisableControlAction(0, 200, true) -- pause menu
            if IsDisabledControlJustReleased(0, 200) or IsControlJustReleased(0, 322) then closeNui(true) end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and nuiOpen then SetNuiFocus(false, false) end
end)
