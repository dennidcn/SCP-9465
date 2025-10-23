include("shared.lua")

surface.CreateFont("DRitual_Small", { font = "Tahoma", size = 18, weight = 500, antialias = true, })
surface.CreateFont("DRitual_DialogTitle", { font = "Tahoma", size = 55, weight = 700, antialias = true, })
surface.CreateFont("DRitual_Button", { font = "Tahoma", size = 18, weight = 600, antialias = true, })
surface.CreateFont("DRitual_Subtitle", { font = "Tahoma", size = 14, weight = 500, antialias = true, })
surface.CreateFont("DRitual_Caption", { font = "Tahoma", size = 13, weight = 500, antialias = true, })
surface.CreateFont("DRitual_Banner", { font = "Tahoma", size = 36, weight = 800, antialias = true, })


-- Halo effect system variables
local haloLingerUntil = setmetatable({}, { __mode = "k", })
local halos = {}
local halosInv = {}

-- Default halo colour is configurable in config menu but this is the default colour (dark maroon)
local defaultHaloColor = Color(120, 20, 40)

local function DrawVertGradient(x, y, w, h, c1, c2)
    local steps = 40
    for i = 0, steps - 1 do
        local t = i / (steps - 1)
        local r = Lerp(t, c1.r, c2.r)
        local g = Lerp(t, c1.g, c2.g)
        local b = Lerp(t, c1.b, c2.b)
        local a = Lerp(t, c1.a, c2.a)
        surface.SetDrawColor(r, g, b, a)
        surface.DrawRect(x, y + (h / steps) * i, w, math.ceil(h / steps))
    end
end

-- Cache materials for performance
local cachedMaterial = nil
local cachedMaterialPath = ""

local function GetPentagramMaterial()
    local path = (GetConVar("dr_ritual_material") and GetConVar("dr_ritual_material"):GetString()) or "pentagram/pentagram"
    if string.find(string.lower(path), "dennid", 1, true) then
        path = "pentagram/pentagram"
    end
    
    -- Only recreate if path changed
    if cachedMaterial and cachedMaterialPath == path then
        return cachedMaterial
    end
    
    -- Cache new material
    cachedMaterialPath = path
    cachedMaterial = Material(path)
    if cachedMaterial:IsError() then
        cachedMaterial = Material("pentagram/pentagram")
    end
    
    return cachedMaterial
end

-- NPC and camera focus
local dritualNpcModel = "models/dejtriyev/scaryblackman.mdl" -- As said in TS model is a placeholder as I can't find any semi decent models
local npcGhost
local currentRitualEnt
local camActive = false

-- Camera smoothing state
local camStartPos, camStartAng, camStartFov
local camTargetPos, camTargetAng, camTargetFov
local camBlendStart, camBlendDur
local blinkActive, blinkStart, blinkDur = false, 0, 2.0

-- Vignette looks a little eh
local vignetteRamp = 0.0
local vignetteRampUntil = 0

-- 3D Panel system variables
local worldPanels = {}
local panelSelectionActive = false
local cursorEnabled = false

-- 3D Panel data structure
local panelData = {
    buffs = {}, -- Array of {pos, size, text, key, hovered}
    exit = {pos = Vector(), size = Vector(135, 68), text = "Exit", hovered = false,} -- 35% bigger (100*1.35=135, 50*1.35=68)
}

-- Typing subtitle system
local subtitleText = ""
local subtitleDisplay = ""
local subtitleStartTime = 0
local subtitleDuration = 4.0
local subtitleTypingSpeed = 0.05
local subtitleActive = false
local function StartVignetteRamp(to, dur)
    local target = math.Clamp(to or 1.0, 0, 1)
    local duration = dur or 0.9
    local start = vignetteRamp
    local t0 = CurTime()
    vignetteRampUntil = t0 + duration
    hook.Add("Think", "dr_ritual_vignette_ramp", function()
        local now = CurTime()
        if now >= vignetteRampUntil then 
            vignetteRamp = target 
            hook.Remove("Think", "dr_ritual_vignette_ramp") 
            return 
        end
        local t = (now - t0) / duration
        t = 1 - (1 - t) ^ 3
        vignetteRamp = Lerp(t, start, target)
    end)
end

local function CancelVignetteRamp()
    hook.Remove("Think", "DRITUAL_vignette_ramp")
    vignetteRamp = 0
    vignetteRampUntil = 0
end

local function CleanupNPC()
    if IsValid(npcGhost) then npcGhost:Remove() end
    npcGhost = nil
    camActive = false
    camStartPos, camStartAng, camStartFov = nil, nil, nil
    camTargetPos, camTargetAng, camTargetFov = nil, nil, nil
    camBlendStart, camBlendDur = nil, nil
    CancelVignetteRamp()
    
    -- Clean up 3D panels
    panelData.buffs = {}
    panelData.exit.hovered = false
    panelSelectionActive = false
    
    -- Disable cursor
    gui.EnableScreenClicker(false)
    cursorEnabled = false
    
    -- Stop subtitle
    subtitleActive = false
    
    -- Unlock player movement when dialog ends
    playerLocked = false
end

