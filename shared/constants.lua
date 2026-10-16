-- Shared constants. Single global table `Constants`.
Constants = Constants or {}

-- mdp_vehicles.state (TINYINT)
Constants.VehicleState = {
    OUT = 0,          -- spawned / driven
    GARAGED = 1,      -- stored in a garage (garage_id)
    PARKED_WORLD = 2, -- physically parked in the world, respawned after restart
    IMPOUNDED = 3,    -- police impound / tow yard
    RETIRED = 4,      -- phase 7: auto-retired after Config.InactivityRetireHours; recoverable from phone app
}

-- mdp_fines.paid (TINYINT)
Constants.FineStatus = {
    UNPAID = 0,
    PAID = 1,
    CLAIMING = 2, -- internal payment in progress (reset to UNPAID on resource start)
    VOIDED = 3,   -- cancelled (e.g. /mdp_finereview <id> void, server/fine_review.lua by Integrations)
}

-- mdp_fines.channel
Constants.FineChannel = { INTERNAL = 'internal', INVOICE = 'invoice', NEEDS_REVIEW = 'needs_review', EXTERNAL = 'external' }

-- Vehicle types accepted by CreateVehicleServerSetter that garages handle
Constants.VehicleTypes = { automobile = true, bike = true, boat = true, heli = true, plane = true }

-- Schema version expected by this code (mdp_schema_version)
Constants.SchemaVersion = 2
