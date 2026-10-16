-- qbx_vehiclekeys adapter. Source: https://github.com/Qbox-project/qbx_vehiclekeys
-- server/keys.lua: GiveKeys(source, vehicle, skipNotification), RemoveKeys(source, vehicle, skipNotification), HasKeys(source, vehicle)
-- client/functions.lua: HasKeys(vehicle).  vehicle = ENTITY handle (not plate).
local RES = 'qbx_vehiclekeys'

if IsDuplicityVersion() then
    local function call(fn, src, vehicle, ...)
        if type(src) ~= 'number' or src <= 0 then return false end
        local veh = Bridge.KeysCommon.ToEntity(vehicle); if not veh then return false end
        local ok, res = pcall(function(...) return exports[RES][fn](exports[RES], src, veh, ...) end, ...)
        return ok and res
    end
    Bridge.RegisterAdapter('keys', RES, {
        GiveKeys   = function(src, vehicle) return call('GiveKeys', src, vehicle, true) ~= false end,
        RemoveKeys = function(src, vehicle) return call('RemoveKeys', src, vehicle, true) ~= false end,
        HasKeys    = function(src, vehicle) return call('HasKeys', src, vehicle) == true end,
    })
else
    Bridge.RegisterAdapter('keys', RES, {
        HasKeys = function(vehicle)
            local veh = Bridge.KeysCommon.ToEntity(vehicle) -- entity or (normalized) plate
            if not veh then return false end
            local ok, res = pcall(function() return exports[RES]:HasKeys(veh) end)
            return ok and res == true
        end,
    })
end