local function GetNPCFocusPos()
    if not IsValid(npcGhost) then return nil end
    local attNames = { "eyes", "Eye", "head", "forward" }
    for _, n in ipairs(attNames) do
        local idx = npcGhost:LookupAttachment(n)
        if idx and idx > 0 then
            local att = npcGhost:GetAttachment(idx)
            if att and att.Pos then return att.Pos end
        end
    end
    local bone = npcGhost:LookupBone("ValveBiped.Bip01_Head1")
    if bone then
        local m = npcGhost:GetBoneMatrix(bone)
        if m then return m:GetTranslation() end 
    end
    return npcGhost:WorldSpaceCenter()
end

local function pickIdleSequence(ent)
    if not IsValid(ent) then return 0 end
    local candidates = {
        "idle_all", "idle", "idle_subtle", "idle_all_01", "batonidle1", "idle01", "Crouch_idle" 
    }
    for _, name in ipairs(candidates) do
        local idx = ent:LookupSequence(name)
        if idx and idx >= 0 then return idx end
    end
    return 0
end

local function ShowRitualNPC(ent)
    CleanupNPC()
    npcGhost = ClientsideModel(dritualNpcModel, RENDERGROUP_OPAQUE)
    if not IsValid(npcGhost) then return end
    npcGhost:SetNoDraw(false)
    npcGhost:SetIK(false)
    local pos
    local ang
    if IsValid(ent) then
        local mins, maxs = ent:OBBMins(), ent:OBBMaxs()
        local top = Vector(0,0,maxs.z)
        local topW = ent:LocalToWorld(top)
        local foot = npcGhost:OBBMins().z or 0
        pos = topW - Vector(0,0,foot) + Vector(0,0,1)
        local eye = LocalPlayer():EyePos()
        ang = (eye - pos):Angle(); ang.p = 0; ang.r = 0
    else
        pos = LocalPlayer():EyePos() + LocalPlayer():EyeAngles():Forward() * 100
        ang = Angle(0, LocalPlayer():EyeAngles().y, 0)
    end
    npcGhost:SetPos(pos)
    npcGhost:SetAngles(ang)

    local seq = pickIdleSequence(npcGhost)
    npcGhost:ResetSequence(seq)
    npcGhost:SetCycle(0)
    npcGhost:SetPlaybackRate(1)

    -- Frame advance
    hook.Add("Think", "dr_ritual_npc_frameadvance", function()
        if not IsValid(npcGhost) then hook.Remove("Think", "dr_ritual_npc_frameadvance") return end
        npcGhost:FrameAdvance(RealFrameTime())
    end)

    -- Camera anchor increased zoom to focus on NPC
    local face = GetNPCFocusPos() or npcGhost:WorldSpaceCenter()
    local dir = (LocalPlayer():EyePos() - face):GetNormalized()
    camTargetPos = face + dir * 75 + Vector(0,0,8) -- Closer to NPC
    camTargetAng = (face - camTargetPos):Angle()
    camTargetFov = 50 -- Slightly narrower FOV
    -- Smoother animation to focus on npc
    camStartPos = LocalPlayer():EyePos()
    camStartAng = LocalPlayer():EyeAngles()
    camStartFov = (LocalPlayer().GetFOV and LocalPlayer():GetFOV()) or 70
    camBlendStart = CurTime()
    camBlendDur = 0.9
    camActive = true
    -- ensure vignette is on when camera focuses on npc
    if vignetteRamp < 1 then StartVignetteRamp(1.0, (camBlendDur or 0.9) + 0.4) end
    
    -- Trigger subtitle after camera blend completes
    timer.Simple(camBlendDur + 0.1, function()
        if IsValid(npcGhost) and camActive then
            -- Start the subtitle locally
            subtitleText = "What does one desire?"
            subtitleDisplay = ""
            subtitleStartTime = CurTime()
            subtitleActive = true
        end
    end)
end

hook.Add("CalcView", "dr_ritual_dialog_cam", function(ply, origin, angles, fov)
    if not camActive or not IsValid(npcGhost) then return end
    
    -- Completely lock camera when player is locked
    if playerLocked then
        return { origin = camTargetPos, angles = camTargetAng, fov = camTargetFov, drawviewer = false }
    end
    
    local t = 1
    if camBlendStart and camBlendDur and camBlendDur > 0 then
        t = math.Clamp((CurTime() - camBlendStart) / camBlendDur, 0, 1)
        t = 1 - (1 - t)^3
    end
    
    local pos = LerpVector(t, camStartPos or origin, camTargetPos or origin)
    local ang = LerpAngle(t, camStartAng or angles, camTargetAng or angles)
    local vfov = Lerp(t, camStartFov or fov, camTargetFov or fov)
    
    -- Lock camera view when panels are active
    if panelSelectionActive then
        return { origin = pos, angles = ang, fov = vfov, drawviewer = false }
    end
    
    return { origin = pos, angles = ang, fov = vfov, drawviewer = false }
end)

local function StartBlink(d)
    blinkDur = d or 2.0
    blinkStart = CurTime()
    blinkActive = true
end

