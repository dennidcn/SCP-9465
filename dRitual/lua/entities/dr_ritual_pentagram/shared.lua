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


function ENT:SetupDataTables()
    self:NetworkVar("Bool", 0, "IsChanneling")
    self:NetworkVar("Bool", 1, "IsActive")
    self:NetworkVar("Float", 0, "ChannelEndTime")
    self:NetworkVar("Float", 1, "DeadlineTime")
end
