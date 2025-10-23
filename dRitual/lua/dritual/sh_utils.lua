-- Shared utility functions

if not DRITUAL then DRITUAL = {} end

-- Shared constants
DRITUAL.FALLBACK_WEAPONS = {
    "weapon_crowbar", "weapon_pistol", "weapon_357", "weapon_smg1",
    "weapon_ar2", "weapon_shotgun", "weapon_crossbow", "weapon_rpg",
    "weapon_frag", "weapon_stunstick"
}

-- Utility functions for common operations
DRITUAL.Utils = {
    -- Safe entity validation with class checking
    IsValidEntity = function(ent, className)
        if not IsValid(ent) then return false end
        if className and ent:GetClass() != className then return false end
        return true
    end,
    
    IsValidPlayer = function(ply)
        return IsValid(ply) and ply:IsPlayer()
    end,
    
    GetConVarValue = function(name, fallback)
        local cv = GetConVar(name)
        if cv and cv.GetFloat then
            return cv:GetFloat()
        end
        return fallback or 0
    end,
    
    -- Safe network sending I think
    SafeNetSend = function(netName, ply, callback)
        if not util.NetworkStringToID then return false end
        local netID = util.NetworkStringToID(netName)
        if netID == 0 then return false end
        
        net.Start(netName)
        if callback then callback() end
        if ply then
            net.Send(ply)
        else
            net.Broadcast()
        end
        return true
    end,
    
    -- Colour utilities
    ColorLerp = function(t, c1, c2)
        return Color(
            Lerp(t, c1.r, c2.r),
            Lerp(t, c1.g, c2.g),
            Lerp(t, c1.b, c2.b),
            Lerp(t, c1.a, c2.a)
        )
    end,
    
    -- Table utilities
    TableCopy = function(t)
        if type(t) != "table" then return t end
        local copy = {}
        for k, v in pairs(t) do
            copy[k] = type(v) == "table" and DRITUAL.Utils.TableCopy(v) or v
        end
        return copy
    end,
    
    -- String utilities
    TruncateString = function(str, maxLen, suffix)
        if not str or string.len(str) <= maxLen then return str end
        suffix = suffix or "..."
        return string.sub(str, 1, maxLen - string.len(suffix)) .. suffix
    end,
    
    -- Math utilities
    Clamp = function(value, min, max)
        return math.Clamp(value, min, max)
    end,
    
    -- Time utilities
    FormatTime = function(seconds)
        local mins = math.floor(seconds / 60)
        local secs = math.floor(seconds % 60)
        if mins > 0 then
            return string.format("%d:%02d", mins, secs)
        else
            return string.format("%ds", secs)
        end
    end,
    
    -- File utilities
    SafeFileRead = function(path, location)
        if not file.Exists(path, location) then return nil end
        
        local success, data = pcall(function()
            return file.Read(path, location)
        end)
        
        if not success then
            ErrorNoHaltWithStack("[dRitual] Failed to read file " .. tostring(path) .. ": " .. tostring(data))
            return nil
        end
        
        return data
    end,
    
    SafeFileWrite = function(path, data, location)
        if not data then return false end
        local success, err = pcall(function()
            return file.Write(path, data, location)
        end)
        if not success then
            ErrorNoHaltWithStack("[dRitual] Failed to write file " .. tostring(path) .. ": " .. tostring(err))
            return false
        end
        return true
    end,
    
    -- JSON utilities with error handling
    SafeJSONToTable = function(json)
        if not json or json == "" then return nil end
        local success, result = pcall(util.JSONToTable, json)
        return success and result or nil
    end,
    
    SafeTableToJSON = function(tbl, pretty)
        if not tbl then return nil end
        local success, result = pcall(util.TableToJSON, tbl, pretty)
        return success and result or nil
    end,
    
    -- UI utilities
    CreateThemedButton = function(parent, text, callback)
        local btn = vgui.Create("DButton", parent)
        btn:SetText(text)
        if callback then
            function btn:DoClick()
                callback(self)
            end
        end
        return btn
    end,
    
    CreateThemedLabel = function(parent, text, font)
        local lbl = vgui.Create("DLabel", parent)
        lbl:SetText(text)
        if font then lbl:SetFont(font) end
        return lbl
    end,
    
    -- Debug utilities if it works
    DebugPrint = function(...)
        if GetConVar("developer"):GetInt() > 0 then
            print("[dRitual]", ...)
        end
    end,
    
    -- Performance utilities
    Throttle = function(func, delay)
        local lastCall = 0
        return function(...)
            local now = CurTime()
            if now - lastCall >= delay then
                lastCall = now
                return func(...)
            end
        end
    end
}

-- Common hook patterns
DRITUAL.Hooks = {
    -- Safe hook removal
    SafeRemove = function(name, id)
        if hook.GetTable()[name] and hook.GetTable()[name][id] then
            hook.Remove(name, id)
        end
    end,
    
    -- Conditional hook addition
    AddConditional = function(name, id, func, condition)
        if condition then
            hook.Add(name, id, func)
        end
    end
}

-- Common validation patterns
DRITUAL.Validation = {
    -- Validate ritual entity
    IsRitualEntity = function(ent)
        return DRITUAL.Utils.IsValidEntity(ent, "dr_ritual_pentagram")
    end,
    
    -- Validate player distance
    IsPlayerInRange = function(ply, ent, maxDist)
        if not DRITUAL.Utils.IsValidPlayer(ply) or not IsValid(ent) then return false end
        local dist = ply:GetPos():DistToSqr(ent:GetPos())
        return dist <= (maxDist or 150) * (maxDist or 150)
    end,
    
    -- Validate trace entity
    IsTraceEntity = function(tr, className)
        if not tr or not IsValid(tr.Entity) then return false end
        if className and tr.Entity:GetClass() != className then return false end
        return true
    end
}

-- PlayerDeath hook management
DRITUAL.DeathHooks = {
    -- Setup PlayerDeath hook for ritual cancellation
    SetupDeathHook = function(ent, ply, callback)
        if not IsValid(ent) or not IsValid(ply) then return end
        
        -- Remove existing hook if any
        if ent.DeathHookId then
            hook.Remove("PlayerDeath", ent.DeathHookId)
            ent.DeathHookId = nil
        end
        
        local deathHookId = "DRITUAL_owner_death_" .. ent:EntIndex()
        ent.DeathHookId = deathHookId
        
        hook.Add("PlayerDeath", deathHookId, function(victim)
            if not IsValid(ent) then 
                hook.Remove("PlayerDeath", deathHookId) 
                return 
            end
            if victim != ply then 
                return 
            end
            if callback then callback() end
        end)
    end,
    
    -- Remove PlayerDeath hook
    RemoveDeathHook = function(ent)
        if ent and ent.DeathHookId then
            hook.Remove("PlayerDeath", ent.DeathHookId)
            ent.DeathHookId = nil
        end
    end
}
