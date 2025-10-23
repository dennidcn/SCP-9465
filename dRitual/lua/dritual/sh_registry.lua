-- dRitual buffs and debuffs and stuff

if not DRITUAL then DRITUAL = {} end

DRITUAL.Buffs = DRITUAL.Buffs or {}
DRITUAL.Config = DRITUAL.Config or { buffs = {} }

-- Dynamic weapon pool configuration
DRITUAL.Config.weapons = DRITUAL.Config.weapons or {}
DRITUAL.Config.weaponPacks = DRITUAL.Config.weaponPacks or {}
DRITUAL.Config.weaponOverrides = DRITUAL.Config.weaponOverrides or {}
DRITUAL._weaponPool = DRITUAL._weaponPool or nil

-- Entity selection
DRITUAL.Config.entities = DRITUAL.Config.entities or {}
DRITUAL._entityPool = DRITUAL._entityPool or nil

-- Rebuild weapon pool from selected config
function DRITUAL.RebuildWeaponPool()
    if CLIENT then return end
    local packSel = DRITUAL.Config.weaponPacks or {}
    local pool = {}
    local overrides = DRITUAL.Config.weaponOverrides or {}

    -- Determine if packs are in use
    local packActive = false
    for _, v in pairs(packSel) do 
        if v then 
            packActive = true 
            break 
        end 
    end
    
    -- If no packs explicitly selected, but overrides exist that effectively enable some weapons in a pack
    if not packActive then
        for _, wep in ipairs(weapons.GetList() or {}) do
            local cat = (wep and wep.Category) or "Uncategorized"
            local cls = wep.ClassName or wep.Classname or wep.Class or wep.PrintName
            if cls and overrides[cls] != false then
                -- mark its category active
                packSel[cat] = packSel[cat] or false
            end
        end
    end

    if packActive then
        -- Build from categories
        for _, wep in ipairs(weapons.GetList() or {}) do
            local cat = (wep and wep.Category) or "Uncategorized"
            if packSel[cat] then
                local cls = wep.ClassName or wep.Classname or wep.Class or wep.PrintName
                if cls and overrides[cls] != false then
                    table.insert(pool, cls)
                end
            end
        end
    end

    if #pool == 0 then
        pool = DRITUAL.FALLBACK_WEAPONS or {}
    end
    -- Sort class names 
    table.sort(pool, function(a, b)
        return tostring(a) < tostring(b)
    end)
    DRITUAL._weaponPool = pool
end

-- Get current weapon pool
function DRITUAL.GetWeaponPool()
    if SERVER then
        if not DRITUAL._weaponPool then 
            DRITUAL.RebuildWeaponPool() 
        end
        return DRITUAL._weaponPool or {}
    else
        if DRITUAL._weaponPool and #DRITUAL._weaponPool > 0 then 
            return DRITUAL._weaponPool 
        end
        return DRITUAL.FALLBACK_WEAPONS or {}
    end
end

