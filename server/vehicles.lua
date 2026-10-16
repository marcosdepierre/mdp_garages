-- mdp_vehicles is the source of truth. This module:
--  * imports rows from framework tables (owned_vehicles / player_vehicles), batched INSERT IGNORE, originals untouched
--  * syncs a player's missing plates on load (Config.SyncFrameworkTables)
--  * exposes export AddVehicle for dealerships
Vehicles = {}
local VS = Constants.VehicleState

local schemaCache = {}
local function tableExists(name)
    local key = 't:' .. name
    if schemaCache[key] == nil then
        schemaCache[key] = MySQL.scalar.await(
            'SELECT 1 FROM information_schema.tables WHERE table_schema = DATABASE() AND table_name = ? LIMIT 1', { name }) ~= nil
    end
    return schemaCache[key]
end

local function columnExists(tbl, col)
    local key = 'c:' .. tbl .. '.' .. col
    if schemaCache[key] == nil then
        schemaCache[key] = MySQL.scalar.await(
            'SELECT 1 FROM information_schema.columns WHERE table_schema = DATABASE() AND table_name = ? AND column_name = ? LIMIT 1',
            { tbl, col }) ~= nil
    end
    return schemaCache[key]
end
Vehicles.TableExists, Vehicles.ColumnExists = tableExists, columnExists

local function modelFromProps(raw)
    local ok, props = pcall(json.decode, raw or '{}')
    if ok and type(props) == 'table' and props.model then return tostring(props.model) end
    return nil
end

--- Normalize one framework row into an mdp_vehicles row, or nil + skip reason.
--- framework: 'esx' | 'qb'
function Vehicles.MapFrameworkRow(framework, r)
    local mig = Config.Migration or {}
    local plate = Utils.NormalizePlate(r.plate)
    if not Utils.IsValidPlate(plate) then return nil, 'invalid_plate' end
    if framework == 'esx' then
        if r.type ~= nil and not (mig.VehicleTypes or { car = true })[tostring(r.type)] then return nil, 'type' end
        if mig.SkipJobVehicles ~= false and r.job ~= nil and r.job ~= '' and r.job ~= 'civ' then return nil, 'job' end
        local state = VS.GARAGED
        if r.stored ~= nil and tonumber(r.stored) == 0 and mig.NotStored == 'impounded' then state = VS.IMPOUNDED end
        local gid = Utils.ResolveGarageId(r.parking and r.parking ~= '' and ('public:' .. tostring(r.parking)) or nil, plate)
        if state == VS.IMPOUNDED then gid = nil end
        return { plate = plate, owner = r.owner, model = modelFromProps(r.vehicle) or 'unknown', props = r.vehicle,
                 state = state, garage_id = gid, fuel = 100, engine = 1000, body = 1000 }
    else
        local state = (tonumber(r.state) == 2) and VS.IMPOUNDED or VS.GARAGED
        local gid = state == VS.GARAGED and Utils.ResolveGarageId(r.garage and ('public:' .. tostring(r.garage)) or nil, plate) or nil
        return { plate = plate, owner = r.citizenid, model = tostring(r.vehicle or 'unknown'), props = r.mods,
                 state = state, garage_id = gid, fuel = tonumber(r.fuel) or 100,
                 engine = tonumber(r.engine) or 1000, body = tonumber(r.body) or 1000 }
    end
end

