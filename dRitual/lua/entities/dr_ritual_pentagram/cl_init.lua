include("shared.lua")

surface.CreateFont("DRitual_Small", { font = "Tahoma", size = 18, weight = 500, antialias = true })
surface.CreateFont("DRitual_DialogTitle", { font = "Tahoma", size = 22, weight = 700, antialias = true })
surface.CreateFont("DRitual_Button", { font = "Tahoma", size = 18, weight = 600, antialias = true })
surface.CreateFont("DRitual_Subtitle", { font = "Tahoma", size = 14, weight = 500, antialias = true })
surface.CreateFont("DRitual_Caption", { font = "Tahoma", size = 13, weight = 500, antialias = true })
surface.CreateFont("DRitual_Banner", { font = "Tahoma", size = 36, weight = 800, antialias = true })

local THEME = {
    bg = Color(16,20,28,230),
    panel = Color(22,27,36,250),
    border = Color(255,255,255,18),
    text = Color(220,228,236,255),
    textDim = Color(170,180,192,235),
    accent = Color(80,160,255,255),
    glow = Color(60,120,220,16)
}

local function DrawVertGradient(x,y,w,h, c1, c2)
    local steps = 40
    for i=0,steps-1 do
        local t = i/(steps-1)
        local r = Lerp(t, c1.r, c2.r)
        local g = Lerp(t, c1.g, c2.g)
        local b = Lerp(t, c1.b, c2.b)
        local a = Lerp(t, c1.a, c2.a)
        surface.SetDrawColor(r,g,b,a)
        surface.DrawRect(x, y + (h/steps)*i, w, math.ceil(h/steps))
    end
end

local function GetPentagramMaterial()
    local path = (GetConVar("dr_ritual_material") and GetConVar("dr_ritual_material"):GetString()) or "pentagram/pentagram"
    if string.find(string.lower(path), "dennid", 1, true) then
        path = "pentagram/pentagram"
    end
    local mat = Material(path)
    if mat and mat:IsError() then
        mat = Material("pentagram/pentagram")
    end
    return mat
end

-- NPC and camera focus
local DRITUAL_NPC_MODEL = "models/dejtriyev/scaryblackman.mdl"
local npcGhost
local currentRitualEnt
local camActive = false
-- Camera smoothing state
local camStartPos, camStartAng, camStartFov
local camTargetPos, camTargetAng, camTargetFov
local camBlendStart, camBlendDur
local blinkActive, blinkStart, blinkDur = false, 0, 2.0
-- Vignette
local vignetteRamp = 0.0
local vignetteRampUntil = 0
local function StartVignetteRamp(to, dur)
    local target = math.Clamp(to or 1.0, 0, 1)
    local duration = dur or 0.9
    local start = vignetteRamp
    local t0 = CurTime()
    vignetteRampUntil = t0 + duration
    hook.Add("Think", "dr_ritual_vignette_ramp", function()
        local now = CurTime()
        if now >= vignetteRampUntil then vignetteRamp = target hook.Remove("Think", "dr_ritual_vignette_ramp") return end
        local t = (now - t0) / duration
        t = 1 - (1 - t)^3
        vignetteRamp = Lerp(t, start, target)
    end)
end

local function CancelVignetteRamp()
    hook.Remove("Think", "dr_ritual_vignette_ramp")
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
    npcGhost = ClientsideModel(DRITUAL_NPC_MODEL, RENDERGROUP_OPAQUE)
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

    -- Camera anchor
    local face = GetNPCFocusPos() or npcGhost:WorldSpaceCenter()
    local dir = (LocalPlayer():EyePos() - face):GetNormalized()
    camTargetPos = face + dir * 60 + Vector(0,0,6)
    camTargetAng = (face - camTargetPos):Angle()
    camTargetFov = 42
    -- Smoother animation to focus on npc
    camStartPos = LocalPlayer():EyePos()
    camStartAng = LocalPlayer():EyeAngles()
    camStartFov = (LocalPlayer().GetFOV and LocalPlayer():GetFOV()) or 70
    camBlendStart = CurTime()
    camBlendDur = 0.9
    camActive = true
    -- ensure vignette is on when camera focuses
    if vignetteRamp < 1 then StartVignetteRamp(1.0, (camBlendDur or 0.9) + 0.4) end
end