-- Build entity pool from config
function DRITUAL.RebuildEntityPool()
    if CLIENT then return end
    local cfg = DRITUAL.Config.entities or {}
    local pool = {}
    for cls, on in pairs(cfg) do 
        if on then 
            pool[#pool + 1] = cls 
        end 
    end
    table.sort(pool, function(a, b) 
        return tostring(a) < tostring(b) 
    end)
    DRITUAL._entityPool = pool
end

function DRITUAL.GetEntityPool()
    if SERVER then
        if not DRITUAL._entityPool then 
            DRITUAL.RebuildEntityPool() 
        end
        return DRITUAL._entityPool or {}
    else
        return DRITUAL._entityPool or {}
    end
end

-- Register a buff option
function DRITUAL.RegisterBuff(key, def)
    if not key or not def then return end
    def.key = key
    DRITUAL.Buffs[key] = def
    local c = DRITUAL.Config.buffs[key] or {}
    if def.enabled != nil and c.enabled == nil then 
        c.enabled = def.enabled 
    end
    if istable(def.fields) then
        for _, f in ipairs(def.fields) do
            local d = f.default
            if d != nil and c[f.key] == nil then 
                c[f.key] = d 
            end
        end
    end
    DRITUAL.Config.buffs[key] = c
end

function DRITUAL.GetEnabledBuffKeys()
    local out = {}
    for key, def in pairs(DRITUAL.Buffs) do
        local cfg = (DRITUAL.Config and DRITUAL.Config.buffs and DRITUAL.Config.buffs[key]) or {}
        if cfg.enabled != false then 
            table.insert(out, key) 
        end
    end
    table.sort(out)
    return out
end

-- Helper to read global duration
local function getBuffDuration()
    local cv = GetConVar and GetConVar("dr_ritual_buff_time")
    if cv and cv.GetInt then 
        return math.max(1, cv:GetInt()) 
    end
    return 120
end

-- Apply a buff by key
function DRITUAL.ApplyBuff(ent, key, ply)
    if CLIENT then return false end
    if not IsValid(ent) or not IsValid(ply) then return false end
    local def = DRITUAL.Buffs[key]
    if not def or type(def.apply) != "function" then return false end
    local cfg = (DRITUAL.Config and DRITUAL.Config.buffs and DRITUAL.Config.buffs[key]) or {}
    cfg._duration = getBuffDuration()
    def.apply(ent, ply, cfg)
    return true
end

-- Health buff
DRITUAL.RegisterBuff("hp", {
    title = "More health",
    enabled = true,
    fields = {
        { key = "add", label = "Bonus health", type = "number", min = 1, max = 200, default = 25 },
        { key = "debuffScaleMin", label = "Debuff scale min", type = "number", min = 1.0, max = 3.0, default = 1.1 },
        { key = "debuffScaleMax", label = "Debuff scale max", type = "number", min = 1.0, max = 3.0, default = 1.2 },
    },
    apply = function(self, ply, cfg)
        local add = tonumber(cfg.add) or 25
        local dur = tonumber(cfg._duration) or 120
        local cur = ply:Health()
        local maxh = ply:GetMaxHealth() or 100
        if maxh <= 0 then 
            maxh = 100 
        end
        if cur >= maxh then
            local oldMax = maxh
            ply:SetMaxHealth(oldMax + add)
            ply:SetHealth(math.min(oldMax + add, cur + add))
            timer.Simple(dur, function()
                if not IsValid(ply) then return end
                ply:SetMaxHealth(oldMax)
                if ply:Health() > oldMax then 
                    ply:SetHealth(oldMax) 
                end
            end)
        else
            ply:SetHealth(math.min(maxh, cur + add))
        end
        -- Debuff scale player model
        local sMin = tonumber(cfg.debuffScaleMin) or 1.1
        local sMax = tonumber(cfg.debuffScaleMax) or 1.2
        local oldScale = ply:GetModelScale()
        local newScale = math.Rand(math.min(sMin, sMax), math.max(sMin, sMax))
        ply:SetModelScale(newScale, 0)
        local tidScale = "dr_ritual_scale_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
        timer.Create(tidScale, dur, 1, function()
            if IsValid(ply) then 
                ply:SetModelScale(oldScale or 1, 0) 
            end
        end)
        self._hpBuff = { ply = ply, oldScale = oldScale or 1, tid = tidScale, ends = CurTime() + dur }
    end
})

-- Speed buff
DRITUAL.RegisterBuff("speed", {
    title = "Faster sprint speed",
    enabled = true,
    fields = {
        { key = "mult", label = "Speed multiplier", type = "number", min = 1.0, max = 3.0, default = 1.25 },
        { key = "debuffHealthLossMin", label = "Debuff HP loss min (fraction)", type = "number", min = 0.0, max = 1.0, default = 0.15 },
        { key = "debuffHealthLossMax", label = "Debuff HP loss max (fraction)", type = "number", min = 0.0, max = 1.0, default = 0.25 },
    },
    apply = function(self, ply, cfg)
        local mult = tonumber(cfg.mult) or 1.25
        local dur = tonumber(cfg._duration) or 120
        local ow, orun = ply:GetWalkSpeed(), ply:GetRunSpeed()
        local oldLMV = ply.GetLaggedMovementValue and ply:GetLaggedMovementValue() or 1.0
        local tw, tr = ow * mult, orun * mult
        ply:SetWalkSpeed(tw)
        ply:SetRunSpeed(tr)
        if ply.SetLaggedMovementValue then 
            ply:SetLaggedMovementValue(oldLMV * mult) 
        end
        local tid = "dr_ritual_speed_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
        local reps = math.max(1, math.floor(dur / 0.3))
        timer.Create(tid, 0.3, reps, function()
            if not IsValid(ply) then 
                timer.Remove(tid) 
                return 
            end
            if ply:GetWalkSpeed() != tw then 
                ply:SetWalkSpeed(tw) 
            end
            if ply:GetRunSpeed() != tr then 
                ply:SetRunSpeed(tr) 
            end
            if ply.SetLaggedMovementValue and math.abs((ply:GetLaggedMovementValue() or 1.0) - (oldLMV * mult)) > 0.01 then
                ply:SetLaggedMovementValue(oldLMV * mult)
            end
        end)
        timer.Simple(dur, function()
            if IsValid(ply) then
                ply:SetWalkSpeed(ow)
                ply:SetRunSpeed(orun)
                if ply.SetLaggedMovementValue then 
                    ply:SetLaggedMovementValue(oldLMV) 
                end
            end
            timer.Remove(tid)
        end)
        self._speedBuff = { tid = tid, ply = ply, ow = ow, orun = orun, oldLMV = oldLMV, mult = mult, ends = CurTime() + dur }
        -- Debuff immediate health reduction
        local fmin = tonumber(cfg.debuffHealthLossMin) or 0.15
        local fmax = tonumber(cfg.debuffHealthLossMax) or 0.25
        local frac = math.Rand(math.min(fmin, fmax), math.max(fmin, fmax))
        local loss = math.floor((ply:Health() or 0) * frac)
        if loss > 0 then 
            ply:TakeDamage(loss, self, self) 
        end
    end
})

-- Jump buff
DRITUAL.RegisterBuff("jump", {
    title = "Higher jump",
    enabled = true,
    fields = {
        { key = "mult", label = "Jump multiplier", type = "number", min = 1.0, max = 5.0, default = 2.5 },
        { key = "recoilMultMin", label = "Debuff recoil min", type = "number", min = 1.0, max = 5.0, default = 1.15 },
        { key = "recoilMultMax", label = "Debuff recoil max", type = "number", min = 1.0, max = 5.0, default = 1.5 },
    },
    apply = function(self, ply, cfg)
        local mult = tonumber(cfg.mult) or 2.5
        local dur = tonumber(cfg._duration) or 120
        local ends = CurTime() + dur
        local hookId = "dr_ritual_jump_move_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
        hook.Add("SetupMove", hookId, function(p, mv, cmd)
            if p != ply then return end
            if not IsValid(self) or CurTime() > ends then 
                hook.Remove("SetupMove", hookId) 
                return 
            end
            local btn = mv:GetButtons()
            local old = mv:GetOldButtons()
            if bit.band(btn, IN_JUMP) != 0 and bit.band(old, IN_JUMP) == 0 then
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
        -- Debuff: increased visual recoil while active
        local rmin = tonumber(cfg.recoilMultMin) or 1.15
        local rmax = tonumber(cfg.recoilMultMax) or 1.5
        local recoilMult = math.Rand(math.min(rmin, rmax), math.max(rmin, rmax))
        local recoilHook = "dr_ritual_jump_recoil_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
        hook.Add("EntityFireBullets", recoilHook, function(ent, data)
            if ent != ply then return end
            if not IsValid(self) or CurTime() > ends then 
                hook.Remove("EntityFireBullets", recoilHook) 
                return 
            end
            local up = -2.0 * recoilMult
            local side = math.Rand(-1, 1) * 0.6 * recoilMult
            if ent.ViewPunch then 
                ent:ViewPunch(Angle(up, side, 0)) 
            end
        end)
        timer.Simple(dur, function() 
            hook.Remove("EntityFireBullets", recoilHook) 
        end)
        self._jumpBuff = { ply = ply, ends = ends, hookIdSM = hookId, recoilHook = recoilHook }
    end
})

-- Weapon buff
DRITUAL.RegisterBuff("weapon", {
    title = "New weapon",
    enabled = true,
    fields = {
        { key = "removeRandom", label = "Debuff: remove random other weapon", type = "bool", default = true },
    },
    apply = function(self, ply, cfg)
        local basePool = DRITUAL.GetWeaponPool()
        local pool = table.Copy(basePool)
        for i = #pool, 1, -1 do 
            if ply:HasWeapon(pool[i]) then 
                table.remove(pool, i) 
            end 
        end
        local give = pool[math.random(#pool)] or basePool[1]
        ply:Give(give)
        if cfg.removeRandom != false then
            local candidates = {}
            for _, w in ipairs(ply:GetWeapons()) do 
                if IsValid(w) and w:GetClass() != give then 
                    table.insert(candidates, w:GetClass()) 
                end 
            end
            if #candidates > 0 then 
                ply:StripWeapon(candidates[math.random(#candidates)]) 
            end
        end
    end
})

-- Ammo buff
DRITUAL.RegisterBuff("ammo", {
    title = "Unlimited ammo",
    enabled = true,
    fields = {
        { key = "duration", label = "Duration (seconds)", type = "number", min = 5, max = 3600, default = 300 },
        { key = "refillInterval", label = "Refill interval (seconds)", type = "number", min = 0.05, max = 2.0, default = 0.2 },
        { key = "reloadHpMin", label = "Debuff: HP loss on reload min", type = "number", min = 0, max = 50, default = 5 },
        { key = "reloadHpMax", label = "Debuff: HP loss on reload max", type = "number", min = 0, max = 50, default = 10 },
    },
    apply = function(self, ply, cfg)
        local ends = CurTime() + (tonumber(cfg.duration) or 300)
        local interval = math.max(0.05, tonumber(cfg.refillInterval) or 0.2)
        local function refillAmmo()
            if not IsValid(ply) then return end
            for _, wep in ipairs(ply:GetWeapons()) do
                if IsValid(wep) then
                    local p = wep:GetPrimaryAmmoType()
                    if p and p >= 0 then 
                        ply:SetAmmo(9999, p) 
                    end
                    local s = wep:GetSecondaryAmmoType()
                    if s and s >= 0 then 
                        ply:SetAmmo(9999, s) 
                    end
                end
            end
        end
        refillAmmo()
        local refillTid = "dr_ritual_ammo_refill_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
        timer.Create(refillTid, interval, 0, function()
            if not IsValid(self) or not IsValid(ply) or CurTime() > ends then 
                timer.Remove(refillTid) 
                return 
            end
            refillAmmo()
        end)
        local hookId = "dr_ritual_ammo_reload_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
        hook.Add("KeyPress", hookId, function(p, key)
            if p != ply then return end
            if CurTime() > ends then 
                hook.Remove("KeyPress", hookId) 
                return 
            end
            if key == IN_RELOAD then
                local mn = tonumber(cfg.reloadHpMin) or 5
                local mx = tonumber(cfg.reloadHpMax) or 10
                local loss = math.random(math.floor(math.min(mn, mx)), math.floor(math.max(mn, mx)))
                if loss > 0 then 
                    p:TakeDamage(loss, self, self) 
                end
            end
        end)
        local endTid = "dr_ritual_ammo_end_" .. self:EntIndex() .. "_" .. (ply.SteamID64 and ply:SteamID64() or "ply")
        timer.Create(endTid, math.max(0, ends - CurTime()), 1, function()
            if not IsValid(self) or not IsValid(ply) then return end
            hook.Remove("KeyPress", hookId)
            timer.Remove(refillTid)
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
            if self._ammoBuff and self._ammoBuff.ply == ply then 
                self._ammoBuff = nil 
            end
        end)
        self._ammoBuff = { ply = ply, ends = ends, reloadHookId = hookId, refillTid = refillTid, endTid = endTid }
    end
})

-- Immunity buff
DRITUAL.RegisterBuff("immunity", {
    title = "Invulnerability",
    enabled = true,
    fields = {
        { key = "uses", label = "Number of immunity procs", type = "number", min = 1, max = 10, default = 2 },
        { key = "window", label = "Immunity window (seconds)", type = "number", min = 1, max = 60, default = 15 },
        { key = "scheduleMin", label = "Schedule min (seconds)", type = "number", min = 1, max = 1800, default = 5 },
        { key = "scheduleMax", label = "Schedule max (seconds)", type = "number", min = 1, max = 1800, default = 300 },
        { key = "debuffHalveMaxHealth", label = "Debuff: halve max health after uses", type = "bool", default = true },
    },
    apply = function(self, ply, cfg)
        if self.ApplyImmunityBuff then 
            self:ApplyImmunityBuff(ply, cfg) 
        end
    end
})
