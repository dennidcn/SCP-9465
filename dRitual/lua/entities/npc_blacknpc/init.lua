AddCSLuaFile()
include("shared.lua")

function ENT:Initialize()
    self:SetModel("models/dejtriyev/scaryblackman.mdl")
    self:SetHealth(100)
    self:SetSolid(SOLID_BBOX)
    self:SetUseType(SIMPLE_USE)
    self:SetCollisionBounds(Vector(-16, -16, 0), Vector(16, 16, 72))

    -- idle sequence for the npc 
    local function PickIdleSequence(ent)
        local acts = { ACT_IDLE, ACT_IDLE_RELAXED, ACT_IDLE_STIMULATED, ACT_IDLE_AGITATED, ACT_IDLE_ANGRY }
        for _, act in ipairs(acts) do
            local s = ent:SelectWeightedSequence(act)
            if s and s >= 0 then return s end
        end
        local names = { "idle_all", "idle_all_01", "idle_subtle", "idle_unarmed", "idle", "Idle01" }
        for _, n in ipairs(names) do
            local s = ent:LookupSequence(n)
            if s and s >= 0 then return s end
        end
        if ent.GetSequenceList then
            local list = ent:GetSequenceList()
            if istable(list) then
                for _, n in ipairs(list) do
                    if isstring(n) and string.find(string.lower(n), "idle", 1, true) then
                        local s = ent:LookupSequence(n)
                        if s and s >= 0 then return s end
                    end
                end
            end
        end
        return -1
    end
    self.IdleSeq = PickIdleSequence(self)
    if self.IdleSeq and self.IdleSeq >= 0 then
        self:ResetSequence(self.IdleSeq)
        self:SetCycle(0)
        self:SetPlaybackRate(1)
    end
end

function ENT:RunBehaviour()
    while true do
        if self.IdleSeq and self.IdleSeq >= 0 then
            self:ResetSequence(self.IdleSeq)
            self:SetPlaybackRate(1)
        else
            self:StartActivity(ACT_IDLE)
            self.loco:SetDesiredSpeed(0)
        end
        
        local nearest, dist = nil, math.huge
        for _, ply in ipairs(player.GetAll()) do
            if IsValid(ply) then
                local d = self:GetPos():DistToSqr(ply:GetPos())
                if d < dist then nearest, dist = ply, d end
            end
        end
        if IsValid(nearest) then
            if self.loco and self.loco.FaceTowards then
                self.loco:FaceTowards(nearest:GetPos())
            else
                self:FaceTowards(nearest:GetPos())
            end
        end
        coroutine.wait(1)
    end
end

function ENT:Use(activator)
    if IsValid(activator) and activator:IsPlayer() then
        activator:ChatPrint("The shadow watches.")
    end
end

function ENT:Think()
    self:FrameAdvance(FrameTime())
    self:NextThink(CurTime())
    return true
end