hook.Add("CalcView", "dr_ritual_dialog_cam", function(ply, origin, angles, fov)
    if not camActive or not IsValid(npcGhost) then return end
    local t = 1
    if camBlendStart and camBlendDur and camBlendDur > 0 then
        t = math.Clamp((CurTime() - camBlendStart) / camBlendDur, 0, 1)
        t = 1 - (1 - t)^3
    end
    local pos = LerpVector(t, camStartPos or origin, camTargetPos or origin)
    local ang = LerpAngle(t, camStartAng or angles, camTargetAng or angles)
    local vfov = Lerp(t, camStartFov or fov, camTargetFov or fov)
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
        local function tri(c, hw) local d = math.abs(tn - c); return math.max(0, 1 - d/hw) end
        local alpha = math.Clamp((tri(0.25,0.22) + 0.85*tri(0.70,0.28))*255, 0, 255)
        surface.SetDrawColor(0,0,0,alpha)
        surface.DrawRect(0,0,w,h)
    end
end)

function ENT:Draw()
    render.SetColorModulation(0,0,0)
    self:DrawModel()
    render.SetColorModulation(1,1,1)
end
function ENT:DrawTranslucent()
    render.SetColorModulation(0,0,0)
    self:DrawModel()
    render.SetColorModulation(1,1,1)
end

-- Red glow, active for 5 seconds after deal is finished
local redGlowMat = Material("sprites/light_glow02_add")
local redLingerUntil = setmetatable({}, { __mode = "k" })
hook.Add("PostDrawTranslucentRenderables", "dr_ritual_world_redglow", function()
    local now = CurTime()
    for _, ent in ipairs(ents.FindByClass("dr_ritual_pentagram")) do
        if not IsValid(ent) then continue end
        local active = ent:GetIsActive()
        local linger = redLingerUntil[ent] and redLingerUntil[ent] > now
        if not active and not linger then continue end
        local pos = ent:LocalToWorld(Vector(0,0, ent:OBBMaxs().z + 2))
        local dl = DynamicLight(ent:EntIndex())
        if dl then dl.pos=pos dl.r=255 dl.g=60 dl.b=60 dl.brightness=2 dl.Decay=1000 dl.Size=220 dl.DieTime=now+0.15 end
        render.SetMaterial(redGlowMat)
        render.DrawSprite(pos, 80, 80, Color(255,70,70,200))
    end
end)

local activeData = { ent = nil, deadline = 0, items = nil }

net.Receive("dr_ritual_begin", function()
    local ent = net.ReadEntity()
    local deadline = net.ReadFloat()
    local count = net.ReadUInt(5)
    local items = {}
    for i=1,count do items[i] = { class = net.ReadString(), done = false } end
    activeData.ent = ent; activeData.deadline = deadline; activeData.items = items
    CleanupNPC(); camActive = false; StartBlink(2.0)
    CancelVignetteRamp()
end)

net.Receive("dr_ritual_progress", function()
    local ent = net.ReadEntity(); if ent ~= activeData.ent then return end
    local cls = net.ReadString(); net.ReadUInt(5)
    if activeData.items then for _,it in ipairs(activeData.items) do if it.class==cls then it.done=true break end end end
    surface.PlaySound("buttons/button14.wav")
end)

local function ClearActive()
    activeData.ent = nil; activeData.items = nil; activeData.deadline = 0
end

net.Receive("dr_ritual_success", function()
    local ent = net.ReadEntity(); if activeData.ent == ent then ClearActive() end
    surface.PlaySound("ambient/machines/thumper_dust.wav")
    redLingerUntil[ent] = CurTime() + 5
    CleanupNPC(); camActive = false; StartBlink(2.2)
    CancelVignetteRamp()
end)

net.Receive("dr_ritual_fail", function()
    local ent = net.ReadEntity(); if activeData.ent == ent then ClearActive() end
    surface.PlaySound("ambient/energy/zap9.wav")
    redLingerUntil[ent] = CurTime() + 5
    CleanupNPC(); camActive = false; StartBlink(2.2)
    CancelVignetteRamp()
end)

