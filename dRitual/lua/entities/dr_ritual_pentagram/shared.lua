AddCSLuaFile()

ENT.Type = "anim"
ENT.Base = "base_anim"
ENT.PrintName = "Ritual Pentagram"
ENT.Author = "Dennid"
ENT.Information = "Interact to begin a ritual and sacrifice requested items."
ENT.Category = "dRitual"
ENT.Spawnable = true
ENT.AdminOnly = false
ENT.RenderGroup = RENDERGROUP_TRANSLUCENT

CreateConVar("dr_ritual_time", "120", FCVAR_ARCHIVE, "Time limit to complete a ritual after channeling.")
CreateConVar("dr_ritual_channel_time", "3", FCVAR_ARCHIVE, "Channeling time before the ritual starts.")
CreateConVar("dr_ritual_item_count", "3", FCVAR_ARCHIVE, "How many items are required for a ritual.")
CreateConVar("dr_ritual_material", "pentagram/pentagram", FCVAR_ARCHIVE, "Material path for the pentagram")
CreateConVar("dr_ritual_size", "256", FCVAR_ARCHIVE, "Pentagram half-size in Hammer units")
CreateConVar("dr_ritual_zoffset", "0.2", FCVAR_ARCHIVE, "Vertical offset from the surface to avoid z-fighting.")
CreateConVar("dr_ritual_buff_time", "120", FCVAR_ARCHIVE, "Duration in seconds for buffs after a successful ritual.")

if SERVER then
    util.AddNetworkString("dr_ritual_channel")
    util.AddNetworkString("dr_ritual_begin")
    util.AddNetworkString("dr_ritual_progress")
    util.AddNetworkString("dr_ritual_success")
    util.AddNetworkString("dr_ritual_fail")
    util.AddNetworkString("dr_ritual_cancel")
    util.AddNetworkString("dr_ritual_offerbuff")
    util.AddNetworkString("dr_ritual_pickbuff")
    util.AddNetworkString("dr_ritual_cancelbuff")
    util.AddNetworkString("dr_ritual_immunity_state")
end

function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "IsChanneling")
    self:NetworkVar("Bool", 1, "IsActive")
    self:NetworkVar("Float", 0, "ChannelEndTime")
    self:NetworkVar("Float", 1, "DeadlineTime")
end
