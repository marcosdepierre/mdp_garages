-- Shared helpers for key adapters (Integrations).
Bridge.KeysCommon = {}
-- Plate normalization delegates to shared/utils.lua (upper + collapse spaces + length/charset check).
function Bridge.KeysCommon.Trim(s)
    if not Utils.IsValidPlate(s) then return nil end
    return Utils.NormalizePlate(s)
end
--- Accepts a plate string or a vehicle entity; returns Utils.NormalizePlate'd plate (validated) or nil.
function Bridge.KeysCommon.ToPlate(v)
    local raw
    if type(v) == 'string' then raw = v
    elseif type(v) == 'number' and v ~= 0 and DoesEntityExist(v) then raw = GetVehicleNumberPlateText(v) end
    if not raw or not Utils.IsValidPlate(raw) then return nil end
    return Utils.NormalizePlate(raw)
end
--- Plate -> entity of a vehicle with that plate (server: GetAllVehicles; client: CVehicle pool). Entity passthrough.
local function vehiclePool()
    if IsDuplicityVersion() then return GetAllVehicles() end
    return GetGamePool('CVehicle')
end
function Bridge.KeysCommon.ToEntity(v)
    if type(v) == 'number' then return (v ~= 0 and DoesEntityExist(v)) and v or nil end
    local plate = Bridge.KeysCommon.ToPlate(v); if not plate then return nil end
    for _, veh in ipairs(vehiclePool()) do
        if Bridge.KeysCommon.ToPlate(veh) == plate then return veh end
    end
    return nil
end