net.Receive("dr_ritual_cancel", function()
    local ent = net.ReadEntity(); if activeData.ent == ent then ClearActive() end
    redLingerUntil[ent] = CurTime() + 5
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

hook.Add("HUDPaint", "dr_ritual_hud", function()
    local ent = activeData.ent; if not IsValid(ent) then return end
    local total = 120; local cv = GetConVar and GetConVar("dr_ritual_time"); if cv and cv.GetFloat then total = math.max(1, cv:GetFloat()) end
    local remain = math.max(0, math.floor(activeData.deadline - CurTime()))
    local frac = math.Clamp((activeData.deadline - CurTime())/total, 0, 1)

    local w, h = ScrW(), ScrH()
    local bw, bh = math.min(560, math.floor(w*0.42)), 84
    local bx, by = math.floor((w-bw)/2), h - bh - 24
    draw.RoundedBox(10, bx, by, bw, bh, THEME.panel)
    surface.SetDrawColor(THEME.border)
    surface.DrawOutlinedRect(bx, by, bw, bh, 1)

    draw.SimpleText("Ritual: "..remain.."s left","DRitual_Small", bx+10, by+22, THEME.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)

    local items = activeData.items
    if items and #items > 0 then
        local WEAPON_PRETTY = {
            weapon_crowbar = "Crowbar",
            weapon_pistol = "Pistol",
            weapon_357 = ".357 Magnum",
            weapon_smg1 = "SMG",
            weapon_ar2 = "Pulse Rifle",
            weapon_shotgun = "Shotgun",
            weapon_crossbow = "Crossbow",
            weapon_rpg = "RPG",
            weapon_frag = "Frag Grenade",
            weapon_stunstick = "Stunstick",
        }

        local pad = 8
        local gap = 6
        local pillH = 24
        local cols = math.min(#items, 4)
        local rows = math.ceil(#items / cols)
        local innerW = bw - pad*2
        local pillW = math.floor((innerW - gap*(cols-1)) / cols)
        local startY = by + 36
        surface.SetFont("DRitual_Caption")
        for i, it in ipairs(items) do
            local r = math.floor((i-1)/cols)
            local c = (i-1) % cols
            local x = bx + pad + c * (pillW + gap)
            local y = startY + r * (pillH + gap)
            local done = it.done
            local bg = done and Color(30, 56, 40, 240) or Color(56, 30, 30, 240)
            local br = done and Color(120,205,150,200) or Color(220,120,120,200)
            local tx = WEAPON_PRETTY[it.class] or (string.gsub(it.class or "", "weapon_", ""))
            tx = string.gsub(tx, "_", " ")
            draw.RoundedBox(8, x, y, pillW, pillH, bg)
            surface.SetDrawColor(br)
            surface.DrawOutlinedRect(x, y, pillW, pillH, 1)
            local icon = done and "\226\156\148" or "\226\157\151"
            local tw, th = surface.GetTextSize(tx)
            draw.SimpleText(icon, "DRitual_Caption", x + 8, y + pillH/2, br, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            draw.SimpleText(tx, "DRitual_Caption", x + 26, y + pillH/2, THEME.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
        end
    end

    local pad2 = 6
    local fw, fh = bw - pad2*2, 8
    DrawVertGradient(bx+pad2, by + bh - pad2 - fh, math.floor(fw*(1-frac)), fh, Color(60,140,255,200), Color(60,140,255,120))
end)

local buffOverlay
local function OpenBuffUI(ent, offered)
    if IsValid(buffOverlay) then buffOverlay:Remove() end
    currentRitualEnt = ent
    ShowRitualNPC(ent)

    -- Dialogue box
    local W, H = math.Clamp(math.floor(ScrW()*0.60), 720, 1100), 180
    local panel = vgui.Create("DPanel")
    panel:SetSize(W,H)
    panel:SetPos(math.floor((ScrW()-W)/2), ScrH()-H-24)
    panel:SetKeyboardInputEnabled(true)
    panel:MakePopup()
    function panel:Paint(w,h)
        draw.RoundedBox(10,0,0,w,h,THEME.bg)
        surface.SetDrawColor(THEME.border)
        surface.DrawOutlinedRect(0,0,w,h,1)
        draw.SimpleText("Choose your reward","DRitual_DialogTitle",16,12,THEME.text)
        draw.SimpleText("Press 1–3 or click","DRitual_Subtitle",16,36,THEME.textDim)
        surface.SetDrawColor(THEME.accent.r,THEME.accent.g,THEME.accent.b,80)
        surface.DrawRect(0,0,3,h)
    end
    buffOverlay = panel

    local row = vgui.Create("DPanel", panel)
    row:Dock(FILL)
    row:DockMargin(12,62,12,12)
    function row:Paint() end
    row:SetPaintBackground(false)

    local pretty = {
        hp = { title = "More health" },
        speed = { title = "Faster sprint speed" },
        jump = { title = "Higher jump" },
        weapon = { title = "New weapon" },
        ammo = { title = "Unlimited ammo" },
        immunity = { title = "Invulnerability" },
    }

    local function AddOpt(idx, key)
        local info = pretty[key] or { title = key }
        local b = vgui.Create("DButton", row)
        b:SetText("")
    b:Dock(LEFT)
    b:SetTall(64)
    
        local spacing = 8
        local available = W - 24 - spacing*2
        b:SetWide(math.floor(available/3))
        b:DockMargin(idx==1 and 0 or spacing, 0, 0, 0)
        function b:Paint(w,h)
            local hov = self:IsHovered()
            draw.RoundedBox(8,0,0,w,h, hov and THEME.panel or Color(24,29,38,245))
            surface.SetDrawColor(hov and THEME.accent or THEME.border)
            surface.DrawOutlinedRect(0,0,w,h,1)
            draw.SimpleText(info.title, "DRitual_Button", 16, h*0.5, THEME.text, TEXT_ALIGN_LEFT, TEXT_ALIGN_CENTER)
            draw.SimpleText(tostring(idx), "DRitual_Subtitle", w-12, h*0.5, THEME.textDim, TEXT_ALIGN_RIGHT, TEXT_ALIGN_CENTER)
        end
        function b:DoClick()
            if IsValid(buffOverlay) then buffOverlay:Remove() end
            EndFocusSmooth(0.9, 1.2)
            CancelVignetteRamp()
            net.Start("dr_ritual_pickbuff") net.WriteEntity(ent) net.WriteString(key) net.SendToServer()
        end
    end

    for i=1,3 do if offered[i] then AddOpt(i, offered[i]) end end

    -- Cancel button
    local cancel = vgui.Create("DButton", panel)
    cancel:SetText("")
    cancel:SetTall(40)
    cancel:Dock(BOTTOM)
    cancel:DockMargin(12,8,12,12)
    function cancel:Paint(w,h)
        draw.RoundedBox(8,0,0,w,h, Color(32,36,46,245))
        surface.SetDrawColor(Color(255,90,90,160))
        surface.DrawOutlinedRect(0,0,w,h,1)
        draw.SimpleText("No, I cant do this", "DRitual_Button", w*0.5, h*0.5, Color(255,100,100), TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER)
    end
    function cancel:DoClick()
        if IsValid(buffOverlay) then buffOverlay:Remove() end
        EndFocusSmooth(0.9, 1.2)
    CancelVignetteRamp()
        net.Start("dr_ritual_cancelbuff") net.WriteEntity(ent) net.SendToServer()
        -- kick player
        local t = CurTime() + 1.2
        timer.Create("dr_ritual_cancel_kb_" .. ent:EntIndex(), 0.05, 0, function()
            if CurTime() >= t then
                timer.Remove("dr_ritual_cancel_kb_" .. ent:EntIndex())
                net.Start("dr_ritual_cancel_knockback") net.WriteEntity(ent) net.SendToServer()
            end
        end)
    end

    function panel:OnKeyCodePressed(key)
        if key == KEY_ESCAPE then cancel:DoClick() end
        if key == KEY_1 and offered[1] then row:GetChildren()[1]:DoClick() end
        if key == KEY_2 and offered[2] then row:GetChildren()[2]:DoClick() end
        if key == KEY_3 and offered[3] then row:GetChildren()[3]:DoClick() end
    end
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

hook.Add("HUDPaint", "dr_ritual_prompt", function()
    local lp = LocalPlayer(); if not IsValid(lp) then return end
    local tr = lp:GetEyeTrace(); if not tr or not IsValid(tr.Entity) then return end
    local ent = tr.Entity; if ent:GetClass() ~= "dr_ritual_pentagram" then return end
    if tr.HitPos:DistToSqr(lp:GetShootPos()) > (150*150) then return end
    local text = "Press E to begin the ██████"
    if ent:GetIsActive() then text = "Press E to offer your held weapon"
    elseif ent:GetIsChanneling() then text = "Channeling..." end
    draw.SimpleTextOutlined(text, "DRitual_Small", ScrW()/2, ScrH()*0.74, color_white, TEXT_ALIGN_CENTER, TEXT_ALIGN_CENTER, 1, Color(0,0,0,200))
end)

hook.Add("KeyPress", "dr_ritual_e", function(ply, key)
    if ply ~= LocalPlayer() or key ~= IN_USE then return end
    local tr = ply:GetEyeTrace(); if not tr or not IsValid(tr.Entity) then return end
    local ent = tr.Entity; if ent:GetClass() ~= "dr_ritual_pentagram" then return end
    if tr.HitPos:DistToSqr(ply:GetShootPos()) > (150*150) then return end
   
    StartVignetteRamp(0.35, 1.4)
    if ent:GetIsActive() then
        net.Start("dr_ritual_try_sacrifice") net.WriteEntity(ent) net.SendToServer()
    elseif (not ent:GetIsChanneling()) then
    end
end)
