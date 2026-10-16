-- MrNewbVehicleKeys. Docs ✅ https://mrnewbs-scrips.gitbook.io/guide/mrnewbvehiclekeys-beta/vehicle-keys-exports/server-exports
-- Server: GiveKeysByPlate(source, plate[, autoKeyring]) · RemoveKeysByPlate(source, plate[, deepSearch])
--         GiveKeys/RemoveKeys(source, netId) also exist. HasKeys server export: ⚠️ not confirmed -> not used.
if not IsDuplicityVersion() then return end
local RES = 'MrNewbVehicleKeys'

local function plateOf(src, vehicle)
    local plate = Bridge.KeysCommon.ToPlate(vehicle)
    if type(src) ~= 'number' or src <= 0 or not plate then return nil end
    return plate
end

Bridge.RegisterAdapter('keys', RES, {
    GiveKeys = function(src, vehicle)
        local plate = plateOf(src, vehicle); if not plate then return false end
        exports[RES]:GiveKeysByPlate(src, plate, true)
        return true
    end,
    RemoveKeys = function(src, vehicle)
        local plate = plateOf(src, vehicle); if not plate then return false end
        exports[RES]:RemoveKeysByPlate(src, plate, true)
        return true
    end,
})
