-- qb-vehiclekeys adapter (PLATE-based). Source: https://github.com/qbcore-framework/qb-vehiclekeys
-- server.lua: exports GiveKeys(id, plate), RemoveKeys(id, plate), HasKeys(id, plate) -> boolean
-- client.lua: exports HasKeys(plate); events vehiclekeys:client:SetOwner(plate), qb-vehiclekeys:client:RemoveKeys(plate)
local RES = 'qb-vehiclekeys'

if IsDuplicityVersion() then
    Bridge.RegisterAdapter('keys', RES, {
        GiveKeys = function(src, vehicle)
            local plate = Bridge.KeysCommon.ToPlate(vehicle)
            if type(src) ~= 'number' or src <= 0 or not plate then return false end
            if pcall(function() exports[RES]:GiveKeys(src, plate) end) then return true end
            TriggerClientEvent('vehiclekeys:client:SetOwner', src, plate) -- fallback for older builds
            return true
        end,
        RemoveKeys = function(src, vehicle)
            local plate = Bridge.KeysCommon.ToPlate(vehicle)
            if type(src) ~= 'number' or src <= 0 or not plate then return false end
            if pcall(function() exports[RES]:RemoveKeys(src, plate) end) then return true end
            TriggerClientEvent('qb-vehiclekeys:client:RemoveKeys', src, plate)
            return true
        end,
        HasKeys = function(src, vehicle)
            local plate = Bridge.KeysCommon.ToPlate(vehicle)
            if type(src) ~= 'number' or src <= 0 or not plate then return false end
            local ok, res = pcall(function() return exports[RES]:HasKeys(src, plate) end)
            return ok and res == true
        end,
    })
else
    Bridge.RegisterAdapter('keys', RES, {
        HasKeys = function(vehicle)
            local plate = Bridge.KeysCommon.ToPlate(vehicle); if not plate then return false end
            local ok, res = pcall(function() return exports[RES]:HasKeys(plate) end)
            return ok and res == true
        end,
    })
end
