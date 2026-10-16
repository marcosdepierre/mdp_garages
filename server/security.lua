--[[
    mdp_garages - server/security.lua
    Módulo de seguridad reutilizable (Lua 5.4, lado servidor FiveM).
    Ver docs/security.md para las reglas obligatorias.

    API de Bridge esperada (la provee bridge/*.lua):
      Bridge.GetIdentifier(source) -> string|nil   -- license/citizenid/identifier del framework
      Bridge.GetJob(source) -> { name = string, grade = integer, onDuty|onduty = boolean? }|nil
      Bridge.GetMoney(source, account) -> number             (account: 'cash'|'bank')
      Bridge.RemoveMoney(source, account, amount, reason) -> boolean
      Bridge.Notify(source, msg, type)                       (opcional)

    Requiere '@oxmysql/lib/MySQL.lua', '@ox_lib/init.lua' y shared/utils.lua (Utils) cargados antes.
]]

Security = Security or {}

---------------------------------------------------------------------------
-- Configuración (sobrescribible desde shared/config.lua vía Config.Security)
---------------------------------------------------------------------------
local cfgSrc = (type(Config) == 'table' and type(Config.Security) == 'table') and Config.Security or {}

Security.Config = {
    -- Sigue Config.Debug salvo que Config.Security.debug se fije explícitamente.
    debug             = (cfgSrc.debug ~= nil) and (cfgSrc.debug == true)
                        or (type(Config) == 'table' and Config.Debug == true),
    resourceName      = GetCurrentResourceName(),
    ownedTable        = cfgSrc.ownedTable or 'mdp_vehicles', -- Config.Security.ownedTable si existe
    plateColumn       = cfgSrc.plateColumn or 'plate',
    ownerColumn       = cfgSrc.ownerColumn or 'owner',
    keysTable         = cfgSrc.keysTable or 'mdp_vehicle_keys',
    allowKeyHolders   = cfgSrc.allowKeyHolders ~= false, -- OWN incluye titulares de llaves
    defaultRateLimit  = cfgSrc.defaultRateLimit or { max = 5, windowMs = 2000 },
    lockTimeoutMs     = cfgSrc.lockTimeoutMs or 10000,
    flagThreshold     = cfgSrc.flagThreshold or 20, -- rechazos antes de disparar OnSuspicious
    despawnOnDropMs   = cfgSrc.despawnOnDropMs,       -- nil = no hacer nada con vehículos al desconectar
    rateCarryMs       = cfgSrc.rateCarryMs or 30000,  -- cooldown por identificador al reconectar (0/false = off)
}

-- Whitelist de tablas/columnas permitidas para identificadores dinámicos en SQL.
local SQL_IDENT_WHITELIST = {
    mdp_vehicles = true, mdp_vehicle_keys = true, holder = true,
    plate = true, owner = true, state = true, garage_id = true,
}

---------------------------------------------------------------------------
-- Logging y hooks preparados para anticheat/ban
---------------------------------------------------------------------------
local rejectCount = {} ---@type table<integer, integer>

--- Hook sobrescribible: integrar aquí Discord webhook / anticheat / ban.
--- NO banear automáticamente por defecto: los falsos positivos (lag) existen.
---@param src integer
---@param reason string
---@param data table
function Security.OnSuspicious(src, reason, data) end

---@param src integer
---@param event string
---@param reason string
---@param extra table|nil
function Security.LogReject(src, event, reason, extra)
    rejectCount[src] = (rejectCount[src] or 0) + 1
    local ident = (Bridge and Bridge.GetIdentifier) and Bridge.GetIdentifier(src) or 'unknown'
    print(('[%s][SECURITY] rechazo src=%s id=%s evento=%s motivo=%s'):format(
        Security.Config.resourceName, tostring(src), tostring(ident), event, reason))
    if rejectCount[src] == Security.Config.flagThreshold then
        Security.OnSuspicious(src, 'too_many_rejects', { event = event, reason = reason, extra = extra, identifier = ident })
    end
end

---------------------------------------------------------------------------
-- Validadores
---------------------------------------------------------------------------
Security.V = {}
local V = Security.V

--- Matrícula: regla única en Utils.IsValidPlate (longitud = Config.PlateMaxLength, por defecto 8).
--- Aquí no hay longitudes fijas: todo se delega en Utils.
--- Delegado en shared/utils.lua para que cliente y servidor usen la misma regla.
function V.isPlate(v) return Utils.IsValidPlate(v) end

--- Normaliza matrícula (trim + mayúsculas). nil si no es string.
function V.normalizePlate(v) return Utils.NormalizePlate(v) end

--- garage_id con formato public|private|impound:<id>.
function V.isGarageId(v) return Utils.IsValidGarageId(v) end

function V.isInt(v, min, max)
    if math.type(v) ~= 'integer' then
        if type(v) ~= 'number' or v ~= v or v % 1 ~= 0 then return false end
    end
    if min and v < min then return false end
    if max and v > max then return false end
    return true
end

function V.isString(v, maxLen, pattern)
    if type(v) ~= 'string' then return false end
    if maxLen and #v > maxLen then return false end
    if pattern and not v:match(pattern) then return false end
    return true
end

--- Identificador genérico [%w_-] hasta 32 (NO usar para garage_id: usar V.isGarageId).
function V.isId(v) return V.isString(v, 32, '^[%w_%-]+$') end

function V.isBool(v) return type(v) == 'boolean' end

function V.clamp(n, min, max)
    n = tonumber(n) or min
    if n < min then return min elseif n > max then return max end
    return n
end

--- Elimina HTML, caracteres de control y recorta longitud.
function V.sanitizeString(v, maxLen)
    if type(v) ~= 'string' then return '' end
    v = v:gsub('<[^>]*>', ''):gsub('[<>"\'`&]', ''):gsub('%c', '')
    v = v:gsub('^%s+', ''):gsub('%s+$', '')
    maxLen = maxLen or 64
    if #v > maxLen then v = v:sub(1, maxLen) end
    return v
end

-- Fábricas cómodas para schemas
function Security.Int(min, max) return function(v) return V.isInt(v, min, max) end end
function Security.Str(maxLen, pattern) return function(v) return V.isString(v, maxLen, pattern) end end
function Security.Optional(fn) return function(v) return v == nil or fn(v) end end

local TYPE_VALIDATORS = {
    plate = V.isPlate, garage = V.isGarageId, int = function(v) return V.isInt(v) end, id = V.isId,
    string = function(v) return V.isString(v, 255) end, boolean = V.isBool,
    number = function(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end,
}

--- Valida payload contra schema. Rechaza campos desconocidos.
---@return boolean ok, string|nil err
function Security.ValidateSchema(data, schema)
    if schema == nil then return true end
    if type(data) ~= 'table' then return false, 'payload_not_table' end
    for k in pairs(data) do
        if schema[k] == nil then return false, 'unknown_field:' .. tostring(k) end
    end
    for field, rule in pairs(schema) do
        local fn = type(rule) == 'function' and rule or TYPE_VALIDATORS[rule]
        if not fn then return false, 'bad_schema_rule:' .. field end
        if not fn(data[field]) then return false, 'invalid_field:' .. field end
    end
    if data.plate ~= nil then data.plate = V.normalizePlate(data.plate) end
    return true
end

---------------------------------------------------------------------------
-- Rate limiting por jugador y evento (ventana deslizante)
---------------------------------------------------------------------------
local buckets = {} ---@type table<integer, table<string, number[]>>

---@return boolean allowed
local carry = {} ---@type table<string, {at: integer, buckets: table}>

function Security.RateLimit(src, key, max, windowMs)
    local now = GetGameTimer()
    local pb = buckets[src]
    if not pb then
        pb = {}
        -- Reconexión: recuperar buckets guardados por identificador (si no expiraron)
        local ident = Bridge and Bridge.GetIdentifier and Bridge.GetIdentifier(src)
        local c = ident and carry[ident]
        if c then
            carry[ident] = nil
            if (now - c.at) < (Security.Config.rateCarryMs or 0) then pb = c.buckets end
        end
        buckets[src] = pb
    end
    local list = pb[key]
    if not list then list = {}; pb[key] = list end
    local cutoff, j = now - windowMs, 0
    for i = 1, #list do
        if list[i] > cutoff then j = j + 1; list[j] = list[i] end
    end
    for i = #list, j + 1, -1 do list[i] = nil end
    if j >= max then return false end
    list[j + 1] = now
    return true
end

---------------------------------------------------------------------------
-- Locks por matrícula (anti-duplicación / anti doble spawn)
---------------------------------------------------------------------------
local plateLocks = {} ---@type table<string, {src: integer, at: integer, token: string}>
local lockSeq = 0

local function newToken(src)
    lockSeq = lockSeq + 1
    return ('%d:%d:%d'):format(src or 0, GetGameTimer(), lockSeq)
end

--- Toma el lock de una matrícula (o clave, p.ej. 'fine:<id>').
--- Un lock caducado (> lockTimeoutMs) se reemplaza con un token nuevo.
---@param plate string
---@param src integer|nil   0 = servidor
---@return string|false token
function Security.Lock(plate, src)
    plate = V.normalizePlate(plate)
    if not plate then return false end
    local now, l = GetGameTimer(), plateLocks[plate]
    if l and (now - l.at) < Security.Config.lockTimeoutMs then return false end
    if l and Security.Config.debug then
        print(('[%s][SECURITY] lock caducado de %s (src=%s) reemplazado'):format(
            Security.Config.resourceName, plate, tostring(l.src)))
    end
    local token = newToken(src)
    plateLocks[plate] = { src = src or 0, at = now, token = token }
    return token
end

--- Libera el lock solo si el token coincide; si no, devuelve false (log solo en debug).
---@param plate string
---@param token string
---@return boolean
function Security.Unlock(plate, token)
    plate = V.normalizePlate(plate)
    local l = plate and plateLocks[plate]
    if not l then return false end
    if token == nil or l.token ~= token then
        -- Tras un takeover legítimo (lock caducado) esto es normal: solo se registra en debug.
        if Security.Config.debug then
            print(('[%s][SECURITY] Unlock ignorado: token no coincide (clave=%s, dueño src=%s)'):format(
                Security.Config.resourceName, tostring(plate), tostring(l.src)))
        end
        return false
    end
    plateLocks[plate] = nil
    return true
end

function Security.IsLocked(plate)
    plate = V.normalizePlate(plate)
    local l = plate and plateLocks[plate]
    return l ~= nil and l ~= false and (GetGameTimer() - l.at) < Security.Config.lockTimeoutMs
end

--- Ejecuta fn con el lock tomado y lo libera siempre (incluso si fn falla).
--- El token se gestiona internamente; si el lock caducó y otro lo tomó, no se libera el ajeno.
function Security.WithLock(plate, src, fn, ...)
    local token = Security.Lock(plate, src)
    if not token then return false, 'locked' end
    local res = table.pack(pcall(fn, ...))
    Security.Unlock(plate, token)
    if not res[1] then error(res[2], 0) end
    return table.unpack(res, 2, res.n)
end

---------------------------------------------------------------------------
-- Seguimiento de vehículos spawneados (plate -> netId)
---------------------------------------------------------------------------
local spawned = {} ---@type table<string, {netId: integer, src: integer}>

---@param plate string
---@param netId integer
---@param src integer|nil
function Security.TrackSpawn(plate, netId, src)
    plate = V.normalizePlate(plate)
    if not plate or math.type(netId) ~= 'integer' then return false end
    spawned[plate] = { netId = netId, src = src }
    return true
end

function Security.UntrackSpawn(plate)
    plate = V.normalizePlate(plate)
    if plate then spawned[plate] = nil end
end

--- Devuelve la entidad si el vehículo de esa matrícula sigue existiendo.
function Security.GetSpawnedEntity(plate)
    plate = V.normalizePlate(plate)
    local s = plate and spawned[plate]
    if not s then return nil end
    local ent = NetworkGetEntityFromNetworkId(s.netId)
    if ent ~= 0 and DoesEntityExist(ent) then return ent, s.netId end
    spawned[plate] = nil
    return nil
end

--- Resuelve la matrícula de un vehículo en servidor a partir de su netId.
---@param netId integer
---@return string|nil plate, string|nil err
function Security.PlateFromNetId(netId)
    if math.type(netId) ~= 'integer' or netId <= 0 then return nil, 'bad_netid' end
    local ent = NetworkGetEntityFromNetworkId(netId)
    if not ent or ent == 0 or not DoesEntityExist(ent) then return nil, 'no_entity' end
    if GetEntityType(ent) ~= 2 then return nil, 'not_vehicle' end
    local plate = V.normalizePlate(GetVehicleNumberPlateText(ent))
    if not V.isPlate(plate) then return nil, 'bad_plate' end
    return plate, nil, ent
end

---------------------------------------------------------------------------
-- Saneado de propiedades de vehículo (props de lib.getVehicleProperties enviadas por el cliente)
---------------------------------------------------------------------------
Security.Props = {
    maxBytes = 16384,   -- tamaño máximo del JSON resultante
    maxDepth = 3,       -- profundidad máxima de tablas anidadas
    maxTableItems = 64, -- elementos máximos por tabla anidada
}

--- Convenciones GTA: motor -4000..1000, carrocería 0..1000, depósito -1000..1000, suciedad 0..15, fuel 0..100.
local HEALTH = {
    engine = { -4000.0, 1000.0 }, body = { 0.0, 1000.0 }, tank = { -1000.0, 1000.0 },
}
Security.Health = HEALTH

--- Clamp de salud para guardar en BD (usar en UPDATE engine/body).
function Security.ClampHealth(kind, v)
    local r = HEALTH[kind]; if not r then return nil end
    v = tonumber(v)
    if not v or v ~= v then return r[2] end
    return V.clamp(v, r[1], r[2])
end

local function num(min, max, int)
    return function(v)
        if type(v) ~= 'number' or v ~= v or v == math.huge or v == -math.huge then return nil end
        if int then
            if v % 1 ~= 0 then return nil end
            v = math.tointeger(v) or v
        end
        -- enteros fuera de rango -> descartar; decimales -> clamp
        if v < min then if int then return nil end return min end
        if v > max then if int then return nil end return max end
        return v
    end
end
local function bool(v) if type(v) == 'boolean' then return v end return nil end
local function rgb(v)
    if type(v) ~= 'table' then return nil end
    local r, g, b = num(0, 255, true)(v[1]), num(0, 255, true)(v[2]), num(0, 255, true)(v[3])
    if not (r and g and b) then return nil end
    return { r, g, b }
end
local function colorOrRgb(v) if type(v) == 'table' then return rgb(v) end return num(0, 255, true)(v) end
--- Lista/mapa con claves enteras acotadas y valores validados.
local function intMap(maxKey, valueFn)
    return function(v)
        if type(v) ~= 'table' then return nil end
        local out, n = {}, 0
        for k, val in pairs(v) do
            local key = tonumber(k)
            if not key or key % 1 ~= 0 or key < 0 or key > maxKey then return nil end
            local cv = valueFn(val)
            if cv == nil then return nil end
            n = n + 1
            if n > Security.Props.maxTableItems then return nil end
            out[math.tointeger(key)] = cv
        end
        return out
    end
end
local function extraVal(v)
    if type(v) == 'boolean' then return v and 1 or 0 end
    return num(0, 1, true)(v)
end
local function anyBoolOrInt(v) if type(v) == 'boolean' then return v end return num(-1, 255, true)(v) end
local modIdx = num(-1, 255, true)

-- Whitelist de campos (ox_lib getVehicleProperties). Lo que no esté aquí se descarta.
local PROP_RULES = {
    plateIndex = num(0, 5, true),
    bodyHealth = num(HEALTH.body[1], HEALTH.body[2]),
    engineHealth = num(HEALTH.engine[1], HEALTH.engine[2]),
    tankHealth = num(HEALTH.tank[1], HEALTH.tank[2]),
    fuelLevel = num(0, 100), oilLevel = num(0, 100), dirtLevel = num(0, 15),
    paintType1 = num(0, 9, true), paintType2 = num(0, 9, true),
    color1 = colorOrRgb, color2 = colorOrRgb,
    pearlescentColor = num(0, 255, true), interiorColor = num(0, 255, true), dashboardColor = num(0, 255, true),
    wheelColor = num(0, 255, true), wheelWidth = num(0, 10), wheelSize = num(0, 10),
    wheels = num(0, 12, true), windowTint = num(-1, 6, true), xenonColor = num(-1, 255, true),
    neonEnabled = intMap(4, bool), neonColor = rgb, tyreSmokeColor = rgb,
    extras = intMap(20, extraVal), -- índices 0..20 (con [99] -> se descarta la tabla entera),
    windows = intMap(14, anyBoolOrInt), doors = intMap(8, anyBoolOrInt), tyres = intMap(48, anyBoolOrInt),
    bulletProofTyres = bool, driftTyres = bool,
    modTurbo = bool, modSmokeEnabled = bool, modXenon = bool, modCustomTiresF = bool, modCustomTiresR = bool,
    modLivery = modIdx, modRoofLivery = modIdx,
}
for _, m in ipairs({ 'modSpoilers', 'modFrontBumper', 'modRearBumper', 'modSideSkirt', 'modExhaust', 'modFrame',
    'modGrille', 'modHood', 'modFender', 'modRightFender', 'modRoof', 'modEngine', 'modBrakes', 'modTransmission',
    'modHorns', 'modSuspension', 'modArmor', 'modNitrous', 'modSubwoofer', 'modHydraulics', 'modFrontWheels',
    'modBackWheels', 'modPlateHolder', 'modVanityPlate', 'modTrimA', 'modOrnaments', 'modDashboard', 'modDial',
    'modDoorSpeaker', 'modSeats', 'modSteeringWheel', 'modShifterLeavers', 'modAPlate', 'modSpeakers', 'modTrunk',
    'modHydrolic', 'modEngineBlock', 'modAirFilter', 'modStruts', 'modArchCover', 'modAerials', 'modTrimB',
    'modTank', 'modWindows', 'modDoorR', 'modLightbar' }) do
    PROP_RULES[m] = modIdx
end
Security.PropRules = PROP_RULES

--- Campos que puede actualizar un snapshot de props de un cliente que NO es dueño ni tiene llave
--- (dueño de red cercano al despawn): solo estado/daños, nunca estética ni mods.
Security.PropSnapshotFields = {
    bodyHealth = true, engineHealth = true, tankHealth = true, dirtLevel = true, fuelLevel = true,
    oilLevel = true, windows = true, doors = true, tyres = true,
}

--- Kilometraje plausible.
--- * newKm < oldKm, no numérico o NaN -> oldKm (clamped = true si newKm venía y era inválido/menor).
--- * permitido = max(0, elapsedSec) * Config.MaxSpeedKmh (400) / 3600 + Config.MileageMarginKm (0.5),
---   con tope Config.MaxMileageDeltaKm (50). Si se supera -> oldKm + permitido, LogReject/debug.
---@param plate string|nil  solo para el log
---@param oldKm number
---@param newKm number
---@param elapsedSec number
---@return number km, boolean clamped
function Security.ClampMileage(plate, oldKm, newKm, elapsedSec)
    local function finite(v) return type(v) == 'number' and v == v and v ~= math.huge and v ~= -math.huge end
    oldKm = tonumber(oldKm); if not finite(oldKm) or oldKm < 0 then oldKm = 0.0 end
    newKm = tonumber(newKm)
    if not finite(newKm) then return oldKm, true end
    if newKm < oldKm then return oldKm, true end
    local el = tonumber(elapsedSec); if not finite(el) or el < 0 then el = 0 end
    local C = type(Config) == 'table' and Config or {}
    local allowed = el * (tonumber(C.MaxSpeedKmh) or 400) / 3600 + (tonumber(C.MileageMarginKm) or 0.5)
    local cap = tonumber(C.MaxMileageDeltaKm) or 50
    if allowed > cap then allowed = cap end
    if newKm - oldKm > allowed then
        local msg = ('mileage +%.2f km en %ds (permitido %.2f) plate=%s'):format(newKm - oldKm, el, allowed, tostring(plate))
        if Security.Config.debug then print(('[%s][SECURITY] %s'):format(Security.Config.resourceName, msg)) end
        return oldKm + allowed, true
    end
    return newKm, false
end

local function depthOk(t, d)
    if d > Security.Props.maxDepth then return false end
    for _, v in pairs(t) do
        if type(v) == 'table' and not depthOk(v, d + 1) then return false end
    end
    return true
end

--- Sanea props del cliente antes de guardarlas.
--- * Solo campos de PROP_RULES; campos desconocidos o fuera de rango se DESCARTAN (no rechazan).
--- * model: debe coincidir con dbRow.model (hash) y, si se pasa entity, con GetEntityModel(entity). Si no -> rechazo.
--- * plate: se sustituye SIEMPRE por la del servidor (dbRow.plate).
--- * mileage (si viene): nunca por debajo del valor de BD -> se conserva el de BD (no se rechaza).
---   Con elapsedSec (s desde la última actualización de km) se aplica además Security.ClampMileage.
--- * Profundidad > maxDepth o JSON > maxBytes -> rechazo.
---@param props table
---@param dbRow {plate: string, model: string|integer, mileage: number|nil}
---@param entity integer|nil
---@param elapsedSec number|nil
---@return table|nil clean, string|nil err
function Security.SanitizeProps(props, dbRow, entity, elapsedSec)
    if type(props) ~= 'table' then return nil, 'props_not_table' end
    if type(dbRow) ~= 'table' or not dbRow.plate or dbRow.model == nil then return nil, 'no_db_row' end
    if not depthOk(props, 1) then return nil, 'props_too_deep' end
    local dbHash = Utils.ModelHash(dbRow.model)
    if math.type(dbHash) ~= 'integer' then return nil, 'bad_db_model' end
    local m = props.model
    if type(m) == 'string' then m = Utils.ModelHash(m) end
    if math.type(m) == 'float' then m = math.tointeger(m) end
    -- GTA puede devolver el hash con signo o sin signo: comparar en 32 bits
    local function u32(h) return h and (h & 0xFFFFFFFF) or nil end
    if math.type(m) ~= 'integer' or u32(m) ~= u32(dbHash) then return nil, 'model_mismatch' end
    if entity ~= nil then
        if not DoesEntityExist(entity) or u32(GetEntityModel(entity)) ~= u32(dbHash) then return nil, 'entity_model_mismatch' end
    end
    local clean, dropped = { model = dbHash, plate = V.normalizePlate(dbRow.plate) }, 0
    for k, v in pairs(props) do
        if k ~= 'model' and k ~= 'plate' then
            local rule = type(k) == 'string' and PROP_RULES[k]
            local cv = rule and rule(v)
            if cv ~= nil then clean[k] = cv else dropped = dropped + 1 end
        end
    end
    if props.mileage ~= nil then
        local old = tonumber(dbRow.mileage) or 0
        local new = tonumber(props.mileage)
        if elapsedSec ~= nil then
            clean.mileage = Security.ClampMileage(dbRow.plate, old, new, elapsedSec)
        else
            clean.mileage = (new and new == new and new >= old and new < 1e9) and new or old
        end
    end
    local okE, encoded = pcall(json.encode, clean)
    if not okE or type(encoded) ~= 'string' then return nil, 'props_encode' end
    if #encoded > Security.Props.maxBytes then return nil, 'props_too_large' end
    if dropped > 0 and Security.Config.debug then
        print(('[%s][SECURITY] SanitizeProps %s: %d campos descartados'):format(Security.Config.resourceName, clean.plate, dropped))
    end
    return clean, nil, encoded
end

---------------------------------------------------------------------------
-- SQL seguro
---------------------------------------------------------------------------
--- Devuelve el identificador SQL si está en la whitelist; error si no.
function Security.SqlIdent(name)
    if type(name) ~= 'string' or not SQL_IDENT_WHITELIST[name] then
        error(('identificador SQL no permitido: %s'):format(tostring(name)), 2)
    end
    return '`' .. name .. '`'
end

--- Comprueba propiedad por matrícula + identificador (Bridge.GetIdentifier), SQL parametrizado.
--- Acepta también titulares de llaves (mdp_vehicle_keys.plate/holder) salvo allowKeys == false
--- o Config.Security.allowKeyHolders == false.
---@param src integer
---@param plate string
---@param allowKeys boolean|nil
---@return boolean isOwner, string|nil via  -- via = 'owner' | 'key'
function Security.IsOwner(src, plate, allowKeys)
    if not (Bridge and Bridge.GetIdentifier) then return false end
    local ident = Bridge.GetIdentifier(src)
    if type(ident) ~= 'string' or ident == '' or not V.isPlate(plate) then return false end
    plate = V.normalizePlate(plate)
    local c = Security.Config
    local q = ('SELECT 1 FROM %s WHERE %s = ? AND %s = ? LIMIT 1'):format(
        Security.SqlIdent(c.ownedTable), Security.SqlIdent(c.plateColumn), Security.SqlIdent(c.ownerColumn))
    if MySQL.scalar.await(q, { plate, ident }) ~= nil then return true, 'owner' end
    if allowKeys == false or not c.allowKeyHolders then return false end
    return Security.IsKeyHolder(src, plate, ident), 'key'
end

--- Titular de llave: mdp_vehicle_keys (plate, holder), con FK a mdp_vehicles.plate.
function Security.IsKeyHolder(src, plate, ident)
    ident = ident or (Bridge and Bridge.GetIdentifier and Bridge.GetIdentifier(src))
    if type(ident) ~= 'string' or ident == '' or not V.isPlate(plate) then return false end
    local q = ('SELECT 1 FROM %s WHERE `plate` = ? AND `holder` = ? LIMIT 1'):format(
        Security.SqlIdent(Security.Config.keysTable))
    return MySQL.scalar.await(q, { V.normalizePlate(plate), ident }) ~= nil
end

---------------------------------------------------------------------------
-- Comprobaciones de trabajo y distancia
---------------------------------------------------------------------------
---@param src integer
---@param job {names: string[]|table<string,boolean>, minGrade: integer|nil, requireDuty: boolean|nil}
---@return boolean
function Security.HasJob(src, job)
    if not (Bridge and Bridge.GetJob) then return false end
    local pj = Bridge.GetJob(src)
    if not pj or not pj.name then return false end
    local allowed = false
    for k, v in pairs(job.names or {}) do
        if v == pj.name or (k == pj.name and v == true) then allowed = true break end
    end
    if not allowed then return false end
    -- Bridge puede devolver onDuty u onduty. Por defecto se exige estar de servicio
    -- (architecture.md); job.requireDuty = false lo desactiva.
    local duty = pj.onDuty
    if duty == nil then duty = pj.onduty end
    if job.requireDuty ~= false and duty == false then return false end
    return (tonumber(pj.grade) or 0) >= (job.minGrade or 0)
end

---@param src integer
---@param coords vector3|{x:number,y:number,z:number}  -- SIEMPRE de config/entidad del servidor
---@param max number
---@return boolean
function Security.IsNear(src, coords, max)
    local ped = GetPlayerPed(src)
    if not ped or ped == 0 or not coords or type(max) ~= 'number' then return false end
    local p = GetEntityCoords(ped)
    local dx, dy, dz = p.x - coords.x, p.y - coords.y, p.z - coords.z
    return (dx * dx + dy * dy + dz * dz) <= (max * max)
end

---------------------------------------------------------------------------
-- Pipeline común de validación
---------------------------------------------------------------------------
--- Convierte argumentos posicionales (p.ej. `plate, garageId`) en tabla según opts.args.
local function packArgs(opts, ...)
    if opts.args then
        local t, a = {}, table.pack(...)
        for i, k in ipairs(opts.args) do t[k] = a[i] end
        if a.n > #opts.args then t.__extra = true end -- argumentos sobrantes => rechazo por schema
        return t
    end
    return (...)
end
Security.PackArgs = packArgs

--- Orden: source → rate limit → schema → resolvePlate → job → distancia → propiedad (BD).
local function runChecks(name, src, opts, data)
    if type(data) == 'table' then data._plate = nil end -- nunca aceptar _plate del cliente
    src = tonumber(src)
    if not src or src <= 0 or GetPlayerName(src) == nil then return false, 'invalid_source' end
    local rl = opts.rateLimit or Security.Config.defaultRateLimit
    if rl ~= false and not Security.RateLimit(src, name, rl.max, rl.windowMs) then
        return false, 'rate_limited'
    end
    local ok, err = Security.ValidateSchema(data, opts.schema)
    if not ok then return false, err end
    -- opts.resolvePlate(src, data) -> plate|nil, err: la matrícula se obtiene en SERVIDOR
    -- (p.ej. desde netId con Security.PlateFromNetId) y se guarda en data._plate.
    if opts.resolvePlate then
        if type(data) ~= 'table' then return false, 'payload_not_table' end
        local okR, plate, rerr = pcall(opts.resolvePlate, src, data)
        if not okR then return false, 'resolve_error' end
        plate = plate and V.normalizePlate(plate)
        if not plate or not V.isPlate(plate) then return false, 'plate_unresolved:' .. tostring(rerr or 'nil') end
        data._plate = plate
    end
    if opts.job and not Security.HasJob(src, opts.job) then return false, 'job_denied' end
    if opts.distance then
        -- getCoords(src, data) debe resolver coords DESDE CONFIG/servidor, nunca desde data.coords
        local c = opts.distance.getCoords(src, data)
        if not c or not Security.IsNear(src, c, opts.distance.max or 10.0) then
            return false, 'too_far'
        end
    end
    -- La propiedad (consulta a BD) va al final: es la comprobación más cara.
    if opts.requireOwnership then
        local plate = (type(data) == 'table') and (data._plate or data.plate) or nil
        if not V.isPlate(plate) then return false, 'no_plate' end
        if not Security.IsOwner(src, plate) then return false, 'not_owner' end
    end
    return true
end

---------------------------------------------------------------------------
-- Registro de eventos seguros
---------------------------------------------------------------------------
---@param name string
---@param opts table {args={'plate','garageId'}?, rateLimit={max,windowMs}|false, schema={campo=tipo|validador}, distance={getCoords=fn,max=n}, job={names,minGrade}, requireOwnership=bool, resolvePlate=fn(src,data)->plate|nil,err}
---@param handler fun(src: integer, data: table)
function Security.RegisterSecureEvent(name, opts, handler)
    opts = opts or {}
    RegisterNetEvent(name, function(...)
        local src = source
        local data = packArgs(opts, ...)
        local ok, err = runChecks(name, src, opts, data)
        if not ok then
            Security.LogReject(src, name, err, Security.Config.debug and { data = data } or nil)
            return
        end
        local okH, errH = pcall(handler, src, data)
        if not okH then
            print(('[%s][SECURITY] error en handler %s: %s'):format(Security.Config.resourceName, name, tostring(errH)))
        end
    end)
end

--- Callback seguro sobre ox_lib lib.callback.register (sin fallback por eventos, ver architecture.md).
--- El handler devuelve la respuesta.
---@param name string
---@param opts table  (mismas opciones que RegisterSecureEvent)
---@param handler fun(src: integer, data: table): ...
--- Si se rechaza, devuelve (false, motivo) al cliente.
function Security.RegisterSecureCallback(name, opts, handler)
    opts = opts or {}
    if not (lib and lib.callback and lib.callback.register) then
        print(('[%s][SECURITY] ox_lib no disponible (dependencia obligatoria); callback %s no registrado'):format(Security.Config.resourceName, name))
        return false
    end
    lib.callback.register(name, function(src, ...)
        local data = packArgs(opts, ...)
        local ok, err = runChecks(name, src, opts, data)
        if not ok then
            Security.LogReject(src, name, err, Security.Config.debug and { data = data } or nil)
            return false, err
        end
        local res = table.pack(pcall(handler, src, data))
        if not res[1] then
            print(('[%s][SECURITY] error en callback %s: %s'):format(Security.Config.resourceName, name, tostring(res[2])))
            return false, 'internal_error'
        end
        return table.unpack(res, 2, res.n)
    end)
    return true
end

---------------------------------------------------------------------------
-- Limpieza
---------------------------------------------------------------------------
--- Hook sobrescribible: se llama tras la limpieza interna.
---@param src integer
---@param identifier string|nil
---@param plates string[]  matrículas trackeadas cuyo dueño era src (ahora src = nil)
---@param reason string|nil
function Security.OnPlayerDropped(src, identifier, plates, reason) end

--- Hook sobrescribible: se llama tras Config.Security.despawnOnDropMs si el vehículo sigue
--- existiendo y nadie lo reclamó. server/persistence.lua decide (guardar en garaje / borrar).
---@param plate string
---@param netId integer
---@param identifier string|nil
function Security.OnDroppedVehicleTimeout(plate, netId, identifier) end

AddEventHandler('playerDropped', function(reason)
    local src = source
    local ident = Bridge and Bridge.GetIdentifier and Bridge.GetIdentifier(src) or nil
    local now = GetGameTimer()
    -- 1) rate limit y contadores (con cooldown por identificador)
    if ident and buckets[src] and (Security.Config.rateCarryMs or 0) > 0 then
        carry[ident] = { at = now, buckets = buckets[src] }
    end
    buckets[src] = nil
    rejectCount[src] = nil
    for id, c in pairs(carry) do
        if (now - c.at) >= (Security.Config.rateCarryMs or 0) then carry[id] = nil end
    end
    -- 2) solo los locks de este src
    for plate, l in pairs(plateLocks) do
        if l.src == src then Security.Unlock(plate, l.token) end
    end
    -- 3) spawn tracking: se mantiene, dueño src -> nil
    local plates = {}
    for plate, sp in pairs(spawned) do
        if sp.src == src then
            sp.src = nil
            sp.droppedIdent = ident
            sp.droppedAt = now
            plates[#plates + 1] = plate
        end
    end
    local delay = Security.Config.despawnOnDropMs
    if delay and delay > 0 and #plates > 0 then
        SetTimeout(delay, function()
            for _, plate in ipairs(plates) do
                local sp = spawned[plate]
                -- solo si nadie lo reclamó (src sigue nil) y la entidad existe
                if sp and sp.src == nil and sp.droppedAt == now then
                    local ent, netId = Security.GetSpawnedEntity(plate)
                    if ent then pcall(Security.OnDroppedVehicleTimeout, plate, netId, ident) end
                end
            end
        end)
    end
    pcall(Security.OnPlayerDropped, src, ident, plates, reason)
end)

--- Reasignar un vehículo trackeado a un jugador (p.ej. al reconectar el dueño).
function Security.ClaimSpawn(plate, src)
    plate = V.normalizePlate(plate)
    local sp = plate and spawned[plate]
    if not sp then return false end
    sp.src, sp.droppedIdent, sp.droppedAt = src, nil, nil
    return true
end

return Security
