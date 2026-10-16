-- NUI plumbing (contract: docs/architecture.md "NUI contract"). No globals: local UI table + exports.
local UI = { open = false }
local blockPauseWhileOpen -- defined below

local function setClosed()
    SetNuiFocus(false, false)
    UI.open = false
end

--- Open the garage UI. view = 'list' | 'detail'
function UI.Open(view, data)
    SendNUIMessage({ action = 'open', view = view or 'list', data = data or {}, locale = UILocale() })
    SetNuiFocus(true, true)
    if not UI.open then
        UI.open = true
        blockPauseWhileOpen()
    end
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

-- Closing is NUI-only (the NUI handles ESC and calls 'close'). While open, this loop only disables the
-- pause menu controls every frame (plus non-ESC stuck-focus recovery), and exits as soon as the UI is closed.
function blockPauseWhileOpen()
    CreateThread(function()
        local graceUntil = GetGameTimer() + 1000
        while UI.open do
            -- stuck-focus recovery (not ESC-based): UI marked open but NUI lost focus
            if GetGameTimer() > graceUntil and not IsNuiFocused() then setClosed() break end
            DisableControlAction(0, 199, true) -- INPUT_FRONTEND_PAUSE
            DisableControlAction(0, 200, true) -- INPUT_FRONTEND_PAUSE_ALTERNATE
            Wait(0)
        end
    end)
end

AddEventHandler('onResourceStop', function(res)
    if res == GetCurrentResourceName() and UI.open then SetNuiFocus(false, false) end
end)