--- Batched INSERT IGNORE. Returns inserted count.
function Vehicles.InsertBatch(rows)
    local inserted, size = 0, (Config.Migration and Config.Migration.BatchSize) or 500
    for i = 1, #rows, size do
        local ph, params = {}, {}
        for j = i, math.min(i + size - 1, #rows) do
            local r = rows[j]
            ph[#ph + 1] = '(?, ?, ?, ?, ?, ?, ?, ?, ?)'
            for _, v in ipairs({ r.plate, r.owner, r.model, r.props, r.state, r.garage_id, r.fuel, r.engine, r.body }) do
                params[#params + 1] = v
            end
        end
        local affected = MySQL.update.await(
            'INSERT IGNORE INTO mdp_vehicles (plate, owner, model, props, state, garage_id, fuel, engine, body) VALUES '
            .. table.concat(ph, ', '), params)
        inserted = inserted + (affected or 0)
    end
    return inserted
end

--- Select framework rows (optionally for one owner), map, insert. Returns read, inserted, skipped{reason=n}.
function Vehicles.ImportFromFramework(framework, owner)
    local tbl, ownerCol, cols
    if framework == 'esx' then
        tbl, ownerCol = 'owned_vehicles', 'owner'
        cols = { 'owner', 'plate', 'vehicle' }
        for _, c in ipairs({ 'type', 'job', 'stored', 'parking' }) do
            if columnExists(tbl, c) then cols[#cols + 1] = c end
        end
    elseif framework == 'qb' or framework == 'qbx' then
        framework, tbl, ownerCol = 'qb', 'player_vehicles', 'citizenid'
        cols = { 'citizenid', 'plate', 'vehicle', 'mods' }
        for _, c in ipairs({ 'garage', 'fuel', 'engine', 'body', 'state' }) do
            if columnExists(tbl, c) then cols[#cols + 1] = c end
        end
    else
        return 0, 0, {}
    end
    if not tableExists(tbl) then return 0, 0, {} end
    -- identifiers are fixed literals above, never user input
    local q = ('SELECT `%s` FROM `%s`'):format(table.concat(cols, '`, `'), tbl)
    local params = {}
    if owner then q = q .. (' WHERE `%s` = ?'):format(ownerCol); params[1] = owner end
    local rows = MySQL.query.await(q, params) or {}
    local out, skipped = {}, {}
    for _, r in ipairs(rows) do
        local m, why = Vehicles.MapFrameworkRow(framework, r)
        if m and m.owner then out[#out + 1] = m else skipped[why or 'no_owner'] = (skipped[why or 'no_owner'] or 0) + 1 end
    end
    return #rows, (#out > 0 and Vehicles.InsertBatch(out) or 0), skipped
end

---------------------------------------------------------------------------
-- Export for dealerships: exports.mdp_garages:AddVehicle(owner, plate, model, props?, garageId?)
-- Returns ok:boolean, err?:string ('invalid_owner'|'invalid_plate'|'invalid_model'|'invalid_props'|'plate_exists'|'db_error')
---------------------------------------------------------------------------
function Vehicles.AddVehicle(owner, plate, model, props, garageId)
    if type(owner) ~= 'string' or owner == '' or #owner > 64 then return false, 'invalid_owner' end
    plate = Utils.NormalizePlate(plate)
    if not Utils.IsValidPlate(plate) then return false, 'invalid_plate' end
    if type(model) ~= 'string' or not model:match('^[%w_]+$') or #model > 64 then return false, 'invalid_model' end
    local propsJson
    if props ~= nil then
        if type(props) == 'table' then propsJson = json.encode(props)
        elseif type(props) == 'string' then propsJson = props
        else return false, 'invalid_props' end
        if #propsJson > 65535 then return false, 'invalid_props' end
    end
    garageId = Utils.ResolveGarageId(garageId or Config.DefaultGarage, plate)
    local ok, affected = pcall(MySQL.update.await,
        'INSERT IGNORE INTO mdp_vehicles (plate, owner, model, props, state, garage_id) VALUES (?, ?, ?, ?, ?, ?)',
        { plate, owner, model, propsJson, VS.GARAGED, garageId })
    if not ok then return false, 'db_error' end
    if affected ~= 1 then return false, 'plate_exists' end
    return true
end
exports('AddVehicle', Vehicles.AddVehicle)

---------------------------------------------------------------------------
-- Sync on player load (per framework event)
---------------------------------------------------------------------------
local function syncPlayer(src)
    if not Config.SyncFrameworkTables or Bridge.Framework == 'standalone' then return end
    local ident = Bridge.GetIdentifier(src)
    if not ident then return end
    local read, inserted = Vehicles.ImportFromFramework(Bridge.Framework, ident)
    if inserted > 0 then
        print(('[mdp_garages] synced %d/%d framework vehicles for %s'):format(inserted, read, ident))
    end
end
Vehicles.SyncPlayer = syncPlayer

if Bridge.Framework == 'esx' then
    AddEventHandler('esx:playerLoaded', function(playerId) CreateThread(function() syncPlayer(playerId) end) end)
elseif Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
    AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
        local src = player and player.PlayerData and player.PlayerData.source
        if src then CreateThread(function() syncPlayer(src) end) end
    end)
end
