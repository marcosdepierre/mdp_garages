-- Shared helpers for key adapters (Integrations).
Bridge.KeysCommon = {}
-- Plate normalization delegates to shared/utils.lua (upper + collapse spaces + length/charset check).
function Bridge.KeysCommon.Trim(s)
    if not Utils.IsValidPlate(s) then return nil end
    return Utils.NormalizePlate(s)
end
--- Accepts a plate string or a vehicle entity; returns trimmed plate or nil.
function Bridge.KeysCommon.ToPlate(v)
    if type(v) == 'string' then return Bridge.KeysCommon.Trim(v) end
    if type(v) == 'number' and v ~= 0 and DoesEntityExist(v) then
        return Bridge.KeysCommon.Trim(GetVehicleNumberPlateText(v))
    end
    return nil
end
--- Plate -> entity of a vehicle with that plate (server: GetAllVehicles; client: CVehicle pool). Entity passthrough.
local function vehiclePool()
    if IsDuplicityVersion() then return GetAllVehicles() end
    return GetGamePool('CVehicle')
end
--- (legacy comment) Server: plate -> entity of a spawned vehicle with that plate (or nil). Entity passthrough.
function Bridge.KeysCommon.ToEntity(v)
    if type(v) == 'number' then return (v ~= 0 and DoesEntityExist(v)) and v or nil end
    local plate = Bridge.KeysCommon.Trim(v); if not plate then return nil end
    for _, veh in ipairs(vehiclePool()) do
        if Bridge.KeysCommon.Trim(GetVehicleNumberPlateText(veh)) == plate then return veh end
    end
    return nil
end
