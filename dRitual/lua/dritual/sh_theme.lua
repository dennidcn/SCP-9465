-- theme ui stuff

if not DRITUAL then DRITUAL = {} end

-- Theme colours
DRITUAL.Theme = {
    -- Background colours
    background = Color(18, 20, 26, 240),
    backgroundDark = Color(12, 14, 18, 245),
    panel = Color(22, 27, 36, 250),
    panelDark = Color(20, 20, 20, 180),
    
    -- Text colours
    text = Color(220, 228, 236),
    textDim = Color(170, 180, 192),
    textBright = Color(255, 255, 255),
    
    -- Selection colours
    selected = Color(70, 72, 78, 255),
    unselected = Color(40, 42, 48, 230),
    selectedBorder = Color(150, 150, 160, 255),
    unselectedBorder = Color(55, 58, 66, 255),
    
    -- Status colours
    success = Color(30, 56, 40, 240),
    successBorder = Color(120, 205, 150, 200),
    error = Color(56, 30, 30, 240),
    errorBorder = Color(220, 120, 120, 200),
    warning = Color(255, 200, 0),
    danger = Color(255, 100, 100),
    
    -- Progress colours
    progress = Color(60, 140, 255, 200),
    progressDim = Color(60, 140, 255, 120),
    
    -- Border colours
    border = Color(100, 100, 100, 255),
    borderDim = Color(0, 0, 0, 180)
}

-- Common UI helper functions
DRITUAL.UI = {
    -- Draw a themed panel background thingy
    DrawPanel = function(x, y, w, h, color)
        color = color or DRITUAL.Theme.panel
        draw.RoundedBox(4, x, y, w, h, color)
        surface.SetDrawColor(DRITUAL.Theme.border)
        surface.DrawOutlinedRect(x, y, w, h, 1)
    end,
    

    DrawBackground = function(x, y, w, h, color)
        color = color or DRITUAL.Theme.background
        draw.RoundedBox(0, x, y, w, h, color)
    end,  

    DrawText = function(text, font, x, y, color, xAlign, yAlign)
        color = color or DRITUAL.Theme.text
        xAlign = xAlign or TEXT_ALIGN_LEFT
        yAlign = yAlign or TEXT_ALIGN_TOP
        draw.SimpleText(text, font, x, y, color, xAlign, yAlign)
    end,

    CreateThemedPanel = function(parent)
        local panel = vgui.Create("DPanel", parent)
        function panel:Paint(w, h)
            DRITUAL.UI.DrawBackground(0, 0, w, h)
        end
        return panel
    end,
    
    CreateSectionPanel = function(parent)
        local panel = vgui.Create("DPanel", parent)
        function panel:Paint(w, h)
            DRITUAL.UI.DrawPanel(0, 0, w, h)
        end
        return panel
    end
}

-- Network strings
DRITUAL.NetworkStrings = {
    -- Config system
    "dr_ritual_cfg_full",
    "dr_ritual_cfg_request", 
    "dr_ritual_cfg_update",
    
    -- Weapon packs
    "dr_ritual_packs_full",
    "dr_ritual_packs_request",
    "dr_ritual_packs_update",
    "dr_ritual_pack_details_request",
    "dr_ritual_pack_details_full",
    "dr_ritual_weapon_overrides_update",
    
    -- Entities
    "dr_ritual_entities_request",
    "dr_ritual_entities_full", 
    "dr_ritual_entities_update",
    
    -- Ritual system stuff
    "dr_ritual_channel",
    "dr_ritual_begin",
    "dr_ritual_progress",
    "dr_ritual_success",
    "dr_ritual_fail",
    "dr_ritual_cancel",
    "dr_ritual_offerbuff",
    "dr_ritual_pickbuff",
    "dr_ritual_cancelbuff",
    "dr_ritual_immunity_state",
    "dr_ritual_player_lock",
    "dr_ritual_subtitle_trigger",
    "dr_ritual_try_sacrifice",
    "dr_ritual_move_back",
    "dr_ritual_vignette_ramp",
    "dr_ritual_cancel_knockback",
    "dr_ritual_no_more",
    "dr_ritual_cancel_vignette"
}

-- Initialize network strings
if SERVER then
    for _, netString in ipairs(DRITUAL.NetworkStrings) do
        util.AddNetworkString(netString)
    end
end
