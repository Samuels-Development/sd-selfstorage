fx_version 'cerulean'
game 'gta5'

name "Self Storage"
author "Made with love by Samuel#0008"
version "1.0.2"

client_scripts {
    'bridge/client.lua',
    'client/*.lua'
}

shared_scripts {
    '@ox_lib/init.lua',
    'bridge/init.lua',
    'bridge/shared.lua',
    'config.lua'
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'bridge/server.lua', 
    'server/*.lua'
}

files {
    'locales/*.json'
}

lua54 'yes'
