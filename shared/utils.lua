-- Shared helpers (client + server)
Utils = Utils or {}

--- Plate normalizer: trim, collapse internal whitespace to one space, upper. nil for non-strings.
function Utils.NormalizePlate(v)
    if type(v) ~= 'string' then return nil end
    return (v:gsub('%s+', ' '):gsub('^ ', ''):gsub(' $', ''):upper())
end

--- Plate rule: after normalization, length 1..Config.PlateMaxLength (8), chars [A-Z0-9 ] only.
function Utils.IsValidPlate(v)
    local p = Utils.NormalizePlate(v)
    local max = math.min(tonumber(Config.PlateMaxLength) or 8, 12)
    return p ~= nil and #p >= 1 and #p <= max and p:match('^[A-Z0-9 ]+$') ~= nil
end

local GARAGE_KINDS = { public = true, private = true, impound = true }

--- garage_id format: public:<id> | private:<id> | impound:<id>
--- <id> = [A-Za-z0-9_-], 1-32 chars. Returns kind, id or nil.
function Utils.ParseGarageId(v)
    if type(v) ~= 'string' or #v > 40 then return nil end
    local kind, id = v:match('^(%a+):([%w_%-]+)$')
    if not kind or not GARAGE_KINDS[kind] or #id > 32 then return nil end
    return kind, id
end

function Utils.IsValidGarageId(v) return Utils.ParseGarageId(v) ~= nil end

--- Mileage stored in km; convert for display per Config.MileageUnit.
function Utils.FormatMileage(km)
    if Config.MileageUnit == 'mi' then return km * 0.621371, 'mi' end
    return km, 'km'
end

--- Resolve a stored garage_id: invalid format, or public id missing from Config.Garages,
--- is remapped to Config.DefaultGarage with a console warning. private/impound: format only.
---@return string garageId, boolean remapped
function Utils.ResolveGarageId(garageId, plate)
    local kind = Utils.ParseGarageId(garageId)
    if kind and (kind ~= 'public' or (Config.Garages and Config.Garages[garageId])) then
        return garageId, false
    end
    print(('^3[mdp_garages] unknown garage "%s" for plate %s -> remapped to %s^0'):format(
        tostring(garageId), tostring(plate), tostring(Config.DefaultGarage)))
    return Config.DefaultGarage, true
end

--- Server may set this to resolve private garages from DB: fn(id) -> garage table|nil
Utils.PrivateGarageLookup = Utils.PrivateGarageLookup or nil

--- Resolve a garage by id and check its kind. expectedKind: string | {kind=true,...} | nil
--- public/impound come from Config.Garages; private via Utils.PrivateGarageLookup (server).
---@return table|nil garage, string|nil err
function Utils.GetGarage(id, expectedKind)
    local kind, key = Utils.ParseGarageId(id)
    if not kind then return nil, 'invalid_garage' end
    if expectedKind then
        local okKind = type(expectedKind) == 'table' and expectedKind[kind] or expectedKind == kind
        if not okKind then return nil, 'wrong_garage_kind' end
    end
    local g
    if kind == 'private' then
        g = Utils.PrivateGarageLookup and Utils.PrivateGarageLookup(key) or nil
    else
        g = Config.Garages and Config.Garages[id] or nil
    end
    if not g then return nil, 'unknown_garage' end
    return g, nil
end

--- Vehicle type helpers (automobile|bike|boat|heli|plane).
function Utils.IsValidVehicleType(t) return type(t) == 'string' and Constants.VehicleTypes[t] == true end

--- GTA vehicle class -> type: 8,13 bike; 14 boat; 15 heli; 16 plane; else automobile.
function Utils.VehicleTypeFromClass(class)
    class = tonumber(class)
    if class == 8 or class == 13 then return 'bike' end
    if class == 14 then return 'boat' end
    if class == 15 then return 'heli' end
    if class == 16 then return 'plane' end
    return 'automobile'
end

--- Does the garage accept this vehicle type? garage.types = { 'automobile', ... }; missing = automobile only.
function Utils.GarageAllowsType(garage, vtype)
    local types = garage and garage.types or { 'automobile' }
    for _, t in ipairs(types) do if t == vtype then return true end end
    return false
end
