-- Phase 0 stub. Callbacks will be registered via Security.RegisterSecureCallback (server/security.lua).
CreateThread(function()
    local ok = pcall(function() return MySQL.scalar.await('SELECT 1') end)
    print(('[mdp_garages] server loaded, framework=%s, db=%s'):format(Bridge.Framework, ok and 'ok' or 'ERROR'))
end)
