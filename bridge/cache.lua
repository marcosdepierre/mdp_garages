-- Server-side identifier cache so Bridge.GetIdentifier keeps working inside playerDropped
-- (ESX/QB/Qbox remove the player object in their own playerDropped handlers; handler order is undefined).
-- Loaded after bridge/framework/*.lua. Entries live 35 s after drop (Security rate-limit carry is 30 s).
if not Bridge.IsServer then return end

local cache = {}   -- src -> identifier
local byIdent = {} -- identifier -> src (reverse map, R3-8)
local rawGetIdentifier = Bridge.GetIdentifier

function Bridge.GetIdentifier(src)
    src = tonumber(src)
    if not src then return nil end
    local ok, id = pcall(rawGetIdentifier, src)
    if ok and type(id) == 'string' and id ~= '' then
        cache[src] = id
        byIdent[id] = src
        return id
    end
    return cache[src]
end

local function remember(src) if src then Bridge.GetIdentifier(src) end end

if Bridge.Framework == 'esx' then
    AddEventHandler('esx:playerLoaded', function(playerId) remember(playerId) end)
elseif Bridge.Framework == 'qb' or Bridge.Framework == 'qbx' then
    AddEventHandler('QBCore:Server:PlayerLoaded', function(player)
        remember(player and player.PlayerData and player.PlayerData.source)
    end)
end

AddEventHandler('playerDropped', function()
    local src = source
    SetTimeout(35000, function()
        -- only clear if the slot was not reused by a new player meanwhile
        if GetPlayerName(src) == nil then
            local id = cache[src]
            cache[src] = nil
            if id and byIdent[id] == src then byIdent[id] = nil end
        end
    end)
end)

--- Online source for an identifier (O(1); verified against the live player), or nil.
function Bridge.GetSourceByIdentifier(ident)
    local src = ident and byIdent[ident]
    if src and GetPlayerName(src) ~= nil and cache[src] == ident then return src end
    return nil
end
