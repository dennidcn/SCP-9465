-- dRitual main initialization file

if not DRITUAL then DRITUAL = {} end

-- Load shared files
include("dritual/sh_theme.lua")
include("dritual/sh_utils.lua")
include("dritual/sh_registry.lua")
include("dritual/sh_init.lua")
include("dritual/sh_npc_setup.lua")

-- Load client files
if CLIENT then
    include("dritual/client/cl_menu.lua")
end

-- Load server files
if SERVER then
    include("dritual/client/cl_menu.lua")
    AddCSLuaFile("dritual/client/cl_menu.lua")
end