local function GetCurrentCamView()
    local ply = LocalPlayer()
    local origin = ply:EyePos()
    local angles = ply:EyeAngles()
    local fov = (ply.GetFOV and ply:GetFOV()) or 70
    if not camActive then return origin, angles, fov end
    local t = 1
    if camBlendStart and camBlendDur and camBlendDur > 0 then
        t = math.Clamp((CurTime() - camBlendStart) / camBlendDur, 0, 1)
        t = 1 - (1 - t)^3
    end
    local pos = LerpVector(t, camStartPos or origin, camTargetPos or origin)
    local ang = LerpAngle(t, camStartAng or angles, camTargetAng or angles)
    local vfov = Lerp(t, camStartFov or fov, camTargetFov or fov)
    
    -- Use locked camera position when player is locked
    if playerLocked then
        return camTargetPos or pos, camTargetAng or ang, camTargetFov or vfov
    end
    
    return pos, ang, vfov
end

-- Smoother animation to return to default player view
local function EndFocusSmooth(dur, blinkTime)
    local ply = LocalPlayer()
    local targetPos = ply:EyePos()
    local targetAng = ply:EyeAngles()
    local targetFov = (ply.GetFOV and ply:GetFOV()) or 70
    local curPos, curAng, curFov = GetCurrentCamView()
    
    if not camActive then if blinkTime then StartBlink(blinkTime) end return end
    camStartPos, camStartAng, camStartFov = curPos, curAng, curFov
    camTargetPos, camTargetAng, camTargetFov = targetPos, targetAng, targetFov
    camBlendStart = CurTime()
    camBlendDur = dur or 0.9

    timer.Create("dr_ritual_cam_outro", camBlendDur + 0.01, 1, function()
    CleanupNPC(); camActive = false; CancelVignetteRamp()
    end)
    if blinkTime then StartBlink(blinkTime) end
end

hook.Add("RenderScreenspaceEffects", "dr_ritual_blink_vignette", function()
    local w,h = ScrW(), ScrH()
    -- Edge vignette when camera is active
    if camActive or (vignetteRamp and vignetteRamp > 0) then
        local band = math.floor(math.min(w,h) * 0.5)
        local steps = 64
        local th = math.max(1, math.floor(band/steps))
        for i=0,steps-1 do
            local a = math.floor(255 * (1 - i/(steps-1))^1.6 * math.Clamp(vignetteRamp, 0, 1))
            if a <= 0 then break end
            surface.SetDrawColor(0,0,0,a)
            surface.DrawRect(0, i*th, w, th)
            surface.DrawRect(0, h - (i+1)*th, w, th)
            surface.DrawRect(i*th, 0, th, h)
            surface.DrawRect(w - (i+1)*th, 0, th, h)
        end
    end
    -- Blink
    if blinkActive then
        local t = CurTime() - blinkStart
        if t >= blinkDur then blinkActive = false return end
        local tn = t / math.max(0.0001, blinkDur)
        local function Tri(c, hw) local d = math.abs(tn - c); return math.max(0, 1 - d/hw) end
        local alpha = math.Clamp((Tri(0.25,0.22) + 0.85*Tri(0.70,0.28))*255, 0, 255)
        surface.SetDrawColor(0,0,0,alpha)
        surface.DrawRect(0,0,w,h)
    end
end)

function ENT:Draw()
    -- Enable halo if looking at pentagram or if ritual is active
    if self:BeingLookedAtByLocalPlayer() or self:GetIsActive() or (haloLingerUntil[self] and haloLingerUntil[self] > CurTime()) then
        if self.RenderGroup == RENDERGROUP_OPAQUE then
            self.OldRenderGroup = self.RenderGroup
            self.RenderGroup = RENDERGROUP_TRANSLUCENT
        end
        self:DrawEntityOutline()
    else
        if self.OldRenderGroup then
            self.RenderGroup = self.OldRenderGroup
            self.OldRenderGroup = nil
        end
    end
    
    render.SetColorModulation(0,0,0)
    self:DrawModel()
    render.SetColorModulation(1,1,1)
end

function ENT:DrawTranslucent()
    self:Draw()
end

-- Halo effect system for pentagram outline glow

-- Get halo color from config or use default
local function GetHaloColor()
    if DRITUAL and DRITUAL.Config and DRITUAL.Config.haloColor then
        local c = DRITUAL.Config.haloColor
        return Color(c.r or 120, c.g or 20, c.b or 40)
    end
    return defaultHaloColor
end

-- Check if player is looking at pentagram
function ENT:BeingLookedAtByLocalPlayer()
    local ply = LocalPlayer()
    if not IsValid(ply) then return false end
    
    local trace = ply:GetEyeTrace()
    return trace.Entity == self
end

