-- qs-vehiclekeys (escrow). Docs ✅ https://www.quasar-store.com/docs/vehiclekeys/commands-and-exports
--   GiveServerKeys(source, plate, model, bypassKeyCheck) · RemoveServerKeys(source, plate, model)
-- model = display name (e.g. 'Adder'); read from mdp_vehicles.model by plate (server can't call GetDisplayNameFromVehicleModel).
if not IsDuplicityVersion() then return end
local RES = 'qs-vehiclekeys'

local function resolve(src, vehicle)
    local plate = Bridge.KeysCommon.ToPlate(vehicle)
    if type(src) ~= 'number' or src <= 0 or not plate then return nil end
    local ok, model = pcall(MySQL.scalar.await, 'SELECT model FROM mdp_vehicles WHERE plate = ?', { plate })
    return plate, (ok and model) or 'unknown'
end

Bridge.RegisterAdapter('keys', RES, {
    GiveKeys = function(src, vehicle)
        local plate, model = resolve(src, vehicle); if not plate then return false end
        exports[RES]:GiveServerKeys(src, plate, model, false)
        return true
    end,
    RemoveKeys = function(src, vehicle)
        local plate, model = resolve(src, vehicle); if not plate then return false end
        exports[RES]:RemoveServerKeys(src, plate, model)
        return true
    end,
})
