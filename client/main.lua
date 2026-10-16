-- NUI plumbing (contract: docs/architecture.md "NUI contract"). No globals: local UI table + exports.
local UI = { open = false }

local function setClosed()
    SetNuiFocus(false, false)
    UI.open = false
end

--- Open the garage UI. view = 'list' | 'detail'
function UI.Open(view, data)
    SendNUIMessage({ action = 'open', view = view or 'list', data = data or {} })
    SetNuiFocus(true, true)
    UI.open = true
end

--- Partial update: NUI merges `data` onto its current state.
function UI.Update(data, view)
    SendNUIMessage({ action = 'update', data = data, view = view })
end

function UI.Close()
    SendNUIMessage({ action = 'close' })
    setClosed()
end

exports('OpenGarageUI', UI.Open)
exports('UpdateGarageUI', UI.Update)
exports('CloseGarageUI', UI.Close)

--- Call a server lib.callback and normalize to { ok, error?, data? }.
local function serverCall(name, payload)
    local ok, res, err = pcall(lib.callback.await, name, false, payload)
    if not ok then return { ok = false, error = 'server_error' } end
    if res == false then return { ok = false, error = err or 'rejected' } end -- Security rejection (false, reason)
    if type(res) ~= 'table' then return { ok = false, error = 'server_error' } end
    return res
end

RegisterNUICallback('close', function(_, cb)
    setClosed()
    cb({ ok = true })
end)

-- Validated proxies; server response passed straight through. Prices never come from NUI.
RegisterNUICallback('getVehicles', function(req, cb)
    local gid = type(req) == 'table' and req.garage_id or nil
    if not Utils.IsValidGarageId(gid) then return cb({ ok = false, error = 'invalid_garage' }) end
    cb(serverCall('mdp_garages:getVehicles', { garage_id = gid }))
end)

RegisterNUICallback('takeOut', function(req, cb)
    if type(req) ~= 'table' then return cb({ ok = false, error = 'invalid_request' }) end
    local plate = Utils.NormalizePlate(req.plate)
    if not Utils.IsValidPlate(plate) or not Utils.IsValidGarageId(req.garage_id) then
        return cb({ ok = false, error = 'invalid_request' })
    end
    local res = serverCall('mdp_garages:takeOut', { plate = plate, garage_id = req.garage_id })
    if res.ok then UI.Close() end
    cb(res)
end)

-- ESC is handled by the NUI (calls 'close'). This loop only blocks the pause menu while open and
-- recovers a hung focus state (UI marked open but NUI no longer focused).
CreateThread(function()
    while true do
        if UI.open then
            DisableControlAction(0, 200, true)
            if not IsNuiFocused() then setClosed() end
            Wait(0)
        else
            Wait(500)
        end
    end
end)

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and UI.open then SetNuiFocus(false, false) end
end)