-- Add entity to halo queue
function ENT:DrawEntityOutline()
    if halosInv[self] then return end
    halos[#halos+1] = self
    halosInv[self] = true
end

-- PreDrawHalos hook to render pentagram halos
hook.Add("PreDrawHalos", "dr_ritual_pentagram_halo", function()
    if #halos == 0 then return end
    
    local haloColor = GetHaloColor()
    local now = CurTime()
    local activeHalos = {}
    local normalHalos = {}
    
    -- Separate active/linger pentagrams from normal ones
    for _, ent in ipairs(halos) do
        if IsValid(ent) and ent:GetClass() == "dr_ritual_pentagram" then
            local active = ent:GetIsActive()
            local linger = haloLingerUntil[ent] and haloLingerUntil[ent] > now
            
            if active or linger then
                table.insert(activeHalos, ent)
            else
                table.insert(normalHalos, ent)
            end
        end
    end
    
    if #normalHalos > 0 then
        halo.Add(normalHalos, haloColor, 2, 2, 1, true, true)
    end
    
    if #activeHalos > 0 then
        local maxAlpha = 255
        for _, ent in ipairs(activeHalos) do
            if haloLingerUntil[ent] and haloLingerUntil[ent] > now then
                local timeLeft = haloLingerUntil[ent] - now
                local alpha = math.Clamp(timeLeft / 5.0, 0, 1)
                maxAlpha = math.min(maxAlpha, alpha * 255)
            end
        end
        
        local activeColor = Color(haloColor.r, haloColor.g, haloColor.b, maxAlpha)
        halo.Add(activeHalos, activeColor, 5, 5, 3, true, true)
    end
    
    halos = {}
    halosInv = {}
end)

local activeData = { ent = nil, deadline = 0, items = nil }

net.Receive("dr_ritual_begin", function()
    local ent = net.ReadEntity()
    local deadline = net.ReadFloat()
    local count = net.ReadUInt(5)
    local items = {}

    for i=1,count do
        local cls = net.ReadString()
        local isEntity = net.ReadBool()
        local disp = net.ReadString()
        local pretty = isEntity and ("[E] " .. disp) or disp
        items[i] = { class = cls, name = pretty, done = false, isEntity = isEntity }
    end

    activeData.ent = ent; activeData.deadline = deadline; activeData.items = items
    CleanupNPC(); camActive = false; StartBlink(2.0)
    CancelVignetteRamp()
end)

net.Receive("dr_ritual_progress", function()
    local ent = net.ReadEntity(); if ent != activeData.ent then return end
    local cls = net.ReadString(); net.ReadUInt(5)
    if activeData.items then for _,it in ipairs(activeData.items) do if it.class==cls then it.done=true break end end end
    surface.PlaySound("buttons/button14.wav")
end)

local function ClearActive()
    activeData.ent = nil; activeData.items = nil; activeData.deadline = 0
end

net.Receive("dr_ritual_success", function()
    local ent = net.ReadEntity()
    print("Received dr_ritual_success for entity " .. ent:EntIndex())
    print("Current activeData.ent: " .. (IsValid(activeData.ent) and activeData.ent:EntIndex() or "nil"))
    if activeData.ent == ent then 
        print("Clearing active data")
        ClearActive() 
    end
    surface.PlaySound("ambient/machines/thumper_dust.wav")
    haloLingerUntil[ent] = CurTime() + 5
    CleanupNPC(); camActive = false; StartBlink(2.2)
    CancelVignetteRamp()
end)

net.Receive("dr_ritual_fail", function()
    local ent = net.ReadEntity(); if activeData.ent == ent then ClearActive() end
    surface.PlaySound("ambient/energy/zap9.wav")
    haloLingerUntil[ent] = CurTime() + 5
    CleanupNPC(); camActive = false; StartBlink(2.2)
    CancelVignetteRamp()
end)

net.Receive("dr_ritual_cancel", function()
    local ent = net.ReadEntity(); if activeData.ent == ent then ClearActive() end
    haloLingerUntil[ent] = CurTime() + 5
    CleanupNPC(); camActive = false
    CancelVignetteRamp()
end)

-- Immunity tint
local immunityActive, immunityEnds = false, 0
net.Receive("dr_ritual_immunity_state", function()
    immunityActive = net.ReadBool(); immunityEnds = net.ReadFloat()
end)
hook.Add("RenderScreenspaceEffects", "dr_ritual_immunity_tint", function()
    if not immunityActive then return end
    if CurTime() > immunityEnds then immunityActive = false return end
    surface.SetDrawColor(121,224,238,120)
    surface.DrawRect(0,0,ScrW(),ScrH())
end)

local moveBackUntil = 0
net.Receive("dr_ritual_move_back", function()
    moveBackUntil = CurTime() + 2.2

    CancelVignetteRamp()
end)

local noMoreUntil = 0
net.Receive("dr_ritual_no_more", function()
    noMoreUntil = CurTime() + 2.2
    CancelVignetteRamp()
    CleanupNPC(); camActive = false
end)

net.Receive("dr_ritual_cancel_vignette", function()
    CancelVignetteRamp()
    CleanupNPC(); camActive = false
end)
hook.Add("HUDPaint", "dr_ritual_no_more_banner", function()
    if CurTime() > noMoreUntil then return end
    local w, h = ScrW(), ScrH()
    local bw, bh = 520, 72
    local x, y = (w - bw)/2, math.floor(h * 0.10)
    draw.RoundedBox(8, x, y, bw, bh, Color(0,0,0,230))
    draw.SimpleText("NO MORE", "DRitual_Banner", x + bw/2, y + bh/2, Color(255,80,80), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)
hook.Add("HUDPaint", "dr_ritual_move_back_banner", function()
    if CurTime() > moveBackUntil then return end
    local w, h = ScrW(), ScrH()
    local bw, bh = 520, 72
    local x, y = (w - bw)/2, math.floor(h * 0.10)
    draw.RoundedBox(8, x, y, bw, bh, Color(0,0,0,230))
    draw.SimpleText("MOVE BACK", "DRitual_Banner", x + bw/2, y + bh/2, Color(255,255,255), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)


-- C menu detection for UI visibility
local cMenuOpen = false
hook.Add("OnContextMenuOpen", "dr_ritual_c_menu_open", function()
    cMenuOpen = true
end)

hook.Add("OnContextMenuClose", "dr_ritual_c_menu_close", function()
    cMenuOpen = false
end)

-- Draggable UI position
local uiPos = {x = 0, y = 0} -- Will be set to default position on first use
local isDragging = false
local dragOffset = {x = 0, y = 0}
local panelSize = 300
local padding = 20

-- Load saved position
local function LoadUIPosition()
    if file.Exists("dritual_ui_pos.txt", "DATA") then
        local success, data = pcall(function()
            return file.Read("dritual_ui_pos.txt", "DATA")
        end)
        
        if success and data then
            local jsonSuccess, pos = pcall(function()
                return util.JSONToTable(data)
            end)
            
            if jsonSuccess and pos and pos.x and pos.y then
                uiPos.x = pos.x
                uiPos.y = pos.y
                return
            end
        else
            ErrorNoHaltWithStack("[dRitual] Failed to read UI position: " .. tostring(data))
        end
    end
    -- Default position is at the top-right of the screen
    uiPos.x = ScrW() - panelSize - padding
    uiPos.y = padding
end

-- Save UI position
local function SaveUIPosition()
    local data = util.TableToJSON(uiPos)
    local success, err = pcall(function()
        file.Write("dritual_ui_pos.txt", data)
    end)
    
    if not success then
        ErrorNoHaltWithStack("[dRitual] Failed to save UI position: " .. tostring(err))
    end
end

-- Initialize position
LoadUIPosition()

-- Mouse interaction for dragging only works when c menu open
hook.Add("GUIMousePressed", "dr_ritual_ui_drag", function(mouseCode)
    if mouseCode != MOUSE_LEFT or not cMenuOpen then return end
    
    local ent = activeData.ent
    if not IsValid(ent) then return end
    
    local mx, my = gui.MouseX(), gui.MouseY()
    
    -- Check if mouse is over the panel
    if mx >= uiPos.x and mx <= uiPos.x + panelSize and 
       my >= uiPos.y and my <= uiPos.y + panelSize then
        isDragging = true
        dragOffset.x = mx - uiPos.x
        dragOffset.y = my - uiPos.y
    end
end)

hook.Add("GUIMouseReleased", "dr_ritual_ui_drag_end", function(mouseCode)
    if mouseCode != MOUSE_LEFT then return end
    
    if isDragging then
        isDragging = false
        SaveUIPosition()
    end
end)

hook.Add("Think", "dr_ritual_ui_drag_update", function()
    if not isDragging or not cMenuOpen then return end
    
    local mx, my = gui.MouseX(), gui.MouseY()
    local w, h = ScrW(), ScrH()
    
    -- Update position with drag offset
    uiPos.x = mx - dragOffset.x
    uiPos.y = my - dragOffset.y
    
    -- dont let the panel escape
    uiPos.x = math.Clamp(uiPos.x, 0, w - panelSize)
    uiPos.y = math.Clamp(uiPos.y, 0, h - panelSize)
end)

hook.Add("HUDPaint", "dr_ritual_hud", function()
    local ent = activeData.ent; if not IsValid(ent) then return end
    
    
    local total = 120; local cv = GetConVar and GetConVar("dr_ritual_time"); if cv and cv.GetFloat then total = math.max(1, cv:GetFloat()) end
    local remain = math.max(0, math.floor(activeData.deadline - CurTime()))
    local frac = math.Clamp((activeData.deadline - CurTime())/total, 0, 1)

    local w, h = ScrW(), ScrH()
    local bx, by = uiPos.x, uiPos.y
    
    -- Main panel background
    local bgColor = isDragging and Color(DRITUAL.Theme.panel.r, DRITUAL.Theme.panel.g, DRITUAL.Theme.panel.b, DRITUAL.Theme.panel.a + 30) or DRITUAL.Theme.panel
    draw.RoundedBox(10, bx, by, panelSize, panelSize, bgColor)
    surface.SetDrawColor(DRITUAL.Theme.border)
    surface.DrawOutlinedRect(bx, by, panelSize, panelSize, 1)
    
    -- Header section
    local headerHeight = 60
    local headerY = by + 10
    draw.SimpleText("Ritual Progress", "DRitual_Small", bx + 15, headerY, DRITUAL.Theme.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    draw.SimpleText(remain.."s left", "DRitual_Small", bx + 15, headerY + 20, DRITUAL.Theme.textDim, TEXT_ALIGN_LEFT, TEXT_ALIGN_TOP)
    
    -- Items section
    local itemsStartY = by + headerHeight + 10
    local itemsHeight = 180
    local itemHeight = 40
    local items = activeData.items
    if items and #items > 0 then
        surface.SetFont("DRitual_Caption")
        for i, it in ipairs(items) do
            local itemY = itemsStartY + (i-1) * itemHeight
            if itemY + itemHeight <= by + headerHeight + itemsHeight then -- Only render if within visible area
                local done = it.done
                local bg = done and Color(30, 56, 40, 240) or Color(56, 30, 30, 240)
                local br = done and Color(120,205,150,200) or Color(220,120,120,200)
                local tx = it.name or it.class or "?"
                
                -- Item background
                draw.RoundedBox(6, bx + 10, itemY, panelSize - 20, itemHeight - 5, bg)
                surface.SetDrawColor(br)
                surface.DrawOutlinedRect(bx + 10, itemY, panelSize - 20, itemHeight - 5, 1)
                
                -- Item icon and text
                local icon = done and "\226\156\148" or "\226\157\151"
                draw.SimpleText(icon, "DRitual_Caption", bx + 20, itemY + (itemHeight-5)/2, br, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
                draw.SimpleText(tx, "DRitual_Caption", bx + 40, itemY + (itemHeight-5)/2, DRITUAL.Theme.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            end
        end
    end
    
    -- Footer section with progress bar
    local footerY = by + panelSize - 60
    local progressBarHeight = 8
    local progressBarY = footerY + 20
    local progressBarW = panelSize - 20
    
    -- Progress bar background
    draw.RoundedBox(4, bx + 10, progressBarY, progressBarW, progressBarHeight, Color(40, 40, 40, 200))
    
    -- Progress bar fill
    local progressW = math.floor(progressBarW * (1-frac))
    if progressW > 0 then
        DrawVertGradient(bx + 10, progressBarY, progressW, progressBarHeight, Color(60,140,255,200), Color(60,140,255,120))
    end
    
    -- Progress text
    local progressText = math.floor(frac * 100) .. "%"
    draw.SimpleText(progressText, "DRitual_Caption", bx + panelSize/2, progressBarY + progressBarHeight + 5, DRITUAL.Theme.textDim, TEXT_ALIGN_CENTER, TEXT_ALIGN_TOP)
end)

-- Helper function to get buff display names
local function GetBuffDisplayName(key)


    if DRITUAL and DRITUAL.Config and DRITUAL.Config.buffDisplayNames and DRITUAL.Config.buffDisplayNames[key] then
        return DRITUAL.Config.buffDisplayNames[key]
    end
    
    -- Then check registry titles
    if DRITUAL and DRITUAL.Buffs and DRITUAL.Buffs[key] and DRITUAL.Buffs[key].title then
        return DRITUAL.Buffs[key].title
    end
    
    -- Fall back to defaults
    local pretty = {
        hp = "More health",
        speed = "Faster sprint speed", 
        jump = "Higher jump",
        weapon = "New weapon",
        ammo = "Unlimited ammo",
        immunity = "Invulnerability",
    }
    
    return pretty[key] or key
end

-- Create 3D world panels
local function CreateWorldPanels(ent, offered)
    if not IsValid(npcGhost) then return end
    
    -- Clear existing panels
    panelData.buffs = {}
    
    -- Get NPC head position for panel positioning
    local headPos = GetNPCFocusPos() or npcGhost:WorldSpaceCenter()
    local npcAng = npcGhost:GetAngles()
    
    -- Panel positions relative to NPC head - moved down a bit
    local panelPositions = {
        {pos = headPos + Vector(0, 0, 8)}, 
        {pos = headPos + npcAng:Right() * -12 + Vector(0, 0, 0)},
        {pos = headPos + npcAng:Right() * 12 + Vector(0, 0, 0)},
    }
    
    -- Create buff panel data
    for i = 1, 3 do
        if offered[i] then
            local buffKey = offered[i]
            local buffTitle = GetBuffDisplayName(buffKey)
            
            table.insert(panelData.buffs, {
                pos = panelPositions[i].pos,
                size = Vector(162, 81),
                text = buffTitle,
                key = buffKey,
                hovered = false
            })
        end
    end
    
    -- Set exit panel position closer to bottom of screen
    panelData.exit.pos = headPos + npcAng:Forward() * 15 + Vector(0, 0, -15)
    
    -- Enable cursor and mark selection as active
    gui.EnableScreenClicker(true)
    cursorEnabled = true
    panelSelectionActive = true
end

-- Render 3D panels
local function Render3DPanels()
    if not panelSelectionActive or not IsValid(npcGhost) then return end
    
    -- Use locked camera position when player is locked, otherwise use player position
    local playerPos = playerLocked and (camTargetPos or LocalPlayer():EyePos()) or LocalPlayer():EyePos()
    
    
    -- Render buff panels
    for i, buffPanel in ipairs(panelData.buffs) do
        local panelPos = buffPanel.pos
        local dir = (playerPos - panelPos):GetNormalized()
        local angle = dir:Angle()
        
        -- Fix the angle to make panels face the player properly
        angle:RotateAroundAxis(angle:Right(), -90)
        angle:RotateAroundAxis(angle:Up(), 90)
        
        -- Check if mouse is hovering over this panel
        local screenPos = panelPos:ToScreen()
        local mouseX, mouseY = gui.MouseX(), gui.MouseY()
        local hovered = (screenPos.visible and math.abs(screenPos.x - mouseX) < 108 and math.abs(screenPos.y - mouseY) < 54)
        buffPanel.hovered = hovered
        
        
        -- Only render if panel is visible on screen
        if screenPos.visible then
            -- Render panel
            cam.Start3D2D(panelPos, angle, 0.05)
                local w, h = buffPanel.size.x, buffPanel.size.y
                local bgColor = hovered and Color(60, 70, 80, 200) or Color(40, 50, 60, 180)
                local borderColor = hovered and DRITUAL.Theme.progress or DRITUAL.Theme.border
                
                draw.RoundedBox(8, -w/2, -h/2, w, h, bgColor)
                surface.SetDrawColor(borderColor)
                surface.DrawOutlinedRect(-w/2, -h/2, w, h, 2)
                
                draw.SimpleText(buffPanel.text, "DRitual_Button", 0, 0, DRITUAL.Theme.text, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
                draw.SimpleText(tostring(i), "DRitual_Subtitle", w/2-8, h/2-8, DRITUAL.Theme.textDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_BOTTOM)
            cam.End3D2D()
        end
    end
    
    -- Render exit panel
    local exitPanel = panelData.exit
    local panelPos = exitPanel.pos
    local dir = (playerPos - panelPos):GetNormalized()
    local angle = dir:Angle()
    
    -- Fix the angle to make exit panel face the player properly
    angle:RotateAroundAxis(angle:Right(), -90)
    angle:RotateAroundAxis(angle:Up(), 90)
    
    -- Check if mouse is hovering over exit panel
    local screenPos = panelPos:ToScreen()
    local mouseX, mouseY = gui.MouseX(), gui.MouseY()
    local hovered = (screenPos.visible and math.abs(screenPos.x - mouseX) < 81 and math.abs(screenPos.y - mouseY) < 41) -- Adjusted for 35% bigger exit panel
    exitPanel.hovered = hovered
    
    
    -- Only render if panel is visible on screen
    if screenPos.visible then
        -- Render exit panel
        cam.Start3D2D(panelPos, angle, 0.05) -- Smaller scale for better visibility
            local w, h = exitPanel.size.x, exitPanel.size.y
            local bgColor = hovered and Color(80, 40, 40, 200) or Color(60, 30, 30, 180)
            local borderColor = hovered and Color(255, 120, 120) or Color(255, 90, 90)
            
            draw.RoundedBox(6, -w/2, -h/2, w, h, bgColor)
            surface.SetDrawColor(borderColor)
            surface.DrawOutlinedRect(-w/2, -h/2, w, h, 2)
            
            draw.SimpleText("Exit", "DRitual_Button", 0, 0, Color(255, 150, 150), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
        cam.End3D2D()
    end
end

-- Hook to render 3D panels
hook.Add("PostDrawTranslucentRenderables", "dr_ritual_3d_panels", function()
    Render3DPanels()
end)

-- Mouse click detection for 3D panels
hook.Add("GUIMousePressed", "dr_ritual_panel_clicks", function(mouseCode)
    if mouseCode != MOUSE_LEFT or not panelSelectionActive then return end
    
    local ent = currentRitualEnt
    if not IsValid(ent) then return end
    
    -- Check buff panels
    for i, buffPanel in ipairs(panelData.buffs) do
        if not buffPanel.hovered then continue end
        
        -- Clean up panels and cursor
        panelData.buffs = {}
        panelData.exit.hovered = false
        panelSelectionActive = false
        gui.EnableScreenClicker(false)
        cursorEnabled = false
        
        EndFocusSmooth(0.9, 1.2)
        CancelVignetteRamp()
        net.Start("dr_ritual_pickbuff") net.WriteEntity(ent) net.WriteString(buffPanel.key) net.SendToServer()
        return
    end
    
    -- Check exit panel
    if panelData.exit.hovered then
        -- Clean up panels and cursor
        panelData.buffs = {}
        panelData.exit.hovered = false
        panelSelectionActive = false
        gui.EnableScreenClicker(false)
        cursorEnabled = false
        
        EndFocusSmooth(0.9, 1.2)
        CancelVignetteRamp()
        net.Start("dr_ritual_cancelbuff") net.WriteEntity(ent) net.SendToServer()
        
        -- Start knockback sequence
        local t = CurTime() + 1.2
        timer.Create("dr_ritual_cancel_kb_" .. ent:EntIndex(), 0.05, 0, function()
            if CurTime() >= t then
                timer.Remove("dr_ritual_cancel_kb_" .. ent:EntIndex())
                net.Start("dr_ritual_cancel_knockback") net.WriteEntity(ent) net.SendToServer()
            end
        end)
    end
end)

local function OpenBuffUI(ent, offered)
    currentRitualEnt = ent
    ShowRitualNPC(ent)
    
    -- Wait for subtitle to finish before showing panels
    timer.Simple(subtitleDuration + 0.5, function()
        if IsValid(npcGhost) and camActive then
            CreateWorldPanels(ent, offered)
        end
    end)
end

net.Receive("dr_ritual_offerbuff", function()
    local ent = net.ReadEntity(); if not IsValid(ent) then return end
    local count = net.ReadUInt(3)
    local offered = {}
    for i=1,count do offered[i] = net.ReadString() end
    OpenBuffUI(ent, offered)
end)


net.Receive("dr_ritual_vignette_ramp", function()
    StartVignetteRamp(0.35, net.ReadFloat() or 1.0)
end)

-- Player lock state
local playerLocked = false
net.Receive("dr_ritual_player_lock", function()
    playerLocked = net.ReadBool()
end)

-- Hook to disable player movement when locked
hook.Add("SetupMove", "dr_ritual_player_lock", function(ply, mv, cmd)
    if ply != LocalPlayer() then return end
    if not playerLocked then return end
    if not camActive then 
        playerLocked = false
        return 
    end
    
    -- Disable all movement
    mv:SetForwardSpeed(0)
    mv:SetSideSpeed(0)
    mv:SetUpSpeed(0)
    mv:SetMaxSpeed(0)
    mv:SetMaxClientSpeed(0)
    -- disables mouse looking around
    mv:SetAngles(camTargetAng or ply:EyeAngles())
end)

-- Disable input when locked
hook.Add("PlayerBindPress", "dr_ritual_disable_input", function(ply, bind, pressed)
    if ply != LocalPlayer() then return end
    if not playerLocked then return end
    if not camActive then 
        playerLocked = false
        return false
    end
    
    -- Allow only specific keys for UI interaction
    if bind == "attack" or bind == "attack2" or bind == "jump" or bind == "use" then
        return false -- Allow these keys
    end
    
    -- Block all other input
    return true
end)

-- Hook to unlock player on death
hook.Add("PlayerDeath", "dr_ritual_player_unlock_on_death", function(victim)
    if victim != LocalPlayer() then return end
    if playerLocked then
        playerLocked = false
    end
end)

net.Receive("dr_ritual_subtitle_trigger", function()
    subtitleText = "What does one desire?"
    subtitleDisplay = ""
    subtitleStartTime = CurTime()
    subtitleActive = true
end)

hook.Add("HUDPaint", "dr_ritual_prompt", function()
    local lp = LocalPlayer(); if not IsValid(lp) then return end
    local tr = lp:GetEyeTrace(); if not tr or not IsValid(tr.Entity) then return end
    local ent = tr.Entity; if ent:GetClass() != "dr_ritual_pentagram" then return end
    if tr.HitPos:DistToSqr(lp:GetShootPos()) > (150*150) then return end
    local text = "Press E to begin the ██████"
    if ent:GetIsActive() then text = "Press E to offer your held weapon"
    elseif ent:GetIsChanneling() then text = "Channeling..." end
    draw.SimpleTextOutlined(text, "DRitual_Small", ScrW()/2, ScrH()*0.74, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, Color(0,0,0,200))
end)

-- Typing subtitle render
hook.Add("HUDPaint", "dr_ritual_subtitle", function()
    if not subtitleActive then return end
    
    local elapsed = CurTime() - subtitleStartTime
    local textLen = string.len(subtitleText)
    local targetLen = math.floor(elapsed / subtitleTypingSpeed)
    
    -- Update displayed text with typing effect
    if targetLen <= textLen then
        subtitleDisplay = string.sub(subtitleText, 1, targetLen)
    else
        subtitleDisplay = subtitleText
    end
    
    -- Check if we should stop showing subtitle
    if elapsed >= subtitleDuration then
        subtitleActive = false
        return
    end
    
    local alpha = 255
    if elapsed >= (subtitleDuration - 1.0) then
        alpha = math.floor(255 * (subtitleDuration - elapsed))
    end
    
    -- Draw subtitle at bottom center
    local w, h = ScrW(), ScrH()
    local textW, textH = surface.GetTextSize(subtitleDisplay)
    local x, y = w/2, h - 120
    
    -- Background box
    local boxW, boxH = textW + 40, textH + 20
    draw.RoundedBox(8, x - boxW/2, y - boxH/2, boxW, boxH, Color(0, 0, 0, math.floor(alpha * 0.8)))
    
    -- Text
    draw.SimpleText(subtitleDisplay, "DRitual_DialogTitle", x, y, Color(255, 255, 255, alpha), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
end)

hook.Add("KeyPress", "dr_ritual_e", function(ply, key)
    if ply != LocalPlayer() or key != IN_USE then return end
    local tr = ply:GetEyeTrace(); if not tr or not IsValid(tr.Entity) then return end
    local ent = tr.Entity; if ent:GetClass() != "dr_ritual_pentagram" then return end
    if tr.HitPos:DistToSqr(ply:GetShootPos()) > (150*150) then return end
   
    StartVignetteRamp(0.35, 1.4)
    if ent:GetIsActive() then
        net.Start("dr_ritual_try_sacrifice") net.WriteEntity(ent) net.SendToServer()
    elseif (not ent:GetIsChanneling()) then
    end
end)

