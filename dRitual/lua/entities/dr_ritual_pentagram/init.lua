AddCSLuaFile("shared.lua")
AddCSLuaFile("cl_init.lua")
include("shared.lua")


-- Combined pool utilities
local function BuildCombinedPool()
    local weaponPool = (DRITUAL and DRITUAL.GetWeaponPool and DRITUAL.GetWeaponPool()) or (DRITUAL and DRITUAL.FALLBACK_WEAPONS) or {}
    local entityPool = (DRITUAL and DRITUAL.GetEntityPool and DRITUAL.GetEntityPool()) or {}
    local combined = {}
    for _, cls in ipairs(weaponPool) do
        combined[#combined + 1] = { kind = "weapon", class = cls }
    end
    for _, cls in ipairs(entityPool) do
        combined[#combined + 1] = { kind = "entity", class = cls }
    end
    return combined
end

local function PickRandomItems(count)
    local pool = BuildCombinedPool()
    if #pool == 0 then 
        return {} 
    end
    local copy = table.Copy(pool)
    local out = {}
    for i = 1, math.min(count, #copy) do
        local idx = math.random(#copy)
        out[#out + 1] = table.remove(copy, idx)
    end
    return out
end

local function ClassToPretty(cls)
    if not cls then 
        return "" 
    end
    local wep = weapons.GetStored and weapons.GetStored(cls)
    if wep and (wep.PrintName or wep.Printname) then
        return wep.PrintName or wep.Printname or cls
    end
    return cls
end

-- if player dies ritual cancelled
function ENT:CancelRitual()
    if self._finishing then 
        return 
    end
    if not self:GetIsActive() and not self:GetIsChanneling() then 
        return 
    end

    timer.Remove("dr_ritual_deadline_" .. self:EntIndex())
    timer.Remove("dr_ritual_channel_" .. self:EntIndex())
    if self._entityScanTimer then
        timer.Remove(self._entityScanTimer)
        self._entityScanTimer = nil
    end

    self:SetIsChanneling(false)
    self:SetIsActive(false)
    self.RitualItems = {}
    self.ItemGivenMap = {}

    local ply = self.InteractingPly
    if IsValid(ply) then
        net.Start("dr_ritual_cancel")
            net.WriteEntity(self)
        net.Send(ply)
        
        -- Unlock player movement
        net.Start("dr_ritual_player_lock")
            net.WriteBool(false)
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

-- Limits one deal per life
local function PlayerHasMadeDeal(ply)
    if not IsValid(ply) then 
        return false 
    end
    return ply._drRitualDealDoneLife == true
end

local function MarkPlayerDealDone(ply)
    if not IsValid(ply) then 
        return 
    end
    ply._drRitualDealDoneLife = true
end

-- Reset when player deaded
if not DRITUAL._resetDealHooksAdded then
    hook.Add("PlayerDeath", "dr_ritual_player_death", function(ply)
        if IsValid(ply) then 
            ply._drRitualDealDoneLife = nil 
            ply._drRitualDialogCount = 0 
            ply._drRitualPostDealTries = 0 
        end
    end)
    hook.Add("PlayerSpawn", "dr_ritual_player_spawn", function(ply)
        if IsValid(ply) then 
            ply._drRitualDealDoneLife = nil 
            ply._drRitualDialogCount = 0 
            ply._drRitualPostDealTries = 0 
        end
    end)
    DRITUAL._resetDealHooksAdded = true
end

-- check if player on prop
local function IsStandingOn(ent, ply)
    if not IsValid(ent) or not IsValid(ply) then 
        return false 
    end
    if ply:GetGroundEntity() == ent then 
        return true 
    end
    local start = ply:GetPos() + Vector(0, 0, 4)
    local tr = util.TraceHull({
        start = start,
        endpos = start - Vector(0, 0, 24),
        mins = Vector(-12, -12, 0),
        maxs = Vector(12, 12, 8),
        mask = MASK_SOLID,
        filter = ply
    })
    if tr.Hit and IsValid(tr.Entity) and tr.Entity == ent then 
        return true 
    end
    local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
   
    local feetLocal = ent:WorldToLocal(ply:GetPos())
    local insideXY = (feetLocal.x >= mins.x - 8 and feetLocal.x <= maxs.x + 8
        and feetLocal.y >= mins.y - 8 and feetLocal.y <= maxs.y + 8)
    if not insideXY then 
        return false 
    end
    local topZ = ent:LocalToWorld(Vector(0, 0, maxs.z)).z
    local dz = ply:GetPos().z - topZ
    return dz >= -6 and dz <= 36
end

function ENT:Initialize()
    local model = "models/pentagram/pentagram_giant.mdl"
    self:SetModel(model)
    -- Make prop smaller as too fat (used to be revolutionary)
    self:SetModelScale(0.75, 0)
    self:SetNoDraw(false)
    self:PhysicsInit(SOLID_VPHYSICS)
    self:SetMoveType(MOVETYPE_NONE)
    self:SetSolid(SOLID_VPHYSICS)
    self:SetCollisionGroup(COLLISION_GROUP_WEAPON)
    local phys = self:GetPhysicsObject()
    if IsValid(phys) then 
        phys:EnableMotion(false) 
    end

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

local function pickBuffChoices(n)
    local pool = (DRITUAL and DRITUAL.GetEnabledBuffKeys and DRITUAL.GetEnabledBuffKeys()) or { "hp", "speed", "jump", "weapon", "ammo", "immunity" }
    local out = {}
    for i = 1, math.min(n or 3, #pool) do
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

    -- If the player dies during channeling, cancel the ritual
    DRITUAL.DeathHooks.SetupDeathHook(self, ply, function()
        self:CancelRitual()
    end)

    timer.Create("dr_ritual_channel_" .. self:EntIndex(), chanTime, 1, function()
        if not IsValid(self) or not IsValid(ply) then 
            return 
        end
        if not self:GetIsChanneling() then 
            return 
        end
        self:SetIsChanneling(false)
        -- 3 random buffs offered to player
        ply._drRitualDialogCount = (ply._drRitualDialogCount or 0) + 1
        local offered = pickBuffChoices(3)
        self.OfferedBuffs = offered
        net.Start("dr_ritual_offerbuff")
            net.WriteEntity(self)
            net.WriteUInt(#offered, 3)
            for _, k in ipairs(offered) do 
                net.WriteString(k) 
            end
        net.Send(ply)
        
        -- Lock player movement during buff selection
        net.Start("dr_ritual_player_lock")
            net.WriteBool(true)
        net.Send(ply)
    end)
end

function ENT:Use(activator)
    if not IsValid(activator) or not activator:IsPlayer() then 
        return 
    end
    if self._quietUntil and CurTime() < self._quietUntil then 
        return 
    end
    if self._finishing then 
        return 
    end
    if self._blockedStartUntil and CurTime() < self._blockedStartUntil then 
        return 
    end
    -- if player has made deal and tries again 3 times they get set on fire for 5 seconds
    if PlayerHasMadeDeal(activator) then
        activator._drRitualPostDealTries = (activator._drRitualPostDealTries or 0) + 1
        if activator._drRitualPostDealTries > 3 then
            net.Start("dr_ritual_no_more")
                net.WriteEntity(self)
            net.Send(activator)
            self._blockedStartUntil = CurTime() + 1.0
            if activator.Ignite then 
                activator:Ignite(5) 
            end
            activator:EmitSound("ambient/fire/ignite.wav", 70, 100)
            return
        else
            -- no vignette
            net.Start("dr_ritual_cancel_vignette") 
            net.Send(activator)
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
        local dir = (activator:GetPos() - self:GetPos())
        dir.z = 0
        if dir:LengthSqr() < 1 then 
            dir = activator:GetForward() 
        end
        dir:Normalize()
        activator:SetVelocity(dir * 460 + Vector(0, 0, 220))
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
            for _, need in ipairs(self.RitualItems) do 
                local key = (istable(need) and need.class) or need
                if not self.ItemGivenMap[key] then 
                    remaining = remaining + 1 
                end 
            end
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
    if self:GetIsActive() or self:GetIsChanneling() then 
        return 
    end
    
    if self.LastRitualEnd > 0 and (CurTime() - self.LastRitualEnd) < 2 then 
        return 
    end

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
        if IsValid(wep) then 
            owns[wep:GetClass()] = true 
        end
    end
    local base = (DRITUAL and DRITUAL.GetWeaponPool and DRITUAL.GetWeaponPool()) or (DRITUAL and DRITUAL.FALLBACK_WEAPONS) or {}
    for _, cls in ipairs(base) do
        if owns[cls] then 
            table.insert(have, cls) 
        end
    end
    return have
end

-- items remaining
function chatRemaining(ply, ent)
    if not IsValid(ply) or not IsValid(ent) then 
        return 
    end
    local rem = {}
    for _, need in ipairs(ent.RitualItems or {}) do
        local key = (istable(need) and need.class) or need
        if not ent.ItemGivenMap or not ent.ItemGivenMap[key] then 
            table.insert(rem, ClassToPretty(key)) 
        end
    end
    if #rem > 0 then 
        ply:ChatPrint("Remaining: " .. table.concat(rem, ", ")) 
    end
end

function ENT:StartRitual()
    local ply = self.InteractingPly
    if not IsValid(ply) then 
        return 
    end
    if self:GetIsActive() then 
        return 
    end

    self:SetIsChanneling(false)
    self:SetIsActive(true)
    self._finishing = false

    local itemCount = math.max(1, GetConVar("dr_ritual_item_count"):GetInt())
    local timeLimit = math.max(1, GetConVar("dr_ritual_time"):GetFloat())
  
    local requested = PickRandomItems(itemCount)

    self.RitualItems = requested
    self.ItemGivenMap = {}
    for _, item in ipairs(self.RitualItems) do
        local key = (istable(item) and item.class) or item
        self.ItemGivenMap[key] = false
    end

    local deadline = CurTime() + timeLimit
    self:SetDeadlineTime(deadline)

    -- deadline timer
    local tname = "dr_ritual_deadline_" .. self:EntIndex()
    timer.Create(tname, 0.2, 0, function()
        if not IsValid(self) then 
            timer.Remove(tname) 
            return 
        end
        if not self:GetIsActive() then 
            timer.Remove(tname) 
            return 
        end
        if self._finishing then 
            timer.Remove(tname) 
            return 
        end
        if CurTime() > deadline then
            timer.Remove(tname)
            self:FailRitual()
        end
    end)

    -- Periodically scan for entity offerings
    if self._entityScanTimer then 
        timer.Remove(self._entityScanTimer) 
    end
    self._entityScanTimer = "dr_ritual_entityscan_" .. self:EntIndex()
    timer.Create(self._entityScanTimer, 0.5, 0, function()
        if not IsValid(self) then 
            timer.Remove(self._entityScanTimer) 
            return 
        end
        if not self:GetIsActive() or self._finishing then 
            return 
        end
        if not istable(self.RitualItems) or not istable(self.ItemGivenMap) then 
            return 
        end
        local needAny = false
        for _, itm in ipairs(self.RitualItems) do
            local key = (istable(itm) and itm.class) or itm
            if self.ItemGivenMap[key] == false then 
                needAny = true 
                break 
            end
        end
        if not needAny then 
            return 
        end
        local mins, maxs = self:OBBMins(), self:OBBMaxs()
        local worldMins = self:LocalToWorld(mins - Vector(4, 4, 0))
        local worldMaxs = self:LocalToWorld(maxs + Vector(4, 4, 16))
        local found = ents.FindInBox(worldMins, worldMaxs)
        local newlySatisfied = {}
        for _, ent in ipairs(found) do
            if IsValid(ent) and ent != self then
                local cls = ent:GetClass()
                -- Match any pending entity requirement
                for _, itm in ipairs(self.RitualItems) do
                    if istable(itm) and itm.kind == "entity" then
                        local key = itm.class
                        if key == cls and self.ItemGivenMap[key] == false then
                            self.ItemGivenMap[key] = true
                            newlySatisfied[#newlySatisfied + 1] = key
                            
                            if ent.Remove then 
                                ent:Remove() 
                            end
                        end
                    end
                end
            end
        end
        if #newlySatisfied > 0 then
            local remaining = 0
            for _, itm in ipairs(self.RitualItems) do
                local key = (istable(itm) and itm.class) or itm
                if not self.ItemGivenMap[key] then 
                    remaining = remaining + 1 
                end
            end
            local ply = self.InteractingPly
            if IsValid(ply) then
                for _, cls in ipairs(newlySatisfied) do
                    net.Start("dr_ritual_progress")
                        net.WriteEntity(self)
                        net.WriteString(cls)
                        net.WriteUInt(remaining, 5)
                    net.Send(ply)
                end
                if remaining == 0 then
                    self._finishing = true
                    self:CompleteRitual()
                else
                    chatRemaining(ply, self)
                end
            end
        end
    end)

    net.Start("dr_ritual_begin")
        net.WriteEntity(self)
        net.WriteFloat(deadline)
        net.WriteUInt(#self.RitualItems, 5)
        for _, item in ipairs(self.RitualItems) do
            local cls = (istable(item) and item.class) or item
            local kind = (istable(item) and item.kind) or "weapon"
            local disp = cls
            if kind == "entity" then
                local ed = scripted_ents.GetStored(cls)
                if ed and ed.t and (ed.t.PrintName or ed.t.Printname) then
                    disp = ed.t.PrintName or ed.t.Printname or cls
                end
            else
                local wep = weapons.GetStored and weapons.GetStored(cls)
                if wep and (wep.PrintName or wep.Printname) then 
                    disp = wep.PrintName or wep.Printname or cls 
                end
            end
            net.WriteString(cls)
            net.WriteBool(kind == "entity")
            net.WriteString(disp)
        end
    net.Send(ply)

    -- player death = no more yes yes
    DRITUAL.DeathHooks.SetupDeathHook(self, ply, function()
        self:CancelRitual()
    end)
end

net.Receive("dr_ritual_pickbuff", function(_, ply)
    local ent = net.ReadEntity()
    local choice = net.ReadString()
    if not IsValid(ent) or ent:GetClass() != "dr_ritual_pentagram" then 
        return 
    end
    if ent.InteractingPly != ply then 
        return 
    end
    if ent:GetIsActive() then 
        return 
    end

    if PlayerHasMadeDeal(ply) then
        ent.InteractingPly = nil
        ent.SelectedBuff = nil
        ent.OfferedBuffs = nil
        ent.LastRitualEnd = CurTime()
        -- Unlock player movement
        net.Start("dr_ritual_player_lock")
            net.WriteBool(false)
        net.Send(ply)
        return
    end
    if ent.SelectedBuff != nil then 
        return 
    end
    if not istable(ent.OfferedBuffs) then 
        return 
    end
    local ok = false
    for _, k in ipairs(ent.OfferedBuffs) do 
        if k == choice then 
            ok = true 
            break 
        end 
    end
    if not ok then 
        return 
    end
    ent.SelectedBuff = choice
    ent:StartRitual()
end)

net.Receive("dr_ritual_cancelbuff", function(_, ply)
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() != "dr_ritual_pentagram" then 
        return 
    end
    if ent.InteractingPly != ply then 
        return 
    end
    if ent:GetIsActive() then 
        return 
    end

    ent.InteractingPly = nil
    ent.SelectedBuff = nil
    ent.OfferedBuffs = nil
    ent.LastRitualEnd = CurTime()
    ent._cancelKBFor = ply
    ent._cancelKBUntil = CurTime() + 3
    
    -- Unlock player movement
    net.Start("dr_ritual_player_lock")
        net.WriteBool(false)
    net.Send(ply)
end)

-- Player gets kicked
net.Receive("dr_ritual_cancel_knockback", function(_, ply)
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() != "dr_ritual_pentagram" then 
        return 
    end
    if ent._cancelKBFor != ply then 
        return 
    end
    if CurTime() > (ent._cancelKBUntil or 0) then 
        return 
    end
    ent._cancelKBFor = nil
    ent._cancelKBUntil = nil
    -- distance of punt
    local dir = (ply:GetPos() - ent:GetPos())
    dir.z = 0
    if dir:LengthSqr() < 1 then 
        dir = ply:GetForward() 
    end
    dir:Normalize()
    local force = 480
    local up = 260
    ply:SetVelocity(dir * force + Vector(0, 0, up))
    ply:EmitSound("physics/body/body_medium_impact_hard1.wav", 70, 100)
end)

net.Receive("dr_ritual_try_sacrifice", function(_, ply)
    local ent = net.ReadEntity()
    if not IsValid(ent) or ent:GetClass() != "dr_ritual_pentagram" then 
        return 
    end
    if ent._finishing then 
        return 
    end
    if ent.InteractingPly != ply then 
        return 
    end
    if not ent:GetIsActive() then 
        return 
    end

    local wep = ply:GetActiveWeapon()
    if not IsValid(wep) then 
        return 
    end
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
        local key = (istable(need) and need.class) or need
        if not ent.ItemGivenMap[key] then 
            remaining = remaining + 1 
        end
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

function ENT:ApplyImmunityBuff(ply, cfg)
    -- Configurable windows of damage immunity scheduled over time
    self.ImmunityUses = 0
    self.ImmunityMaxUses = (cfg and tonumber(cfg.uses)) or 2
    self.ImmunityWindowEnds = 0
    self.ImmunityTimers = {}

    local hookId = "DRITUAL_immunity_hook_" .. self:EntIndex()
    local deathHookId = "DRITUAL_immunity_death_" .. self:EntIndex()
    self.ImmunityHookId = hookId
    self.ImmunityDeathHookId = deathHookId

    local function clearImmunity()
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
        self.ImmunityWindowEnds = 0
        if IsValid(ply) then
            net.Start("dr_ritual_immunity_state") 
            net.WriteBool(false) 
            net.WriteFloat(0) 
            net.Send(ply)
        end
    end

    local function procOnce()
        if not IsValid(self) or not IsValid(ply) then 
            return 
        end
        if self.ImmunityUses >= (self.ImmunityMaxUses or 2) then 
            return 
        end
        self.ImmunityUses = self.ImmunityUses + 1
        local window = (cfg and tonumber(cfg.window)) or 15
        self.ImmunityWindowEnds = CurTime() + window
        net.Start("dr_ritual_immunity_state") 
        net.WriteBool(true) 
        net.WriteFloat(self.ImmunityWindowEnds) 
        net.Send(ply)
        local closeId = "dr_ritual_immunity_end_" .. self:EntIndex() .. "_" .. self.ImmunityUses
        timer.Create(closeId, window, 1, function()
            if not IsValid(self) or not IsValid(ply) then 
                return 
            end
            net.Start("dr_ritual_immunity_state") 
            net.WriteBool(false) 
            net.WriteFloat(0) 
            net.Send(ply)
            if self.ImmunityUses >= (self.ImmunityMaxUses or 2) and CurTime() > self.ImmunityWindowEnds then
            
                if not cfg or cfg.debuffHalveMaxHealth != false then
                    local oldMax = ply:GetMaxHealth() or 100
                    local newMax = math.max(1, math.floor(oldMax * 0.5))
                    ply:SetMaxHealth(newMax)
                    if ply:Health() > newMax then 
                        ply:SetHealth(newMax) 
                    end
                end
                clearImmunity()
            end
        end)
        table.insert(self.ImmunityTimers, closeId)
    end
    hook.Add("EntityTakeDamage", hookId, function(ent, dmg)
        if not IsValid(self) or not IsValid(ply) then 
            hook.Remove("EntityTakeDamage", hookId) 
            self.ImmunityHookId = nil 
            return 
        end
        if ent != ply then 
            return 
        end
        if CurTime() <= self.ImmunityWindowEnds then 
            dmg:SetDamage(0) 
            return true 
        end
    end)
    -- Clear on death
    DRITUAL.DeathHooks.SetupDeathHook(self, ply, clearImmunity)
    
    -- Schedule windows within configured range
    local base = CurTime()
    for i = 1, (self.ImmunityMaxUses or 2) do
        local minS = (cfg and tonumber(cfg.scheduleMin)) or 5
        local maxS = (cfg and tonumber(cfg.scheduleMax)) or 300
        if maxS < minS then 
            maxS = minS 
        end
        local t = base + math.Rand(minS, maxS)
        local tid = "dr_ritual_immunity_proc_" .. self:EntIndex() .. "_" .. i
        timer.Create(tid, math.max(0, t - CurTime()), 1, procOnce)
        table.insert(self.ImmunityTimers, tid)
    end
    local cleanupAfter = math.max(((cfg and tonumber(cfg.scheduleMax)) or 300) + ((cfg and tonumber(cfg.window)) or 15) + 5, 5)
    timer.Simple(cleanupAfter, function()
        if not IsValid(self) then 
            return 
        end
        clearImmunity()
    end)
end

function ENT:CompleteRitual()
    local ply = self.InteractingPly
    self._finishing = true
    self:SetIsActive(false)
    timer.Remove("dr_ritual_deadline_" .. self:EntIndex())
    if self._entityScanTimer then
        timer.Remove(self._entityScanTimer)
        self._entityScanTimer = nil
    end

    if IsValid(ply) then
        net.Start("dr_ritual_success")
            net.WriteEntity(self)
        net.Send(ply)
        
        -- Unlock player movement
        net.Start("dr_ritual_player_lock")
            net.WriteBool(false)
        net.Send(ply)
        
        ply:EmitSound("ambient/machines/thumper_dust.wav", 70, 110)
        if not PlayerHasMadeDeal(ply) then
            MarkPlayerDealDone(ply)
        end
        -- Apply the buff via registry
        local buff = self.SelectedBuff
        if DRITUAL and DRITUAL.ApplyBuff then 
            DRITUAL.ApplyBuff(self, buff, ply) 
        end
        -- Ensure all effects are cleared on players death
        self._buffDeathHookIds = self._buffDeathHookIds or {}
        local dhid = self._buffDeathHookIds[ply] or ("dr_ritual_buffclear_death_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply"))
        self._buffDeathHookIds[ply] = dhid
        hook.Add("PlayerDeath", dhid, function(victim)
            if not IsValid(self) then 
                hook.Remove("PlayerDeath", dhid) 
                return 
            end
            if victim != ply then 
                return 
            end
            if IsValid(ply) then 
                self:ClearAllEffectsFor(ply) 
            end
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
    if not IsValid(ply) then 
        return 
    end
    local sid = (ply.SteamID64 and ply:SteamID64()) or "ply"
    timer.Remove("dr_ritual_debuff_" .. sid)

    if self._speedBuff and self._speedBuff.ply == ply then
        local s = self._speedBuff
        if s.tid then 
            timer.Remove(s.tid) 
        end
        if IsValid(ply) then
            if s.ow then 
                ply:SetWalkSpeed(s.ow) 
            end
            if s.orun then 
                ply:SetRunSpeed(s.orun) 
            end
            if s.oldLMV and ply.SetLaggedMovementValue then 
                ply:SetLaggedMovementValue(s.oldLMV) 
            end
        end
        self._speedBuff = nil
    end

    if self._jumpBuff and self._jumpBuff.ply == ply then
        local j = self._jumpBuff
        if j.hookId then 
            hook.Remove("KeyPress", j.hookId) 
        end
        if j.hookIdSM then 
            hook.Remove("SetupMove", j.hookIdSM) 
        end
        if j.recoilHook then 
            hook.Remove("EntityFireBullets", j.recoilHook) 
        end
        self._jumpBuff = nil
    end

    if self._hpBuff and self._hpBuff.ply == ply then
        local h = self._hpBuff
        if h.tid then 
            timer.Remove(h.tid) 
        end
        if IsValid(ply) then 
            ply:SetModelScale(h.oldScale or 1, 0) 
        end
        self._hpBuff = nil
    end

    if self._ammoBuff and self._ammoBuff.ply == ply then
        local a = self._ammoBuff
        if a.reloadHookId then 
            hook.Remove("KeyPress", a.reloadHookId) 
        end
        if a.refillTid then 
            timer.Remove(a.refillTid) 
        end
        if a.endTid then 
            timer.Remove(a.endTid) 
        end
        for _, wep in ipairs(ply:GetWeapons()) do
            if IsValid(wep) then
                local p = wep:GetPrimaryAmmoType()
                if p and p >= 0 then 
                    ply:SetAmmo(0, p) 
                end
                local s = wep:GetSecondaryAmmoType()
                if s and s >= 0 then 
                    ply:SetAmmo(0, s) 
                end
            end
        end
        self._ammoBuff = nil
    end

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
    self.ImmunityWindowEnds = 0
    net.Start("dr_ritual_immunity_state") 
    net.WriteBool(false) 
    net.WriteFloat(0) 
    net.Send(ply)
end

function ENT:FailRitual()
    if self._finishing then 
        return 
    end
    if not self:GetIsActive() then 
        return 
    end
    local ply = self.InteractingPly
    self:SetIsActive(false)
    self.RitualItems = {}
    self.ItemGivenMap = {}
    timer.Remove("dr_ritual_deadline_" .. self:EntIndex())
    if self._entityScanTimer then
        timer.Remove(self._entityScanTimer)
        self._entityScanTimer = nil
    end

    if IsValid(ply) then
        net.Start("dr_ritual_fail")
            net.WriteEntity(self)
        net.Send(ply)
        
        -- Unlock player movement
        net.Start("dr_ritual_player_lock")
            net.WriteBool(false)
        net.Send(ply)
        
        ply:EmitSound("ambient/energy/weld1.wav", 70, 60)
        local originalWalk = ply:GetWalkSpeed()
        local originalRun = ply:GetRunSpeed()
        ply:SetWalkSpeed(math.max(100, originalWalk * 0.6))
        ply:SetRunSpeed(math.max(160, originalRun * 0.6))
        local id = "dr_ritual_debuff_" .. ply:SteamID64()
        timer.Create(id, 1, 20, function()
            if IsValid(ply) then 
                ply:TakeDamage(1, self, self) 
            end
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
    if self._entityScanTimer then
        timer.Remove(self._entityScanTimer)
        self._entityScanTimer = nil
    end
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
            if s.oldLMV and s.ply.SetLaggedMovementValue then 
                s.ply:SetLaggedMovementValue(s.oldLMV) 
            end
        end
        self._speedBuff = nil
    end
    if self._jumpBuff then
        local j = self._jumpBuff
        if j.tid then 
            timer.Remove(j.tid) 
        end
        if j.hookId then 
            hook.Remove("KeyPress", j.hookId) 
        end
        if j.hookIdSM then 
            hook.Remove("SetupMove", j.hookIdSM) 
        end
        if j.recoilHook then 
            hook.Remove("EntityFireBullets", j.recoilHook) 
        end
        if IsValid(j.ply) and (not j.ends or CurTime() < j.ends) and j.oj then
            j.ply:SetJumpPower(j.oj)
        end
        self._jumpBuff = nil
    end
    if self._hpBuff then
        local h = self._hpBuff
        if h.tid then 
            timer.Remove(h.tid) 
        end
        if IsValid(h.ply) then 
            h.ply:SetModelScale(h.oldScale or 1, 0) 
        end
        self._hpBuff = nil
    end
    if self._ammoBuff then
        local a = self._ammoBuff
        if a.reloadHookId then 
            hook.Remove("KeyPress", a.reloadHookId) 
        end
        if a.refillTid then 
            timer.Remove(a.refillTid) 
        end
        if a.endTid then 
            timer.Remove(a.endTid) 
        end
        self._ammoBuff = nil
    end

    if istable(self._buffDeathHookIds) then
        for _, id in pairs(self._buffDeathHookIds) do 
            hook.Remove("PlayerDeath", id) 
        end
        self._buffDeathHookIds = nil
    end
end

function ENT:SpawnFunction(ply, tr)
    if not tr.Hit then 
        return 
    end
    local ent = ents.Create("dr_ritual_pentagram")
    ent:SetPos(tr.HitPos + tr.HitNormal * 0.5)
    local ang = tr.HitNormal:Angle()
    ang:RotateAroundAxis(ang:Right(), -90)
    ent:SetAngles(ang)
    ent:Spawn()
    ent:Activate()
    return ent
end