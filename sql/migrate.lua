-- mdp_garages optional one-off migration: framework table of the DETECTED framework -> mdp_vehicles.
-- Never modifies originals (SELECT + batched INSERT IGNORE). Respects ESX stored/type/job (Config.Migration).
-- Opt-in: Config.Migration.Enabled = true (runs once on start) or restricted command `mdp_migrate`.
local function run(by)
    local fw = Bridge.Framework
    if fw == 'standalone' then
        print('^3[mdp_garages] migration skipped: no framework detected^0')
        return
    end
    local read, inserted, skipped, transferred = MDP.Vehicles.ImportFromFramework(fw)
    local parts = {}
    for why, n in pairs(skipped) do parts[#parts + 1] = why .. '=' .. n end
    print(('[mdp_garages] migration (%s, by %s): %d read, %d imported, %d owner changes, skipped: %s')
        :format(fw, by, read, inserted, transferred or 0, #parts > 0 and table.concat(parts, ', ') or 'none'))
end

RegisterCommand('mdp_migrate', function(src)
    if src ~= 0 and not IsPlayerAceAllowed(src, Config.Migration.Ace) then return end
    CreateThread(function() run(src == 0 and 'console' or ('player ' .. src)) end)
end, true)

if Config.Migration and Config.Migration.Enabled then
    CreateThread(function() Wait(2000); run('auto (Config.Migration.Enabled)') end)
end
