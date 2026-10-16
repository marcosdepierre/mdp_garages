-- Mirror mdp_vehicles -> framework tables (Integrations). Server only.
-- Enabled when Config.SyncFrameworkTables (and Config.MirrorFrameworkTables ~= false). Only UPDATEs existing rows by plate
-- (never inserts/deletes framework rows); parameterized; pcall + log; never throws.
--   qb / qbx: player_vehicles (mods LONGTEXT, fuel INT, engine FLOAT, body FLOAT, state INT 0=out 1=garaged 2=impound, garage)
--             schema ✅ https://github.com/Qbox-project/qbx_vehicles/blob/main/vehicles.sql
--   esx:      owned_vehicles (vehicle LONGTEXT JSON, stored TINYINT 0/1, parking, pound)
--             schema ✅ https://github.com/esx-framework/esx_core/blob/main/%5BSQL%5D/legacy.sql
if not IsDuplicityVersion() then return end
Bridge.FrameworkSync = Bridge.FrameworkSync or {}

local function enabled()
    return Config.SyncFrameworkTables == true and Config.MirrorFrameworkTables ~= false
        and (Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' or Bridge.Framework == 'esx')
end

local function log(msg) print('^3[mdp_garages][fwsync] ' .. msg .. '^0') end

--- mdp state -> qb/qbx state (nil = leave column untouched: RETIRED/REMOVED/unknown)
local function qbState(s)
    local VS = Constants.VehicleState
    if s == VS.OUT or s == VS.PARKED_WORLD then return 0 end
    if s == VS.GARAGED then return 1 end
    if s == VS.IMPOUNDED then return 2 end
    return nil
end

local function int(v, lo, hi, def)
    v = tonumber(v); if not v or v ~= v then return def end
    return math.floor(math.max(lo, math.min(hi, v)) + 0.5)
end

--- Mirror one vehicle. data = { state?, garage_id?, props? (table|json), fuel?, engine?, body? }
--- Returns true if a framework row was updated, false otherwise (disabled, not found, error).
function Bridge.FrameworkSync.Mirror(plate, data)
    if not enabled() then return false end
    plate = Utils.NormalizePlate(plate)
    if not plate or not Utils.IsValidPlate(plate) or type(data) ~= 'table' then return false end
    local propsJson
    if data.props ~= nil then
        local t, enc = Bridge.Props.Sanitize(data.props, plate)
        if not t then log(('props rejected for %s: %s'):format(plate, tostring(enc))) else propsJson = enc end
    end
    local sets, args = {}, {}
    local function add(col, v) if v ~= nil then sets[#sets + 1] = col .. ' = ?'; args[#args + 1] = v end end
    if Bridge.Framework == 'esx' then
        add('`vehicle`', propsJson)
        if data.state ~= nil then
            local VS = Constants.VehicleState
            add('`stored`', data.state == VS.GARAGED and 1 or 0)
            if data.state == VS.GARAGED then add('`parking`', data.garage_id) end
        end
        if #sets == 0 then return false end
        args[#args + 1] = plate
        local ok, n = pcall(MySQL.update.await, 'UPDATE owned_vehicles SET ' .. table.concat(sets, ', ') .. ' WHERE plate = ?', args)
        if not ok then log('esx update failed for ' .. plate .. ': ' .. tostring(n)) return false end
        return (n or 0) > 0
    end
    add('`mods`', propsJson)
    add('`fuel`', data.fuel ~= nil and int(data.fuel, 0, 100, nil) or nil)
    add('`engine`', data.engine ~= nil and int(data.engine, 0, 1000, nil) or nil)
    add('`body`', data.body ~= nil and int(data.body, 0, 1000, nil) or nil)
    if data.state ~= nil then add('`state`', qbState(data.state)) end
    if data.state == Constants.VehicleState.GARAGED then add('`garage`', data.garage_id) end
    if #sets == 0 then return false end
    args[#args + 1] = plate
    local ok, n = pcall(MySQL.update.await, 'UPDATE player_vehicles SET ' .. table.concat(sets, ', ') .. ' WHERE plate = ?', args)
    if not ok then log('qb update failed for ' .. plate .. ': ' .. tostring(n)) return false end
    return (n or 0) > 0
end

--- Convenience hooks for Backend (server/garages.lua):
function Bridge.FrameworkSync.OnStore(plate, garageId, props, fuel, engine, body)
    return Bridge.FrameworkSync.Mirror(plate, { state = Constants.VehicleState.GARAGED, garage_id = garageId,
        props = props, fuel = fuel, engine = engine, body = body })
end
function Bridge.FrameworkSync.OnSpawn(plate)
    return Bridge.FrameworkSync.Mirror(plate, { state = Constants.VehicleState.OUT })
end
function Bridge.FrameworkSync.OnImpound(plate)
    return Bridge.FrameworkSync.Mirror(plate, { state = Constants.VehicleState.IMPOUNDED })
end
