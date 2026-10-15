fx_version 'cerulean'
game 'gta5'
lua54 'yes'

author 'SHOCKS'
description 'SHOCKS Drug Selling - zone-based NPC drug sales with Gang MDT turf activity and persistent reputation'
version '1.2.0'

shared_scripts {
    '@ox_lib/init.lua',
    'config.lua',
}

client_scripts {
    'client.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'server.lua',
}

dependencies {
    'qb-core',
    'ox_lib',
    'oxmysql',
}
