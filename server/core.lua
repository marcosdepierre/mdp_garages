-- Single server namespace for mdp_garages (the only new global besides Config/Bridge/Utils/Constants/Locales/Security).
MDP = MDP or {}
MDP.Ready = false -- set by server/persistence.lua once startup recovery has finished

--- Register a secure lib.callback that refuses with not_ready until startup recovery is done.
function MDP.Callback(name, opts, handler)
    return Security.RegisterSecureCallback(name, opts, function(src, data)
        if not MDP.Ready then return { ok = false, error = 'not_ready' } end
        return handler(src, data)
    end)
end

--- Model hash from a stored model: numeric strings/numbers (ESX stores hashes) are used as-is, names are joaat'd.
--- Kept server-side wrapper over Utils.ModelHash for readability.
MDP.ModelHash = function(model) return Utils.ModelHash(model) end
