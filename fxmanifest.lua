fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'mdp_garages'
author 'mdp'
description 'Standalone garages for ESX / QBCore / Qbox'
version '0.0.1'

dependencies { 'oxmysql', 'ox_lib' }

shared_scripts {
    '@ox_lib/init.lua',
    'shared/config.lua',
    'shared/constants.lua',
    'shared/locale.lua',
    'shared/utils.lua',
    'locales/*.lua',
}

client_scripts {
    'bridge/init.lua',
    'bridge/framework/qbx.lua',
    'bridge/framework/qb.lua',
    'bridge/framework/esx.lua',
    'bridge/cache.lua',
    'bridge/notify/*.lua',
    'bridge/fuel/*.lua',
    'bridge/keys/*.lua',
    -- bridge/billing/*.lua is server-only (not sent to clients)
    'bridge/phone/*.lua',
    'client/main.lua',
    'client/props.lua',
    'client/zones.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/init.lua',
    'bridge/framework/qbx.lua',
    'bridge/framework/qb.lua',
    'bridge/framework/esx.lua',
    'bridge/cache.lua',
    'bridge/notify/*.lua',
    'bridge/fuel/*.lua',
    'bridge/keys/*.lua',
    'bridge/billing/*.lua',
    'bridge/phone/*.lua',
    'server/security.lua', -- written by Security Engineer
    'server/core.lua',
    'server/vehicles.lua',
    'server/persistence.lua',
    'server/props.lua',
    'server/streamer.lua',
    'server/garages.lua',
    'server/fines.lua',
    'server/fine_review*.lua', -- Integrations: /mdp_finereview (glob tolerates absence)
    'server/main.lua',
    'sql/migrate.lua', -- opt-in importer (Config.Migration)
}

ui_page 'web/dist/index.html'
files {
    'web/dist/index.html',
    'web/dist/**/*',
}
