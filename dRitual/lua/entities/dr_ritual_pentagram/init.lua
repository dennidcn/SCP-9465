AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")

-- uses HL2 weapons as a base as no access to vguns, vkeycards etc.
local HL2_WEAPONS = {
    "weapon_crowbar", "weapon_pistol", "weapon_357", "weapon_smg1",
    "weapon_ar2", "weapon_shotgun", "weapon_crossbow", "weapon_rpg",
    "weapon_frag", "weapon_stunstick"
}

local function pickRandomItems(count)
    local pool = table.Copy(HL2_WEAPONS)
    local out = {}
    for i = 1, math.min(count, #pool) do
        local idx = math.random(#pool)
        out[#out + 1] = table.remove(pool, idx)
    end
    return out
end

-- if player dies ritual cancelled
function ENT:CancelRitual()
    if self._finishing then return end
    if not self:GetIsActive() and not self:GetIsChanneling() then return end

    timer.Remove("dr_ritual_deadline_" .. self:EntIndex())
    timer.Remove("dr_ritual_channel_" .. self:EntIndex())

    self:SetIsChanneling(false)
    self:SetIsActive(false)
    self.RitualItems = {}
    self.ItemGivenMap = {}

    local ply = self.InteractingPly
    if IsValid(ply) then
        net.Start("dr_ritual_cancel")
            net.WriteEntity(self)
        net.Send(ply)
    end

    self.InteractingPly = nil
    self.SelectedBuff = nil
    self.OfferedBuffs = nil
    self.LastRitualEnd = CurTime()
    if self.DeathHookId then
        hook.Remove("PlayerDeath", self.DeathHookId)
        self.DeathHookId = nil
    end
end

util.AddNetworkString("dr_ritual_try_sacrifice")
util.AddNetworkString("dr_ritual_move_back")
util.AddNetworkString("dr_ritual_vignette_ramp")
util.AddNetworkString("dr_ritual_cancel_knockback")
util.AddNetworkString("dr_ritual_no_more")
util.AddNetworkString("dr_ritual_cancel_vignette")

-- Limits one deal per life
local function PlayerHasMadeDeal(ply)
    if not IsValid(ply) then return false end
    return ply._drRitualDealDoneLife == true
end

local function MarkPlayerDealDone(ply)
    if not IsValid(ply) then return end
    ply._drRitualDealDoneLife = true
end

-- Reset when player deaded
if not _G.dr_ritual_reset_deal_hooks_added then
    hook.Add("PlayerDeath", "dr_ritual_reset_deal_on_death", function(ply)
    if IsValid(ply) then ply._drRitualDealDoneLife = nil ply._drRitualDialogCount = 0 ply._drRitualPostDealTries = 0 end
    end)
    hook.Add("PlayerSpawn", "dr_ritual_reset_deal_on_spawn", function(ply)
    if IsValid(ply) then ply._drRitualDealDoneLife = nil ply._drRitualDialogCount = 0 ply._drRitualPostDealTries = 0 end
    end)
    _G.dr_ritual_reset_deal_hooks_added = true
end

-- check if player on prop
local function IsStandingOn(ent, ply)
    if not IsValid(ent) or not IsValid(ply) then return false end
    if ply:GetGroundEntity() == ent then return true end
    local start = ply:GetPos() + Vector(0, 0, 4)
    local tr = util.TraceHull({
        start = start,
        endpos = start - Vector(0, 0, 24),
        mins = Vector(-12, -12, 0),
        maxs = Vector(12, 12, 8),
        mask = MASK_SOLID,
        filter = ply
    })
    if tr.Hit and IsValid(tr.Entity) and tr.Entity == ent then return true end
    local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
   
    local feetLocal = ent:WorldToLocal(ply:GetPos())
    local insideXY = (feetLocal.x >= mins.x - 8 and feetLocal.x <= maxs.x + 8
        and feetLocal.y >= mins.y - 8 and feetLocal.y <= maxs.y + 8)
    if not insideXY then return false end
    local topZ = ent:LocalToWorld(Vector(0,0,maxs.z)).z
    local dz = ply:GetPos().z - topZ
    return dz >= -6 and dz <= 36
end

function ENT:Initialize()
    local model = "models/pentagram/pentagram_giant.mdl"
    self:SetModel(model)
    -- Make prop smaller as too fat
    self:SetModelScale(0.75, 0)
    self:SetNoDraw(false)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then phys:EnableMotion(false) end

    self.RitualItems = {}
    self.ItemGivenMap = {}
    self.InteractingPly = nil
    self.LastRitualEnd = 0
    self:SetUseType(SIMPLE_USE)
    self.SelectedBuff = nil
    self.OfferedBuffs = nil

    self.ImmunityUses = 0
    self.ImmunityWindowEnds = 0
    self.ImmunityMaxUses = 0
    self.ImmunityTimers = {}
    self.ImmunityHookId = nil
    self.ImmunityDeathHookId = nil
end

local ALL_BUFFS = { "hp", "speed", "jump", "weapon", "ammo", "immunity" }

local function pickBuffChoices(n)
    local pool = table.Copy(ALL_BUFFS)
    local out = {}
    for i = 1, math.min(n, #pool) do
        local idx = math.random(#pool)
        out[#out + 1] = table.remove(pool, idx)
    end
    return out
end

function ENT:BeginChannel(ply)
    local chanTime = GetConVar("dr_ritual_channel_time"):GetFloat()
    self:SetIsChanneling(true)
    self:SetChannelEndTime(CurTime() + chanTime)
    self.InteractingPly = ply

    if IsValid(ply) then
        net.Start("dr_ritual_vignette_ramp")
            net.WriteFloat(0.9)
        net.Send(ply)
    end

    timer.Create("dr_ritual_channel_" .. self:EntIndex(), chanTime, 1, function()
        if not IsValid(self) or not IsValid(ply) then return end
        if not self:GetIsChanneling() then return end
        self:SetIsChanneling(false)
        -- 3 random buffs offered to player
    ply._drRitualDialogCount = (ply._drRitualDialogCount or 0) + 1
        local offered = pickBuffChoices(3)
        self.OfferedBuffs = offered
        net.Start("dr_ritual_offerbuff")
            net.WriteEntity(self)
            net.WriteUInt(#offered, 3)
            for _, k in ipairs(offered) do net.WriteString(k) end
        net.Send(ply)
    end)
end

function ENT:Use(activator)
    if not IsValid(activator) or not activator:IsPlayer() then return end
    if self._quietUntil and CurTime() < self._quietUntil then return end
    if self._finishing then return end
    if self._blockedStartUntil and CurTime() < self._blockedStartUntil then return end
    -- if player has made deal and tries again 3 times they get set on fire for 5 seconds
    if PlayerHasMadeDeal(activator) then
        activator._drRitualPostDealTries = (activator._drRitualPostDealTries or 0) + 1
        if activator._drRitualPostDealTries > 3 then
            net.Start("dr_ritual_no_more")
                net.WriteEntity(self)
            net.Send(activator)
            self._blockedStartUntil = CurTime() + 1.0
            if activator.Ignite then activator:Ignite(5) end
            activator:EmitSound("ambient/fire/ignite.wav", 70, 100)
            return
        else
            -- no vignette
            net.Start("dr_ritual_cancel_vignette") net.Send(activator)
            self._quietUntil = CurTime() + 0.8
            return
        end
    end
    -- Only allows user to attempt to start 3 times
    if (activator._drRitualDialogCount or 0) >= 3 then
        -- NO MORE AND PLAYER DAMAGE
        net.Start("dr_ritual_no_more")
            net.WriteEntity(self)
        net.Send(activator)
        self._blockedStartUntil = CurTime() + 1.0
        local dir = (activator:GetPos() - self:GetPos()); dir.z = 0
        if dir:LengthSqr() < 1 then dir = activator:GetForward() end
        dir:Normalize()
        activator:SetVelocity(dir * 460 + Vector(0,0,220))
        activator:TakeDamage(10, self, self)
        activator:EmitSound("physics/body/body_medium_impact_hard1.wav", 70, 100)
        return
    end
    if self:GetIsActive() and self.InteractingPly == activator then
        local wep = activator:GetActiveWeapon()
        if IsValid(wep) then
            local cls = wep:GetClass()
            if self.ItemGivenMap[cls] == nil then
                activator:ChatPrint("The ██████ rejects this offering.")
                chatRemaining(activator, self)
                self:EmitSound("buttons/button10.wav", 60, 90)
                return
            end
            if self.ItemGivenMap[cls] then
                activator:ChatPrint("Already offered this.")
                chatRemaining(activator, self)
                return
            end
            self.ItemGivenMap[cls] = true
            activator:StripWeapon(cls)
            self:EmitSound("ambient/levels/canals/windchime2.wav", 70, 120)
            local remaining = 0
            for _, need in ipairs(self.RitualItems) do if not self.ItemGivenMap[need] then remaining = remaining + 1 end end
            net.Start("dr_ritual_progress")
                net.WriteEntity(self)
                net.WriteString(cls)
                net.WriteUInt(remaining, 5)
            net.Send(activator)
            if remaining == 0 then
                self._finishing = true
                self:CompleteRitual()
            else
                chatRemaining(activator, self)
            end
            return
        end
    end
    if self:GetIsActive() or self:GetIsChanneling() then return end
    
    if self.LastRitualEnd > 0 and (CurTime() - self.LastRitualEnd) < 2 then return end

    if IsStandingOn(self, activator) then
        net.Start("dr_ritual_move_back")
            net.WriteEntity(self)
        net.Send(activator)
        self._blockedStartUntil = CurTime() + 1.0
        return
    end

    self:BeginChannel(activator)
end

local function filterPlayerHL2Weapons(ply)
    local have = {}
    local owns = {}
    for _, wep in ipairs(ply:GetWeapons()) do
        if IsValid(wep) then owns[wep:GetClass()] = true end
    end
    for _, cls in ipairs(HL2_WEAPONS) do
        if owns[cls] then table.insert(have, cls) end
    end
    return have
end

-- items remaining
function chatRemaining(ply, ent)
    if not IsValid(ply) or not IsValid(ent) then return end
    local rem = {}
    for _, need in ipairs(ent.RitualItems or {}) do
        if not ent.ItemGivenMap or not ent.ItemGivenMap[need] then table.insert(rem, need) end
    end
    if #rem > 0 then ply:ChatPrint("Remaining: " .. table.concat(rem, ", ")) end
end

function ENT:StartRitual()
    local ply = self.InteractingPly
    if not IsValid(ply) then return end
    if self:GetIsActive() then return end

    self:SetIsChanneling(false)
    self:SetIsActive(true)
    self._finishing = false

    local itemCount = math.max(1, GetConVar("dr_ritual_item_count"):GetInt())
    local timeLimit = math.max(1, GetConVar("dr_ritual_time"):GetFloat())
  
    local requested = pickRandomItems(itemCount)

    self.RitualItems = requested
    self.ItemGivenMap = {}
    for _, cls in ipairs(self.RitualItems) do self.ItemGivenMap[cls] = false end

    local deadline = CurTime() + timeLimit
    self:SetDeadlineTime(deadline)

    -- deadline timer
    local tname = "dr_ritual_deadline_" .. self:EntIndex()
    timer.Create(tname, 0.2, 0, function()
        if not IsValid(self) then timer.Remove(tname) return end
        if not self:GetIsActive() then timer.Remove(tname) return end
        if self._finishing then timer.Remove(tname) return end
        if CurTime() > deadline then
            timer.Remove(tname)
            self:FailRitual()
        end
    end)

    net.Start("dr_ritual_begin")
        net.WriteEntity(self)
        net.WriteFloat(deadline)
        net.WriteUInt(#self.RitualItems, 5)
        for _, cls in ipairs(self.RitualItems) do net.WriteString(cls) end
    net.Send(ply)

    -- player death = no more yes yes
    local deathHookId = "dr_ritual_owner_death_" .. self:EntIndex()
    self.DeathHookId = deathHookId
    hook.Add("PlayerDeath", deathHookId, function(victim)
        if not IsValid(self) then hook.Remove("PlayerDeath", deathHookId) return end
        if victim ~= ply then return end
        self:CancelRitual()
    end)
end


net.Receive("dr_ritual_pickbuff", function(_, ply)
    local ent = net.ReadEntity()
    local choice = net.ReadString()
    if not IsValid(ent) or ent:GetClass() ~= "dr_ritual_pentagram" then return end
    if ent.InteractingPly ~= ply then return end
    if ent:GetIsActive() then return end

    if PlayerHasMadeDeal(ply) then
        ent.InteractingPly = nil
        ent.SelectedBuff = nil
        ent.OfferedBuffs = nil
        ent.LastRitualEnd = CurTime()
        return
    end
    if ent.SelectedBuff ~= nil then return end
    if not istable(ent.OfferedBuffs) then return end
    local ok = false
    for _, k in ipairs(ent.OfferedBuffs) do if k == choice then ok = true break end end
    if not ok then return end
    ent.SelectedBuff = choice
    ent:StartRitual()
end)

net.Receive("dr_ritual_cancelbuff", function(_, ply)
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "dr_ritual_pentagram" then return end
    if ent.InteractingPly ~= ply then return end
    if ent:GetIsActive() then return end

    ent.InteractingPly = nil
    ent.SelectedBuff = nil
    ent.OfferedBuffs = nil
    ent.LastRitualEnd = CurTime()
    ent._cancelKBFor = ply
    ent._cancelKBUntil = CurTime() + 3
end)

-- Player gets kicked
net.Receive("dr_ritual_cancel_knockback", function(_, ply)
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "dr_ritual_pentagram" then return end
    if ent._cancelKBFor ~= ply then return end
    if CurTime() > (ent._cancelKBUntil or 0) then return end
    ent._cancelKBFor = nil
    ent._cancelKBUntil = nil
    -- kick distance
    local dir = (ply:GetPos() - ent:GetPos()); dir.z = 0
    if dir:LengthSqr() < 1 then dir = ply:GetForward() end
    dir:Normalize()
    local force = 480
    local up = 260
    ply:SetVelocity(dir * force + Vector(0,0,up))
    ply:EmitSound("physics/body/body_medium_impact_hard1.wav", 70, 100)
end)

net.Receive("dr_ritual_try_sacrifice", function(_, ply)
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() ~= "dr_ritual_pentagram" then return end
    if ent._finishing then return end
    if ent.InteractingPly ~= ply then return end
    if not ent:GetIsActive() then return end

    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then return end
    local cls = wep:GetClass()
    if ent.ItemGivenMap[cls] == nil then
        ply:ChatPrint("The ██████ rejects this offering.")
        chatRemaining(ply, ent)
        ent:EmitSound("buttons/button10.wav", 60, 90)
        return
    end
    if ent.ItemGivenMap[cls] then
        ply:ChatPrint("Already offered this.")
        chatRemaining(ply, ent)
        return
    end

    ent.ItemGivenMap[cls] = true
    ply:StripWeapon(cls)
    ent:EmitSound("ambient/levels/canals/windchime2.wav", 70, 120)

    local remaining = 0
    for _, need in ipairs(ent.RitualItems) do
        if not ent.ItemGivenMap[need] then remaining = remaining + 1 end
    end
    net.Start("dr_ritual_progress")
        net.WriteEntity(ent)
        net.WriteString(cls)
        net.WriteUInt(remaining, 5)
    net.Send(ply)

    if remaining == 0 then
        ent._finishing = true
        ent:CompleteRitual()
    else
        chatRemaining(ply, ent)
    end
end)

function ENT:ApplyImmunityBuff(ply)
    -- Two persiods of damage immunity for 15 seconds each randomly happens within 5 minutes
    self.ImmunityUses = 0
    self.ImmunityMaxUses = 2
    self.ImmunityWindowEnds = 0
    self.ImmunityTimers = {}

    local hookId = "dr_ritual_immunity_hook_" .. self:EntIndex()
    local deathHookId = "dr_ritual_immunity_death_" .. self:EntIndex()
    self.ImmunityHookId = hookId
    self.ImmunityDeathHookId = deathHookId

    local function clearImmunity()
        if self.ImmunityHookId then hook.Remove("EntityTakeDamage", self.ImmunityHookId) self.ImmunityHookId = nil end
        if self.ImmunityDeathHookId then hook.Remove("PlayerDeath", self.ImmunityDeathHookId) self.ImmunityDeathHookId = nil end
        if istable(self.ImmunityTimers) then for _, tid in ipairs(self.ImmunityTimers) do timer.Remove(tid) end self.ImmunityTimers = {} end
        self.ImmunityWindowEnds = 0
        if IsValid(ply) then
            net.Start("dr_ritual_immunity_state") net.WriteBool(false) net.WriteFloat(0) net.Send(ply)
        end
    end

    local function procOnce()
        if not IsValid(self) or not IsValid(ply) then return end
        if self.ImmunityUses >= (self.ImmunityMaxUses or 2) then return end
        self.ImmunityUses = self.ImmunityUses + 1
        self.ImmunityWindowEnds = CurTime() + 15
        net.Start("dr_ritual_immunity_state") net.WriteBool(true) net.WriteFloat(self.ImmunityWindowEnds) net.Send(ply)
        local closeId = "dr_ritual_immunity_end_" .. self:EntIndex() .. "_" .. self.ImmunityUses
        timer.Create(closeId, 15, 1, function()
            if not IsValid(self) or not IsValid(ply) then return end
            net.Start("dr_ritual_immunity_state") net.WriteBool(false) net.WriteFloat(0) net.Send(ply)
            if self.ImmunityUses >= (self.ImmunityMaxUses or 2) and CurTime() > self.ImmunityWindowEnds then
                -- debuff, halves max health
                local oldMax = ply:GetMaxHealth() or 100
                local newMax = math.max(1, math.floor(oldMax * 0.5))
                ply:SetMaxHealth(newMax)
                if ply:Health() > newMax then ply:SetHealth(newMax) end
                clearImmunity()
            end
        end)
        table.insert(self.ImmunityTimers, closeId)
    end
    hook.Add("EntityTakeDamage", hookId, function(ent, dmg)
        if not IsValid(self) or not IsValid(ply) then hook.Remove("EntityTakeDamage", hookId) self.ImmunityHookId = nil return end
        if ent ~= ply then return end
        if CurTime() <= self.ImmunityWindowEnds then dmg:SetDamage(0) return true end
    end)
    -- Clear on death
    hook.Add("PlayerDeath", deathHookId, function(victim)
        if not IsValid(self) then hook.Remove("PlayerDeath", deathHookId) return end
        if victim ~= ply then return end
        clearImmunity()
    end)
    -- Schedule two random thingies within 5 minutes
    local base = CurTime()
    for i=1,(self.ImmunityMaxUses or 2) do
        local t = base + math.Rand(5, 300)
        local tid = "dr_ritual_immunity_proc_" .. self:EntIndex() .. "_" .. i
        timer.Create(tid, math.max(0, t - CurTime()), 1, procOnce)
        table.insert(self.ImmunityTimers, tid)
    end
    timer.Simple(305, function()
        if not IsValid(self) then return end
        clearImmunity()
    end)
end

function ENT:CompleteRitual()
    local ply = self.InteractingPly
    self._finishing = true
    self:SetIsActive(false)
    timer.Remove("dr_ritual_deadline_" .. self:EntIndex())

    if IsValid(ply) then
        net.Start("dr_ritual_success")
            net.WriteEntity(self)
        net.Send(ply)
        ply:EmitSound("ambient/machines/thumper_dust.wav", 70, 110)
        if not PlayerHasMadeDeal(ply) then
            MarkPlayerDealDone(ply)
        end
    -- Apply the buff
        local buff = self.SelectedBuff
        local dur = math.max(1, GetConVar("dr_ritual_buff_time"):GetInt())
        if buff == "hp" then
            local add = 25
            local cur = ply:Health()
            local maxh = ply:GetMaxHealth() or 0
            if maxh <= 0 then maxh = 100 end
            if cur >= maxh then
                local oldMax = maxh
                ply:SetMaxHealth(oldMax + add)
                ply:SetHealth(math.min(oldMax + add, cur + add))
                timer.Simple(dur, function()
                    if not IsValid(ply) then return end
                    ply:SetMaxHealth(oldMax)
                    if ply:Health() > oldMax then ply:SetHealth(oldMax) end
                end)
            else
                ply:SetHealth(math.min(maxh, cur + add))
            end
            -- debuff by scaling player size randomly 1.1 - 1.2 for duration
            local oldScale = ply:GetModelScale()
            local newScale = math.Rand(1.1, 1.2)
            ply:SetModelScale(newScale, 0)
            local tidScale = "dr_ritual_scale_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
            timer.Create(tidScale, dur, 1, function()
                if IsValid(ply) then ply:SetModelScale(oldScale or 1, 0) end
            end)
            self._hpBuff = { ply = ply, oldScale = oldScale or 1, tid = tidScale, ends = CurTime() + dur }
        elseif buff == "speed" then
            local ow, orun = ply:GetWalkSpeed(), ply:GetRunSpeed()
            local oldLMV = ply.GetLaggedMovementValue and ply:GetLaggedMovementValue() or 1.0
            local mult = 1.25
            local tw, tr = ow * mult, orun * mult
            ply:SetWalkSpeed(tw)
            ply:SetRunSpeed(tr)
            if ply.SetLaggedMovementValue then ply:SetLaggedMovementValue(oldLMV * mult) end
            local tid = "dr_ritual_speed_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
            local reps = math.max(1, math.floor(dur / 0.3))
            timer.Create(tid, 0.3, reps, function()
                if not IsValid(ply) then timer.Remove(tid) return end
                if ply:GetWalkSpeed() ~= tw then ply:SetWalkSpeed(tw) end
                if ply:GetRunSpeed() ~= tr then ply:SetRunSpeed(tr) end
                if ply.SetLaggedMovementValue and math.abs((ply:GetLaggedMovementValue() or 1.0) - (oldLMV * mult)) > 0.01 then
                    ply:SetLaggedMovementValue(oldLMV * mult)
                end
            end)
            timer.Simple(dur, function()
                if IsValid(ply) then
                    ply:SetWalkSpeed(ow)
                    ply:SetRunSpeed(orun)
                    if ply.SetLaggedMovementValue then ply:SetLaggedMovementValue(oldLMV) end
                end
                timer.Remove(tid)
            end)
            self._speedBuff = { tid = tid, ply = ply, ow = ow, orun = orun, oldLMV = oldLMV, mult = mult, ends = CurTime() + dur }
            -- debuff by immediate health reduction 15-25% of current health
            local frac = math.Rand(0.15, 0.25)
            local loss = math.floor((ply:Health() or 0) * frac)
            if loss > 0 then ply:TakeDamage(loss, self, self) end
        elseif buff == "jump" then
            local mult = 2.5 -- 150% increase over base jump height
            local ends = CurTime() + dur
            local hookId = "dr_ritual_jump_move_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
            hook.Add("SetupMove", hookId, function(p, mv, cmd)
                if p ~= ply then return end
                if not IsValid(self) or CurTime() > ends then hook.Remove("SetupMove", hookId) return end
                local btn = mv:GetButtons()
                local old = mv:GetOldButtons()
                if bit.band(btn, IN_JUMP) ~= 0 and bit.band(old, IN_JUMP) == 0 then
                    local jp = (ply.GetJumpPower and ply:GetJumpPower()) or 200
                    local add = jp * (mult - 1)
                    local vel = mv:GetVelocity()
                    vel.z = vel.z + add
                    mv:SetVelocity(vel)
                end
            end)
            timer.Simple(dur, function()
                hook.Remove("SetupMove", hookId)
            end)
            -- debuff by increasing visual recoil by 15-50%
            local recoilMult = 1 + math.Rand(0.15, 0.50)
            local recoilHook = "dr_ritual_jump_recoil_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
            hook.Add("EntityFireBullets", recoilHook, function(ent, data)
                if ent ~= ply then return end
                if not IsValid(self) or CurTime() > ends then hook.Remove("EntityFireBullets", recoilHook) return end
                local up = -2.0 * recoilMult
                local side = math.Rand(-1, 1) * 0.6 * recoilMult
                if ent.ViewPunch then ent:ViewPunch(Angle(up, side, 0)) end
            end)
            timer.Simple(dur, function() hook.Remove("EntityFireBullets", recoilHook) end)
            self._jumpBuff = { ply = ply, ends = ends, hookIdSM = hookId, recoilHook = recoilHook }
        elseif buff == "weapon" then
            local pool = table.Copy(HL2_WEAPONS)
            for i = #pool, 1, -1 do
                if ply:HasWeapon(pool[i]) then table.remove(pool, i) end
            end
            local give = pool[math.random(#pool)] or HL2_WEAPONS[1]
            ply:Give(give)
            -- debuff by making a random item weapon disappear from inventory
            local candidates = {}
            for _, w in ipairs(ply:GetWeapons()) do
                if IsValid(w) and w:GetClass() ~= give then table.insert(candidates, w:GetClass()) end
            end
            if #candidates > 0 then
                local rem = candidates[math.random(#candidates)]
                ply:StripWeapon(rem)
            end
        elseif buff == "ammo" then
            -- Unlimited reserve ammo for 5 minutes reload costs 5-10 HP each time
            local ends = CurTime() + 300
            local function refillAmmo()
                if not IsValid(ply) then return end
                for _, wep in ipairs(ply:GetWeapons()) do
                    if IsValid(wep) then
                        local p = wep:GetPrimaryAmmoType()
                        if p and p >= 0 then ply:SetAmmo(9999, p) end
                        local s = wep:GetSecondaryAmmoType()
                        if s and s >= 0 then ply:SetAmmo(9999, s) end
                    end
                end
            end

            refillAmmo()
    
            local refillTid = "dr_ritual_ammo_refill_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
            timer.Create(refillTid, 0.2, 0, function()
                if not IsValid(self) or not IsValid(ply) or CurTime() > ends then
                    timer.Remove(refillTid)
                    return
                end
                refillAmmo()
            end)

            local hookId = "dr_ritual_ammo_reload_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
            hook.Add("KeyPress", hookId, function(p, key)
                if p ~= ply then return end
                if CurTime() > ends then hook.Remove("KeyPress", hookId) return end
                if key == IN_RELOAD then
                    local loss = math.random(5, 10)
                    p:TakeDamage(loss, self, self)
                end
            end)
            -- when timer ends set all reserve ammo to 0
            local endTid = "dr_ritual_ammo_end_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
            timer.Create(endTid, math.max(0, ends - CurTime()), 1, function()
                if not IsValid(self) or not IsValid(ply) then return end
                hook.Remove("KeyPress", hookId)
                timer.Remove(refillTid)
                -- Zero reserve ammo for all currently held weapons' ammo types
                for _, wep in ipairs(ply:GetWeapons()) do
                    if IsValid(wep) then
                        local p = wep:GetPrimaryAmmoType()
                        if p and p >= 0 then ply:SetAmmo(0, p) end
                        local s = wep:GetSecondaryAmmoType()
                        if s and s >= 0 then ply:SetAmmo(0, s) end
                    end
                end
                if self._ammoBuff and self._ammoBuff.ply == ply then self._ammoBuff = nil end
            end)
            self._ammoBuff = { ply = ply, ends = ends, reloadHookId = hookId, refillTid = refillTid, endTid = endTid }
        elseif buff == "immunity" then
            self:ApplyImmunityBuff(ply)
        end
        -- Ensure all effects are cleared on players death
        self._buffDeathHookIds = self._buffDeathHookIds or {}
        local dhid = self._buffDeathHookIds[ply] or ("dr_ritual_buffclear_death_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply"))
        self._buffDeathHookIds[ply] = dhid
        hook.Add("PlayerDeath", dhid, function(victim)
            if not IsValid(self) then hook.Remove("PlayerDeath", dhid) return end
            if victim ~= ply then return end
            if IsValid(ply) then self:ClearAllEffectsFor(ply) end
            hook.Remove("PlayerDeath", dhid)
            self._buffDeathHookIds[ply] = nil
        end)
    end

    self.InteractingPly = nil
    self.SelectedBuff = nil
    self.OfferedBuffs = nil
    self.LastRitualEnd = CurTime()
    self._quietUntil = CurTime() + 1.5
    if self.DeathHookId then
        hook.Remove("PlayerDeath", self.DeathHookId)
        self.DeathHookId = nil
    end
    self._finishing = false
end

function ENT:ClearAllEffectsFor(ply)
    if not IsValid(ply) then return end
    local sid = (ply.SteamID64 and ply:SteamID64()) or "ply"
    timer.Remove("dr_ritual_debuff_" .. sid)

    if self._speedBuff and self._speedBuff.ply == ply then
        local s = self._speedBuff
        if s.tid then timer.Remove(s.tid) end
        if IsValid(ply) then
            if s.ow then ply:SetWalkSpeed(s.ow) end
            if s.orun then ply:SetRunSpeed(s.orun) end
            if s.oldLMV and ply.SetLaggedMovementValue then ply:SetLaggedMovementValue(s.oldLMV) end
        end
        self._speedBuff = nil
    end

    if self._jumpBuff and self._jumpBuff.ply == ply then
        local j = self._jumpBuff
        if j.hookId then hook.Remove("KeyPress", j.hookId) end
        if j.hookIdSM then hook.Remove("SetupMove", j.hookIdSM) end
        if j.recoilHook then hook.Remove("EntityFireBullets", j.recoilHook) end
        self._jumpBuff = nil
    end

    if self._hpBuff and self._hpBuff.ply == ply then
        local h = self._hpBuff
        if h.tid then timer.Remove(h.tid) end
        if IsValid(ply) then ply:SetModelScale(h.oldScale or 1, 0) end
        self._hpBuff = nil
    end

    if self._ammoBuff and self._ammoBuff.ply == ply then
        local a = self._ammoBuff
        if a.reloadHookId then hook.Remove("KeyPress", a.reloadHookId) end
        if a.refillTid then timer.Remove(a.refillTid) end
        if a.endTid then timer.Remove(a.endTid) end
        for _, wep in ipairs(ply:GetWeapons()) do
            if IsValid(wep) then
                local p = wep:GetPrimaryAmmoType()
                if p and p >= 0 then ply:SetAmmo(0, p) end
                local s = wep:GetSecondaryAmmoType()
                if s and s >= 0 then ply:SetAmmo(0, s) end
            end
        end
        self._ammoBuff = nil
    end

    if self.ImmunityHookId then hook.Remove("EntityTakeDamage", self.ImmunityHookId) self.ImmunityHookId = nil end
    if self.ImmunityDeathHookId then hook.Remove("PlayerDeath", self.ImmunityDeathHookId) self.ImmunityDeathHookId = nil end
    if istable(self.ImmunityTimers) then for _, tid in ipairs(self.ImmunityTimers) do timer.Remove(tid) end self.ImmunityTimers = {} end
    self.ImmunityWindowEnds = 0
    net.Start("dr_ritual_immunity_state") net.WriteBool(false) net.WriteFloat(0) net.Send(ply)
end

function ENT:FailRitual()
    if self._finishing then return end
    if not self:GetIsActive() then return end
    local ply = self.InteractingPly
    self:SetIsActive(false)
    self.RitualItems = {}
    self.ItemGivenMap = {}
    timer.Remove("dr_ritual_deadline_" .. self:EntIndex())

    if IsValid(ply) then
        net.Start("dr_ritual_fail")
            net.WriteEntity(self)
        net.Send(ply)
        ply:EmitSound("ambient/energy/weld1.wav", 70, 60)
        local originalWalk = ply:GetWalkSpeed()
        local originalRun = ply:GetRunSpeed()
        ply:SetWalkSpeed(math.max(100, originalWalk * 0.6))
        ply:SetRunSpeed(math.max(160, originalRun * 0.6))
        local id = "dr_ritual_debuff_" .. ply:SteamID64()
        timer.Create(id, 1, 20, function()
            if IsValid(ply) then ply:TakeDamage(1, self, self) end
        end)
        timer.Simple(20, function()
            if IsValid(ply) then
                ply:SetWalkSpeed(originalWalk)
                ply:SetRunSpeed(originalRun)
            end
        end)
    end
    self.InteractingPly = nil
    self.SelectedBuff = nil
    self.OfferedBuffs = nil
    self.LastRitualEnd = CurTime()
    if self.DeathHookId then
        hook.Remove("PlayerDeath", self.DeathHookId)
        self.DeathHookId = nil
    end
end

function ENT:AcceptInput(name, activator)
    if name == "Use" then
        self:Use(activator)
        return true
    end
end

function ENT:OnRemove()
    timer.Remove("dr_ritual_deadline_" .. self:EntIndex())
    timer.Remove("dr_ritual_channel_" .. self:EntIndex())
    if self.ImmunityHookId then
        hook.Remove("EntityTakeDamage", self.ImmunityHookId)
        self.ImmunityHookId = nil
    end
    if self.ImmunityDeathHookId then
        hook.Remove("PlayerDeath", self.ImmunityDeathHookId)
        self.ImmunityDeathHookId = nil
    end
    if istable(self.ImmunityTimers) then
        for _, tid in ipairs(self.ImmunityTimers) do
            timer.Remove(tid)
        end
        self.ImmunityTimers = {}
    end
    if self.DeathHookId then
        hook.Remove("PlayerDeath", self.DeathHookId)
        self.DeathHookId = nil
    end
        if self._speedBuff then
        local s = self._speedBuff
        timer.Remove(s.tid)
        if IsValid(s.ply) and (not s.ends or CurTime() < s.ends) then
            s.ply:SetWalkSpeed(s.ow)
            s.ply:SetRunSpeed(s.orun)
            if s.oldLMV and s.ply.SetLaggedMovementValue then s.ply:SetLaggedMovementValue(s.oldLMV) end
        end
        self._speedBuff = nil
    end
    if self._jumpBuff then
        local j = self._jumpBuff
        if j.tid then timer.Remove(j.tid) end
        if j.hookId then hook.Remove("KeyPress", j.hookId) end
        if j.hookIdSM then hook.Remove("SetupMove", j.hookIdSM) end
        if j.recoilHook then hook.Remove("EntityFireBullets", j.recoilHook) end
        if IsValid(j.ply) and (not j.ends or CurTime() < j.ends) and j.oj then
            j.ply:SetJumpPower(j.oj)
        end
        self._jumpBuff = nil
    end
    if self._hpBuff then
        local h = self._hpBuff
        if h.tid then timer.Remove(h.tid) end
        if IsValid(h.ply) then h.ply:SetModelScale(h.oldScale or 1, 0) end
        self._hpBuff = nil
    end
    if self._ammoBuff then
        local a = self._ammoBuff
        if a.reloadHookId then hook.Remove("KeyPress", a.reloadHookId) end
    if a.refillTid then timer.Remove(a.refillTid) end
    if a.endTid then timer.Remove(a.endTid) end
        self._ammoBuff = nil
    end

    if istable(self._buffDeathHookIds) then
        for _, id in pairs(self._buffDeathHookIds) do hook.Remove("PlayerDeath", id) end
        self._buffDeathHookIds = nil
    end
end

function ENT:SpawnFunction(ply, tr)
    if not tr.Hit then return end
    local ent = ents.Create("dr_ritual_pentagram")
    ent:SetPos(tr.HitPos + tr.HitNormal * 0.5)
    local ang = tr.HitNormal:Angle()
    ang:RotateAroundAxis(ang:Right(), -90)
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()
    return ent
end
