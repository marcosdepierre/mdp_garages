-- Shared helpers for key adapters (Integrations).
KeysCommon = {}
function KeysCommon.Trim(s)
    if type(s) ~= 'string' then return nil end
    s = s:gsub('^%s+', ''):gsub('%s+$', '')
    return s ~= '' and s or nil
end
--- Accepts a plate string or a vehicle entity; returns trimmed plate or nil.
function KeysCommon.ToPlate(v)
    if type(v) == 'string' then return KeysCommon.Trim(v) end
    if type(v) == 'number' and v ~= 0 and DoesEntityExist(v) then
        return KeysCommon.Trim(GetVehicleNumberPlateText(v))
    end
    return nil
end
--- Server: plate -> entity of a spawned vehicle with that plate (or nil). Entity passthrough.
function KeysCommon.ToEntity(v)
    if type(v) == 'number' then return (v ~= 0 and DoesEntityExist(v)) and v or nil end
    local plate = KeysCommon.Trim(v); if not plate then return nil end
    for _, veh in ipairs(GetAllVehicles()) do
        if KeysCommon.Trim(GetVehicleNumberPlateText(veh)) == plate then return veh end
    end
    return nil
end
