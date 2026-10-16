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

-- Schema version expected by this code (mdp_schema_version)
Constants.SchemaVersion = 1
