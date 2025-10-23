-- dRitual config menu and networking for modular buffs/debuffs
if not DRITUAL then DRITUAL = {} end

if SERVER then
    -- Load existing config from data folder if present
    local function configPath()
        return "dritual_config.txt"
    end

    if file.Exists(configPath(), "DATA") then
        local success, result = pcall(function()
            return file.Read(configPath(), "DATA")
        end)
        
        if success and result then
            local jsonSuccess, tbl = pcall(function()
                return util.JSONToTable(result) or {}
            end)
            
            if jsonSuccess and istable(tbl) then
                DRITUAL.Config = tbl
            end
        else
            ErrorNoHaltWithStack("[dRitual] Failed to read config file: " .. tostring(result))
        end
    end

    local function saveConfig()
        local json = util.TableToJSON(DRITUAL.Config or {}, true)
        local success, err = pcall(function()
            file.Write(configPath(), json)
        end)
        
        if not success then
            ErrorNoHaltWithStack("[dRitual] Failed to save config: " .. tostring(err))
        end
    end

    local function enumerateWeapons()
        local perCat = {}
        for _, wep in ipairs(weapons.GetList() or {}) do
            local t = wep and (wep.t or wep) or nil
            if t and (t.Spawnable or t.AdminSpawnable) then
                local cat = t.Category or "Other"
                perCat[cat] = perCat[cat] or {}
                local class = t.ClassName or t.Classname or t.PrintName or ""
                if wep.ClassName and wep.ClassName != "" then 
                    class = wep.ClassName 
                end
                perCat[cat][#perCat[cat] + 1] = {
                    class = class,
                    name = t.PrintName or class,
                    model = t.WorldModel or t.Model or t.ViewModel or "",
                }
            end
        end
        return perCat
    end

    local function sendPacks(ply)
        local perCat = enumerateWeapons()
        local cats = {}
        for cat, _ in pairs(perCat) do 
            cats[#cats + 1] = cat 
        end
        table.sort(cats, function(a, b) 
            return a:lower() < b:lower() 
        end)
        net.Start("dr_ritual_packs_full")
            net.WriteUInt(#cats, 12)
            for _, cat in ipairs(cats) do
                local enabled = DRITUAL.Config and DRITUAL.Config.weaponPacks and DRITUAL.Config.weaponPacks[cat]
                net.WriteString(cat)
                net.WriteBool(enabled and true or false)
            end
        if IsValid(ply) then 
            net.Send(ply) 
        else 
            net.Broadcast() 
        end
    end

    local function sendPackDetails(ply, cat)
        if not cat or cat == "" then return end
        local perCat = enumerateWeapons()
        local list = perCat[cat] or {}
        table.SortByMember(list, "class", true)
        net.Start("dr_ritual_pack_details_full")
            net.WriteString(cat)
            net.WriteUInt(#list, 12)
            for _, info in ipairs(list) do
                local disabledOverride = DRITUAL.Config and DRITUAL.Config.weaponOverrides and (DRITUAL.Config.weaponOverrides[info.class] == false)
                net.WriteString(info.class or "")
                net.WriteString(info.name or info.class or "")
                net.WriteString(info.model or "")
                net.WriteBool(disabledOverride and true or false) -- true means override is disabled
            end
        if IsValid(ply) then 
            net.Send(ply) 
        else 
            net.Broadcast() 
        end
    end

    local function sendConfig(ply)
        net.Start("dr_ritual_cfg_full")
            local buffCount = table.Count(DRITUAL.Buffs or {})
            net.WriteUInt(buffCount, 8)
            for key, def in pairs(DRITUAL.Buffs or {}) do
                net.WriteString(key)
                net.WriteString(def.title or key)
                local cfg = (DRITUAL.Config and DRITUAL.Config.buffs and DRITUAL.Config.buffs[key]) or {}
                local enabled = (cfg.enabled) and true or false
                net.WriteBool(enabled)
                -- Always send all fields so client can render everything properly
                local fields = (def.fields and istable(def.fields)) and def.fields or {}
                net.WriteUInt(#fields, 8)
                for _, f in ipairs(fields) do
                    local fkey   = f.key
                    local ftype  = f.type or "number"
                    local flabel = f.label or fkey
                    local val
                    if cfg[fkey] != nil then
                        val = cfg[fkey]
                    else
                
                        if ftype == "bool" then
                            val = (f.default and true) or false
                        else
                            val = tonumber(f.default) or 0
                        end
                    end

                    net.WriteString(fkey)
                    net.WriteString(flabel)
                    net.WriteString(ftype)
                    if ftype == "bool" then
                        net.WriteBool(val and true or false)
                    else
                        net.WriteFloat(tonumber(val) or 0)
                    end
                end
            end
        if IsValid(ply) then 
            net.Send(ply) 
        else 
            net.Broadcast() 
        end
    end

    net.Receive("dr_ritual_cfg_request", function(_, ply)
        if not IsValid(ply) then return end
        sendConfig(ply)
    end)

    net.Receive("dr_ritual_cfg_update", function(_, ply)
        if not IsValid(ply) or (not ply:IsAdmin()) then return end
        local count = net.ReadUInt(12) or 0
        DRITUAL.Config = DRITUAL.Config or { buffs = {} }
        DRITUAL.Config.buffs = DRITUAL.Config.buffs or {}
        for i = 1, count do
            local key = net.ReadString()
            local enabled = net.ReadBool()
            local def = DRITUAL.Buffs[key]
            if def then
                local fieldsCount = net.ReadUInt(8) or 0
                local cfg = DRITUAL.Config.buffs[key] or {}
                cfg.enabled = enabled
                for j = 1, fieldsCount do
                    local fkey = net.ReadString()
                    local ftype = net.ReadString()
                    if ftype == "bool" then
                        cfg[fkey] = net.ReadBool() and true or false
                    else
                        cfg[fkey] = net.ReadFloat()
                    end
                end
                DRITUAL.Config.buffs[key] = cfg
            else
                local fieldsCount = net.ReadUInt(8) or 0
                for j = 1, fieldsCount do
                    local _fkey = net.ReadString()
                    local ftype = net.ReadString()
                    if ftype == "bool" then 
                        net.ReadBool() 
                    else 
                        net.ReadFloat() 
                    end
                end
            end
        end
        saveConfig()
        -- Add small delay to prevent network message conflicts
        timer.Simple(0.1, function()
            sendConfig(nil) -- send a broadcast refresh
        end)
    end)

    net.Receive("dr_ritual_packs_request", function(_, ply)
        sendPacks(ply)
    end)

    net.Receive("dr_ritual_pack_details_request", function(_, ply)
        local cat = net.ReadString() or ""
        if cat != "" then 
            sendPackDetails(ply, cat) 
        end
    end)

    net.Receive("dr_ritual_packs_update", function(_, ply)
        if not IsValid(ply) or (not ply:IsAdmin()) then return end
        local total = net.ReadUInt(12) or 0
        DRITUAL.Config.weaponPacks = DRITUAL.Config.weaponPacks or {}
        for i = 1, total do
            local cat = net.ReadString()
            local on = net.ReadBool()
            DRITUAL.Config.weaponPacks[cat] = on and true or false
        end
        if DRITUAL.RebuildWeaponPool then 
            DRITUAL.RebuildWeaponPool() 
        end
        saveConfig()
        -- Add small delay to prevent network message conflicts
        timer.Simple(0.1, function()
            sendPacks(nil)
        end)
    end)

    net.Receive("dr_ritual_weapon_overrides_update", function(_, ply)
        if not IsValid(ply) or (not ply:IsAdmin()) then return end
        local count = net.ReadUInt(14) or 0
        DRITUAL.Config.weaponOverrides = DRITUAL.Config.weaponOverrides or {}
        for i = 1, count do
            local cls = net.ReadString()
            local disabled = net.ReadBool() -- true means disabled
            if disabled then
                DRITUAL.Config.weaponOverrides[cls] = false
            else
                DRITUAL.Config.weaponOverrides[cls] = nil -- remove override to enable
            end
        end
        if DRITUAL.RebuildWeaponPool then 
            DRITUAL.RebuildWeaponPool() 
        end
        saveConfig()
    end)

    net.Receive("dr_ritual_entities_request", function(_, ply)
        if not IsValid(ply) then return end
        local entsCfg = DRITUAL.Config.entities or {}
        local candidates = {}
        for name, def in pairs(scripted_ents.GetList() or {}) do
            local t = def.t or def
            if t and (t.Spawnable or t.AdminSpawnable) and name != "dr_ritual_pentagram" then
                candidates[#candidates + 1] = {
                    class   = name,
                    model   = t.Model or t.WorldModel,
                    category= t.Category or "Other",
                    display = t.PrintName or name
                }
            end
        end
        table.SortByMember(candidates, "class", true)
        net.Start("dr_ritual_entities_full")
            net.WriteUInt(#candidates, 12)
            for _, info in ipairs(candidates) do
                net.WriteString(info.class)                               
                net.WriteString(info.model or "")                          
                net.WriteBool(entsCfg[info.class] and true or false)       
                net.WriteString(info.category or "Other")                 
                net.WriteString(info.display or info.class)                
            end
        net.Send(ply)
    end)

    net.Receive("dr_ritual_entities_update", function(_, ply)
        if not IsValid(ply) or (not ply:IsAdmin()) then return end
        local total = net.ReadUInt(12) or 0
        DRITUAL.Config.entities = DRITUAL.Config.entities or {}
        local newCfg = {}
        for i = 1, total do
            local cls = net.ReadString()
            local enabled = net.ReadBool()
            if enabled then 
                newCfg[cls] = true 
            end
        end
        DRITUAL.Config.entities = newCfg
        if DRITUAL.RebuildEntityPool then 
            DRITUAL.RebuildEntityPool() 
        end
        saveConfig()
        -- send it back to them
        net.Start("dr_ritual_entities_full")
            -- Re-send only enabled entities with basic metadata
            local enabledList = {}
            for cls, _ in pairs(newCfg) do 
                enabledList[#enabledList + 1] = cls 
            end
            table.sort(enabledList)
            net.WriteUInt(#enabledList, 12)
            for _, cls in ipairs(enabledList) do
                local def = scripted_ents.Get(cls)
                local t = def and (def.t or def) or {}
                net.WriteString(cls)                             
                net.WriteString((t.Model or t.WorldModel) or "") 
                net.WriteBool(true)                              
                net.WriteString(t.Category or "Other")          
                net.WriteString(t.PrintName or cls)              
            end
        net.Send(ply)
    end)

    return
end

-- CLIENT side UI
local function openMenu()
    -- Request latest server config with a small delay to ensure server is ready
    timer.Simple(0.1, function()
        net.Start("dr_ritual_cfg_request") 
        net.SendToServer()
    end)

    local frame = vgui.Create("DFrame")
    frame:SetTitle("dRitual Configuration")
    frame:SetSize(math.Clamp(ScrW() * 0.6, 700, 1100), math.Clamp(ScrH() * 0.7, 480, 800))
    frame:Center()
    frame:MakePopup()
    frame._sheet = nil

    frame._populate = function(buffList)

        if IsValid(frame._loadingLabel) then 
            frame._loadingLabel:Remove() 
        end
        if IsValid(frame._sheet) then 
            frame._sheet:Remove() 
        end
        
        if not istable(buffList) or #buffList == 0 then
            frame._loadingLabel = vgui.Create("DLabel", frame)
            frame._loadingLabel:SetText("No buffs registered on server")
            frame._loadingLabel:Dock(FILL)
            frame._loadingLabel:SetContentAlignment(5)
            return
        end
        
        local sheet = vgui.Create("DPropertySheet", frame)
        frame._sheet = sheet
        sheet:Dock(FILL)
        for _, b in ipairs(buffList) do
            local pnl = vgui.Create("DPanel", sheet)
            pnl:Dock(FILL)
            function pnl:Paint(w, h)
                draw.RoundedBox(0, 0, 0, w, h, Color(18, 20, 26, 240))
            end

            local scroll = vgui.Create("DScrollPanel", pnl)
            scroll:Dock(FILL)

            local enabled = vgui.Create("DCheckBoxLabel", scroll)
            enabled:SetText("Enabled")
            enabled:SetValue(b.enabled and 1 or 0)
            enabled:Dock(TOP)
            enabled:DockMargin(8, 8, 8, 8)

            local editors = {}
            for _, f in ipairs(b.fields or {}) do
                if f.type == "bool" then
                    local cb = vgui.Create("DCheckBoxLabel", scroll)
                    cb:SetText(f.label or f.key)
                    cb:SetValue((b.values and b.values[f.key]) and 1 or 0)
                    cb:Dock(TOP)
                    cb:DockMargin(12, 2, 12, 2)
                    editors[#editors + 1] = { f = f, ctrl = cb }
                else
                    local p = vgui.Create("DPanel", scroll)
                    p:Dock(TOP)
                    p:DockMargin(12, 2, 12, 2)
                    function p:Paint(w, h) end
                    local lbl = vgui.Create("DLabel", p)
                    lbl:SetText(f.label or f.key)
                    lbl:Dock(LEFT)
                    lbl:SetWide(240)
                    local num = vgui.Create("DNumSlider", p)
                    num:Dock(FILL)
                    num:SetMinMax(f.min or 0, f.max or 100)
                    num:SetDecimals(2)
                    num:SetValue(tonumber(b.values and b.values[f.key]) or tonumber(f.default) or 0)
                    editors[#editors + 1] = { f = f, ctrl = num }
                end
            end

            sheet:AddSheet(b.title or b.key, pnl, "icon16/cog.png")

            pnl._collect = function()
                local cfg = { key = b.key, enabled = enabled:GetChecked(), fields = {} }
                for _, e in ipairs(editors) do
                    local f = e.f
                    if f.type == "bool" then
                        table.insert(cfg.fields, { key = f.key, type = f.type, val = e.ctrl:GetChecked() and true or false })
                    else
                        table.insert(cfg.fields, { key = f.key, type = f.type, val = tonumber(e.ctrl:GetValue()) or 0 })
                    end
                end
                return cfg
            end
        end

        -- Weapon Packs Selection Tab expandable categories with individual weapon selections
        local packsPanel = vgui.Create("DPanel", sheet)
        packsPanel:Dock(FILL)
        function packsPanel:Paint(w, h)
            draw.RoundedBox(0, 0, 0, w, h, Color(18, 20, 26, 240))
        end
        packsPanel._packCheckboxes = {}
        packsPanel._packContainers = {} 

        local scroll = vgui.Create("DScrollPanel", packsPanel)
        scroll:Dock(FILL)
        local infoLbl = vgui.Create("DLabel", scroll)
        infoLbl:SetText("Fetching weapon packs...")
        infoLbl:Dock(TOP)
        infoLbl:SetContentAlignment(5)
        infoLbl:DockMargin(8, 8, 8, 8)

        local function requestPackDetails(cat)
            if not cat or cat == "" then return end
            net.Start("dr_ritual_pack_details_request")
                net.WriteString(cat)
            net.SendToServer()
        end

        packsPanel._populatePacks = function(pnl, packList)
            -- Clear existing categories
            if IsValid(infoLbl) then 
                infoLbl:Remove() 
            end
            for _, cb in ipairs(packsPanel._packCheckboxes) do
                if IsValid(cb) then
                    local cont = cb._packContainer
                    if IsValid(cont) then 
                        cont:Remove() 
                    end
                end
            end
            packsPanel._packCheckboxes = {}
            packsPanel._packContainers = {}
            if not istable(packList) or #packList == 0 then
                local none = vgui.Create("DLabel", scroll)
                none:SetText("No weapon packs found.")
                none:Dock(TOP)
                none:SetContentAlignment(5)
                none:DockMargin(8, 8, 8, 8)
                return
            end
            for _, wdef in ipairs(packList) do
                local cat = (wdef and wdef.pack) or "Unknown"
                local packContainer = vgui.Create("DPanel", scroll)
                packContainer:Dock(TOP)
                packContainer:DockMargin(4, 4, 4, 0)
                packContainer:InvalidateLayout(true)
                packContainer:SetTall(24) 
                function packContainer:Paint(w, h) end 

                local header = vgui.Create("DPanel", packContainer)
                header:Dock(TOP)
                header:SetTall(24)
                function header:Paint(w, h)
                    draw.RoundedBox(4, 0, 0, w, h, Color(30, 34, 42, 200))
                end

                local expandBtn = vgui.Create("DButton", header)
                expandBtn:SetText("+")
                expandBtn:SetWide(24)
                expandBtn:Dock(LEFT)
                expandBtn:DockMargin(2, 2, 2, 2)
                expandBtn._cat = cat

                local cb = vgui.Create("DCheckBoxLabel", header)
                cb:SetText(cat)
                local isEnabled = DRITUAL.Config and DRITUAL.Config.weaponPacks and DRITUAL.Config.weaponPacks[cat]
                cb:SetValue(isEnabled and 1 or 0)
                cb:Dock(FILL)
                cb:DockMargin(2, 2, 2, 2)
                cb._category = cat
                cb._packContainer = packContainer
                table.insert(packsPanel._packCheckboxes, cb)

                local weaponList = vgui.Create("DPanel", packContainer)
                weaponList:Dock(TOP)
                weaponList:DockMargin(20, 2, 4, 4)
                function weaponList:Paint(w, h) end
                weaponList:SetVisible(false)
                weaponList:SetTall(0)
                weaponList._rows = {}
                -- Grid container inside weaponList
                local grid = vgui.Create("DIconLayout", weaponList)
                grid:Dock(FILL)
                grid:SetSpaceX(6)
                grid:SetSpaceY(6)
                weaponList._grid = grid

                packsPanel._packContainers[cat] = { container = packContainer, header = header, weaponList = weaponList }

                function expandBtn:DoClick()
                    local data = packsPanel._packContainers[self._cat]
                    if not data then return end
                    local wl = data.weaponList
                    local newState = not wl:IsVisible()
                    wl:SetVisible(newState)
                    self:SetText(newState and "-" or "+")
                    if newState and (#wl._rows == 0) then
                        requestPackDetails(self._cat)
                    end
                    -- Adjust heights to fit the weapon list
                    if newState then
                        wl:SetTall(math.max(60, wl:GetTall()))
                        packContainer:SetTall(24 + wl:GetTall() + 6)
                    else
                        wl:SetTall(0)
                        packContainer:SetTall(24)
                    end
                    scroll:InvalidateLayout(true)
                end

                -- Weapon pack override, will select/deselect all weapons in pack
                function cb:OnChange(val)
                    local data = packsPanel._packContainers[self._category]
                    if not data then return end
                    local wl = data.weaponList
                    -- If enabling pack the weapons havent been loaded yet, fetch them and flag for auto-select
                    if val and wl and (#wl._rows == 0) then
                        wl._autoSelectAll = true
                        -- expand to show contents
                        if not wl:IsVisible() then
                            expandBtn:DoClick()
                        else
                            requestPackDetails(self._category)
                        end
                        return
                    end
                    -- Otherwise just set all existing rows
                    if wl and #wl._rows > 0 then
                        for _, row in ipairs(wl._rows) do
                            if IsValid(row) and row.SetSelectedState then
                                row:SetSelectedState(val)
                            end
                        end
                    end
                end
            end
        end
        sheet:AddSheet("Weapon Packs", packsPanel, "icon16/folder.png")
        net.Start("dr_ritual_packs_request") 
        net.SendToServer()

        -- Entities selection tab, mirrors weapon tab functionality
        local entitiesPanel = vgui.Create("DPanel", sheet)
        entitiesPanel:Dock(FILL)
        function entitiesPanel:Paint(w, h)
            draw.RoundedBox(0, 0, 0, w, h, Color(18, 20, 26, 240))
        end
        entitiesPanel._catCheckboxes = {}
        entitiesPanel._catContainers = {} 
        local eScroll = vgui.Create("DScrollPanel", entitiesPanel)
        eScroll:Dock(FILL)
        local eInfo = vgui.Create("DLabel", eScroll)
        eInfo:SetText("Fetching entities...")
        eInfo:Dock(TOP)
        eInfo:SetContentAlignment(5)
        eInfo:DockMargin(8, 8, 8, 8)

        local tileW, tileH, gap = 92, 92, 6

        function entitiesPanel:_populateEntities(list)
            if IsValid(eInfo) then 
                eInfo:Remove() 
            end
            -- clear existing categories
            for _, cb in ipairs(self._catCheckboxes) do 
                if IsValid(cb) and IsValid(cb._catContainer) then 
                    cb._catContainer:Remove() 
                end 
            end
            self._catCheckboxes = {}
            self._catContainers = {}
            if not istable(list) or #list == 0 then
                local none = vgui.Create("DLabel", eScroll)
                none:SetText("No spawnable entities found.")
                none:Dock(TOP)
                none:SetContentAlignment(5)
                none:DockMargin(8, 8, 8, 8)
                return
            end
            local perCat = {}
            for _, info in ipairs(list) do
                local cat = info.category or "Other"
                perCat[cat] = perCat[cat] or {}
                perCat[cat][#perCat[cat] + 1] = info
            end
            local cats = {}
            for k, _ in pairs(perCat) do 
                cats[#cats + 1] = k 
            end
            table.sort(cats, function(a, b) 
                return a:lower() < b:lower() 
            end)
            for _, cat in ipairs(cats) do
                local catContainer = vgui.Create("DPanel", eScroll)
                catContainer:Dock(TOP)
                catContainer:DockMargin(4, 4, 4, 0)
                catContainer:SetTall(24)
                function catContainer:Paint(w, h) end

                local header = vgui.Create("DPanel", catContainer)
                header:Dock(TOP)
                header:SetTall(24)
                function header:Paint(w, h)
                    draw.RoundedBox(4, 0, 0, w, h, Color(30, 34, 42, 200))
                end

                local expandBtn = vgui.Create("DButton", header)
                expandBtn:SetText("+")
                expandBtn:SetWide(24)
                expandBtn:Dock(LEFT)
                expandBtn:DockMargin(2, 2, 2, 2)
                expandBtn._cat = cat

                local cb = vgui.Create("DCheckBoxLabel", header)
                cb:SetText(cat)
                cb:SetValue(0)
                cb:Dock(FILL)
                cb:DockMargin(2, 2, 2, 2)
                cb._category = cat
                cb._catContainer = catContainer
                table.insert(entitiesPanel._catCheckboxes, cb)

                local gridHolder = vgui.Create("DPanel", catContainer)
                gridHolder:Dock(TOP)
                gridHolder:DockMargin(20, 2, 4, 4)
                function gridHolder:Paint(w, h) end
                gridHolder:SetVisible(false)
                gridHolder:SetTall(0)
                local grid = vgui.Create("DIconLayout", gridHolder)
                grid:Dock(FILL)
                grid:SetSpaceX(gap)
                grid:SetSpaceY(gap)
                grid._tiles = {}

                entitiesPanel._catContainers[cat] = { container = catContainer, header = header, gridHolder = gridHolder, grid = grid }

                local function Repack()
                    local g = grid
                    if not IsValid(g) then return end
                    local cols = math.max(1, math.floor((g:GetWide() - 10) / (tileW + gap)))
                    local rows = math.ceil(#g._tiles / cols)
                    local h = rows * tileH + math.max(0, rows - 1) * gap + 6
                    g:SetTall(h)
                    gridHolder:SetTall(h)
                    catContainer:SetTall(24 + (gridHolder:IsVisible() and (h + 6) or 0))
                    if IsValid(eScroll) then 
                        eScroll:InvalidateLayout(true) 
                    end
                end

                function expandBtn:DoClick()
                    local data = entitiesPanel._catContainers[self._cat]
                    if not data then return end
                    local gh = data.gridHolder
                    local newState = not gh:IsVisible()
                    gh:SetVisible(newState)
                    self:SetText(newState and "-" or "+")
                    if newState and #data.grid._tiles == 0 then
                        -- populate tiles for this category
                        for _, info in ipairs(perCat[self._cat] or {}) do
                            local tile = data.grid:Add("DButton")
                            tile:SetText("")
                            tile:SetSize(tileW, tileH)
                            tile._entClass = info.class
                
                            tile._entModel = (info.model and info.model != "") and info.model or nil
                            tile._selected = info.enabled and true or false
                            tile._display = info.display or info.class
                            function tile:SetSelectedState(on)
                                self._selected = on and true or false
                                self:InvalidateLayout(true)
                            end
                            function tile:DoClick()
                                self._selected = not self._selected
                                self:InvalidateLayout(true)
                            end
                            function tile:Paint(wi, hi)
                                local sel = self._selected
                                local bg = sel and Color(70, 72, 78, 255) or Color(40, 42, 48, 230)
                                local bd = sel and Color(150, 150, 160, 255) or Color(55, 58, 66, 255)
                                surface.SetDrawColor(bg) 
                                surface.DrawRect(0, 0, wi, hi)
                                surface.SetDrawColor(bd) 
                                surface.DrawOutlinedRect(0, 0, wi, hi)
                                draw.SimpleText(self._display, "DermaDefault", wi * 0.5, hi - 10, sel and Color(235, 235, 235) or Color(180, 180, 185), TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
                            end
                            if tile._entModel then
                                local icon = vgui.Create("SpawnIcon", tile)
                                icon:SetSize(64, 64)
                                icon:Dock(TOP)
                                icon:DockMargin(14, 4, 14, 2)
                                icon:SetModel(tile._entModel)
                                icon:SetTooltip(tile._display .. " (" .. tile._entClass .. ")")
                                function icon:DoClick() 
                                    tile:DoClick() 
                                end
                            end
                            data.grid._tiles[#data.grid._tiles + 1] = tile
                        end
                        Repack()
                        
                        if cb:GetChecked() and #data.grid._tiles > 0 then
                            for _, t in ipairs(data.grid._tiles) do 
                                if IsValid(t) and t.SetSelectedState then 
                                    t:SetSelectedState(true) 
                                end 
                            end
                        end
                    else
                        Repack()
                    end
                end

                function cb:OnChange(val)
                    local data = entitiesPanel._catContainers[self._category]
                    if not data then return end
                    local g = data.grid
                    if g and #g._tiles == 0 and val then
                        -- auto expand & populate to apply selection
                        if not data.gridHolder:IsVisible() then 
                            data.container:InvalidateLayout(true) 
                        end
                        expandBtn:DoClick()
                        timer.Simple(0, function()
                            if not IsValid(g) then return end
                            for _, t in ipairs(g._tiles) do 
                                if IsValid(t) and t.SetSelectedState then 
                                    t:SetSelectedState(true) 
                                end 
                            end
                        end)
                        return
                    end
                    for _, t in ipairs(g._tiles or {}) do
                        if IsValid(t) and t.SetSelectedState then 
                            t:SetSelectedState(val) 
                        end
                    end
                end
            end
        end
        sheet:AddSheet("Entities", entitiesPanel, "icon16/bricks.png")
        net.Start("dr_ritual_entities_request") 
        net.SendToServer()

        -- General Settings tab for ritual config
        do
            local generalPanel = vgui.Create("DPanel", sheet)
            generalPanel:Dock(FILL)
            function generalPanel:Paint(w, h)
                draw.RoundedBox(0, 0, 0, w, h, Color(18, 20, 26, 240))
            end
            
            local scroll = vgui.Create("DScrollPanel", generalPanel)
            scroll:Dock(FILL)
            
            -- Ritual Duration section
            local durationSection = vgui.Create("DPanel", scroll)
            durationSection:Dock(TOP)
            durationSection:DockMargin(10, 10, 10, 5)
            durationSection:SetTall(120)
            function durationSection:Paint(w, h)
                draw.RoundedBox(4, 0, 0, w, h, Color(30, 34, 42, 200))
            end
            
            local durationTitle = vgui.Create("DLabel", durationSection)
            durationTitle:SetText("Ritual Duration")
            durationTitle:SetFont("DermaDefaultBold")
            durationTitle:Dock(TOP)
            durationTitle:DockMargin(10, 10, 10, 5)
            durationTitle:SetTextColor(Color(220, 228, 236))
            
            local durationDesc = vgui.Create("DLabel", durationSection)
            durationDesc:SetText("Set how long players have to complete a ritual (in seconds)")
            durationDesc:Dock(TOP)
            durationDesc:DockMargin(10, 0, 10, 10)
            durationDesc:SetTextColor(Color(170, 180, 192))
            durationDesc:SetWrap(true)
            durationDesc:SetAutoStretchVertical(true)
            
            -- Duration slider
            local durationSlider = vgui.Create("DNumSlider", durationSection)
            durationSlider:Dock(TOP)
            durationSlider:DockMargin(10, 5, 10, 10)
            durationSlider:SetText("Duration (seconds)")
            durationSlider:SetMin(30)
            durationSlider:SetMax(300)
            durationSlider:SetDecimals(0)
            durationSlider:SetValue(GetConVar("dr_ritual_time"):GetFloat())
            
            function durationSlider:OnValueChanged(val)
                RunConsoleCommand("dr_ritual_time", tostring(val))
            end
            
            -- Pentagram colour section
            local colorSection = vgui.Create("DPanel", scroll)
            colorSection:Dock(TOP)
            colorSection:DockMargin(10, 10, 10, 5)
            colorSection:SetTall(200)
            function colorSection:Paint(w, h)
                draw.RoundedBox(4, 0, 0, w, h, Color(30, 34, 42, 200))
            end
            
            local colorTitle = vgui.Create("DLabel", colorSection)
            colorTitle:SetText("Pentagram Halo Color")
            colorTitle:SetFont("DermaDefaultBold")
            colorTitle:Dock(TOP)
            colorTitle:DockMargin(10, 10, 10, 5)
            colorTitle:SetTextColor(Color(220, 228, 236))
            
            local colorDesc = vgui.Create("DLabel", colorSection)
            colorDesc:SetText("Configure the color of the glowing outline around the pentagram")
            colorDesc:Dock(TOP)
            colorDesc:DockMargin(10, 0, 10, 10)
            colorDesc:SetTextColor(Color(170, 180, 192))
            colorDesc:SetWrap(true)
            colorDesc:SetAutoStretchVertical(true)
            
            -- Get current halo colour or use default
            DRITUAL.Config = DRITUAL.Config or {}
            DRITUAL.Config.haloColor = DRITUAL.Config.haloColor or { r = 120, g = 20, b = 40 }
            
            local colorMixer = vgui.Create("DColorMixer", colorSection)
            colorMixer:Dock(FILL)
            colorMixer:DockMargin(10, 0, 10, 10)
            colorMixer:SetPalette(false)
            colorMixer:SetAlphaBar(false)
            colorMixer:SetWangs(true)
            colorMixer:SetColor(Color(DRITUAL.Config.haloColor.r, DRITUAL.Config.haloColor.g, DRITUAL.Config.haloColor.b))
            
            function colorMixer:ValueChanged(col)
                DRITUAL.Config.haloColor = { r = col.r, g = col.g, b = col.b }
                -- Save to file immediately
                local json = util.TableToJSON(DRITUAL.Config or {}, true)
                local success, err = pcall(function()
                    file.Write("dritual_config.txt", json)
                end)
                if not success then
                    ErrorNoHaltWithStack("[dRitual] Failed to save config: " .. tostring(err))
                end
            end
            
            -- Buff Display Names section
            local buffNamesSection = vgui.Create("DPanel", scroll)
            buffNamesSection:Dock(TOP)
            buffNamesSection:DockMargin(10, 10, 10, 5)
            buffNamesSection:SetTall(350)
            function buffNamesSection:Paint(w, h)
                draw.RoundedBox(4, 0, 0, w, h, Color(30, 34, 42, 200))
            end
            
            local buffNamesTitle = vgui.Create("DLabel", buffNamesSection)
            buffNamesTitle:SetText("Buff Display Names")
            buffNamesTitle:SetFont("DermaDefaultBold")
            buffNamesTitle:Dock(TOP)
            buffNamesTitle:DockMargin(10, 10, 10, 5)
            buffNamesTitle:SetTextColor(Color(220, 228, 236))
            
            local buffNamesDesc = vgui.Create("DLabel", buffNamesSection)
            buffNamesDesc:SetText("Customize the names that appear on the 3D buff selection panels")
            buffNamesDesc:Dock(TOP)
            buffNamesDesc:DockMargin(10, 0, 10, 10)
            buffNamesDesc:SetTextColor(Color(170, 180, 192))
            buffNamesDesc:SetWrap(true)
            buffNamesDesc:SetAutoStretchVertical(true)
            
            -- Initialize buff display names in config if not present
            DRITUAL.Config.buffDisplayNames = DRITUAL.Config.buffDisplayNames or {}
        
            local buffNamesScroll = vgui.Create("DScrollPanel", buffNamesSection)
            buffNamesScroll:Dock(FILL)
            buffNamesScroll:DockMargin(10, 0, 10, 10)
            
            -- Function to create buff name editors
            local function createBuffNameEditors()
                -- Clear existing editors safely
                if IsValid(buffNamesScroll) then
                    for _, child in ipairs(buffNamesScroll:GetChildren()) do
                        if IsValid(child) then 
                            child:Remove() 
                        end
                    end
                end
                
                -- Get all registered buffs
                local buffs = DRITUAL.Buffs or {}
                local buffKeys = {}
                for key, _ in pairs(buffs) do
                    table.insert(buffKeys, key)
                end
                table.sort(buffKeys)
                
                for _, buffKey in ipairs(buffKeys) do
                    local buffDef = buffs[buffKey]
                    if not buffDef then continue end
                    
                    local buffRow = vgui.Create("DPanel", buffNamesScroll)
                    if not IsValid(buffRow) then continue end
                    
                    buffRow:Dock(TOP)
                    buffRow:DockMargin(0, 2, 0, 2)
                    buffRow:SetTall(30)
                    function buffRow:Paint(w, h)
                        draw.RoundedBox(2, 0, 0, w, h, Color(40, 44, 52, 150))
                    end
                    
                    -- Buff key label
                    local keyLabel = vgui.Create("DLabel", buffRow)
                    if IsValid(keyLabel) then
                        keyLabel:SetText(buffKey .. ":")
                        keyLabel:Dock(LEFT)
                        keyLabel:SetWide(120)
                        keyLabel:DockMargin(5, 5, 5, 5)
                        keyLabel:SetTextColor(Color(200, 200, 200))
                    end
                    
                    -- Text entry for custom name
                    local nameEntry = vgui.Create("DTextEntry", buffRow)
                    if IsValid(nameEntry) then
                        nameEntry:Dock(FILL)
                        nameEntry:DockMargin(5, 5, 5, 5)
                        nameEntry:SetPlaceholderText("Enter custom display name...")
                        
                        -- Set current value
                        local currentName = DRITUAL.Config.buffDisplayNames[buffKey] or buffDef.title or buffKey
                        nameEntry:SetValue(currentName)
                        
                        -- Save on change
                        function nameEntry:OnTextChanged()
                            local newName = self:GetValue()
                            if newName and newName != "" then
                                DRITUAL.Config.buffDisplayNames[buffKey] = newName
                            else
                                DRITUAL.Config.buffDisplayNames[buffKey] = nil
                            end
                            -- Save to file immediately
                            local json = util.TableToJSON(DRITUAL.Config or {}, true)
                            local success, err = pcall(function()
                    file.Write("dritual_config.txt", json)
                end)
                if not success then
                    ErrorNoHaltWithStack("[dRitual] Failed to save config: " .. tostring(err))
                end
                        end
                    end
                end
            end
            
            -- Create the editors with a delay to ensure everything is ready
            timer.Simple(0.2, function()
                if IsValid(buffNamesScroll) then
                    createBuffNameEditors()
                end
            end)
            
            -- Reset button
            local resetButton = vgui.Create("DButton", buffNamesSection)
            resetButton:Dock(BOTTOM)
            resetButton:DockMargin(10, 5, 10, 10)
            resetButton:SetTall(25)
            resetButton:SetText("Reset to Default Names")
            resetButton:SetTextColor(Color(255, 255, 255))
            function resetButton:Paint(w, h)
                draw.RoundedBox(4, 0, 0, w, h, Color(60, 64, 72, 200))
            end
            function resetButton:DoClick()
                DRITUAL.Config.buffDisplayNames = {}
                -- Save to file
                local json = util.TableToJSON(DRITUAL.Config or {}, true)
                local success, err = pcall(function()
                    file.Write("dritual_config.txt", json)
                end)
                if not success then
                    ErrorNoHaltWithStack("[dRitual] Failed to save config: " .. tostring(err))
                end
                -- Recreate editors safely
                if IsValid(buffNamesScroll) then
                    createBuffNameEditors()
                end
            end
            
            sheet:AddSheet("General", generalPanel, "icon16/cog.png")
        end

        if IsValid(frame._bottom) then 
            frame._bottom:Remove() 
        end
        local bottom = vgui.Create("DPanel", frame)
        frame._bottom = bottom
        bottom:Dock(BOTTOM)
        bottom:SetTall(42)
        function bottom:Paint(w, h)
            draw.RoundedBox(0, 0, 0, w, h, Color(12, 14, 18, 245))
            surface.SetDrawColor(0, 0, 0, 180)
            surface.DrawRect(0, 0, w, 1)
        end

        local save = vgui.Create("DButton", bottom)
        save:Dock(RIGHT)
        save:SetWide(180)
        save:SetText("Save & Apply (Admin)")
        function save:DoClick()
            local tabs = sheet.Items or {}
            local packets = {}
            for _, it in ipairs(tabs) do
                if IsValid(it.Panel) and it.Panel._collect then
                    local c = it.Panel._collect()
                    table.insert(packets, c)
                end
            end
            -- collect pack selections
            local packSelections = {}
            local weaponOverrides = {}
            local packChecked = {}    
            local packHasEnabled = {}  
            local entitySelections = {}
            for _, it in ipairs(tabs) do
                if it.Tab and it.Tab:GetText() == "Weapon Packs" and it.Panel and it.Panel._packCheckboxes then
                    for _, cb in ipairs(it.Panel._packCheckboxes) do
                        if IsValid(cb) then
                            local pName = cb:GetText()
                            packChecked[pName] = cb:GetChecked() and true or false
                        end
                    end
                    -- collect per-weapon override states
                    for cat, data in pairs(it.Panel._packContainers or {}) do
                        local wl = data.weaponList
                        if not IsValid(wl) then continue end
                        
                        for _, row in ipairs(wl._rows or {}) do
                            if not IsValid(row) or not row._weaponClass then continue end
                            
                            local enabled = (row._selected == nil) and true or row._selected
                            if enabled then 
                                packHasEnabled[cat] = true 
                            end
                            weaponOverrides[#weaponOverrides + 1] = { class = row._weaponClass, disabled = (not enabled) }
                        end
                    end
                end
                if it.Tab and it.Tab:GetText() == "Entities" then
                    if it.Panel and it.Panel._catContainers then
                        for cat, data in pairs(it.Panel._catContainers) do
                            if data.grid and data.grid._tiles then
                                for _, tile in ipairs(data.grid._tiles) do
                                    if not IsValid(tile) then 
                                        continue 
                                    end
                                    if not tile._entClass then 
                                        continue 
                                    end
                                    
                                    entitySelections[#entitySelections + 1] = { class = tile._entClass, enabled = tile._selected }
                                end
                            end
                        end
                    end
                end
            end

            for pack, checked in pairs(packChecked) do
                if checked or packHasEnabled[pack] then
                    packSelections[#packSelections + 1] = { pack = pack, enabled = true }
                else
                    packSelections[#packSelections + 1] = { pack = pack, enabled = false }
                end
            end

            for pack, _ in pairs(packHasEnabled) do
                if packChecked[pack] == nil then
                    packSelections[#packSelections + 1] = { pack = pack, enabled = true }
                end
            end
            net.Start("dr_ritual_cfg_update")
                net.WriteUInt(#packets, 12)
                for _, c in ipairs(packets) do
                    net.WriteString(c.key)
                    net.WriteBool(c.enabled and true or false)
                    net.WriteUInt(#(c.fields or {}), 8)
                    for _, f in ipairs(c.fields or {}) do
                        net.WriteString(f.key)
                        net.WriteString(f.type or "number")
                        if f.type == "bool" then 
                            net.WriteBool(f.val and true or false) 
                        else 
                            net.WriteFloat(tonumber(f.val) or 0) 
                        end
                    end
                end
            net.SendToServer()

            if #packSelections > 0 then
                net.Start("dr_ritual_packs_update")
                    net.WriteUInt(#packSelections, 12)
                    for _, p in ipairs(packSelections) do
                        net.WriteString(p.pack)
                        net.WriteBool(p.enabled and true or false)
                    end
                net.SendToServer()
            end

            if #weaponOverrides > 0 then
                net.Start("dr_ritual_weapon_overrides_update")
                    net.WriteUInt(#weaponOverrides, 14)
                    for _, o in ipairs(weaponOverrides) do
                        net.WriteString(o.class)
                        net.WriteBool(o.disabled and true or false)
                    end
                net.SendToServer()
            end

            if #entitySelections > 0 then
                net.Start("dr_ritual_entities_update")
                    net.WriteUInt(#entitySelections, 12)
                    for _, e in ipairs(entitySelections) do
                        net.WriteString(e.class)
                        net.WriteBool(e.enabled and true or false)
                    end
                net.SendToServer()
            end
        end
    end

    -- placeholder until data arrives
    frame._loadingLabel = vgui.Create("DLabel", frame)
    frame._loadingLabel:SetText("Loading config from server...")
    frame._loadingLabel:Dock(FILL)
    frame._loadingLabel:SetContentAlignment(5)

    -- store for populate when receive
    frame._instanceTag = "dr_ritual_menu_frame"
    DRITUAL._openFrame = frame
end

concommand.Add("dr_ritual_menu", function(ply, cmd, args)
    if IsValid(DRITUAL._openFrame) then 
        DRITUAL._openFrame:Remove() 
    end
    openMenu()
end)

-- Receive full entity list
net.Receive("dr_ritual_entities_full", function()
    local count = net.ReadUInt(12) or 0
    local list = {}
        for i = 1, count do
            local cls = net.ReadString()
            local mdl = net.ReadString()
            local enabled = net.ReadBool()
            local category = net.ReadString()
            local display = net.ReadString()
            list[#list + 1] = { class = cls, model = mdl, enabled = enabled, category = category, display = display }
        end
    if IsValid(DRITUAL._openFrame) and DRITUAL._openFrame._sheet then
        for _, it in ipairs(DRITUAL._openFrame._sheet.Items or {}) do
            if it.Tab and it.Tab:GetText() == "Entities" and it.Panel and it.Panel._populateEntities then
                it.Panel:_populateEntities(list)
                break
            end
        end
    end
end)

-- Receive weapon packs list
net.Receive("dr_ritual_packs_full", function()
    local count = net.ReadUInt(12) or 0
    local list = {}
    for i = 1, count do
        local pack = net.ReadString()
        local enabled = net.ReadBool()
        list[#list + 1] = { pack = pack, enabled = enabled }
    end
    if IsValid(DRITUAL._openFrame) and DRITUAL._openFrame._sheet then
        for _, it in ipairs(DRITUAL._openFrame._sheet.Items or {}) do
            if it.Tab and it.Tab:GetText() == "Weapon Packs" and it.Panel and it.Panel._populatePacks then
                it.Panel:_populatePacks(list)
            end
        end
    end
end)

-- Receive detailed weapon list for a single pack
net.Receive("dr_ritual_pack_details_full", function()
    local cat = net.ReadString() or ""
    local count = net.ReadUInt(12) or 0
    local weapons = {}
    for i = 1, count do
        local cls = net.ReadString()
        local name = net.ReadString()
        local mdl = net.ReadString()
        local disabled = net.ReadBool() -- true means disabled override
        weapons[#weapons + 1] = { class = cls, name = name, model = mdl, disabled = disabled }
    end
    if cat == "" then return end
    if not (IsValid(DRITUAL._openFrame) and DRITUAL._openFrame._sheet) then return end
    for _, it in ipairs(DRITUAL._openFrame._sheet.Items or {}) do
        if it.Tab and it.Tab:GetText() == "Weapon Packs" and it.Panel then
            local pnl = it.Panel
            local data = pnl._packContainers and pnl._packContainers[cat]
            if data and IsValid(data.weaponList) and IsValid(data.container) then
                local wl = data.weaponList
                -- clear existing
                for _, r in ipairs(wl._rows or {}) do 
                    if IsValid(r) then 
                        r:Remove() 
                    end 
                end
                wl._rows = {}
                for _, w in ipairs(weapons) do
                    local tile = wl._grid:Add("DButton")
                    tile:SetText("")
                    tile:SetSize(92, 92)
                    tile._weaponClass = w.class
                    tile._weaponName = w.name or w.class
                    tile._weaponModel = (w.model and w.model != "") and w.model or "models/weapons/w_pistol.mdl"
                    tile._selected = not w.disabled
                    function tile:SetSelectedState(on)
                        self._selected = on and true or false
                        self:InvalidateLayout(true)
                    end
                    function tile:DoClick()
                        self._selected = not self._selected
                        self:InvalidateLayout(true)
                    end
                    function tile:Paint(wi, hi)
                        local sel = self._selected
                        local bg     = sel and Color(70, 72, 78, 255) or Color(40, 42, 48, 230)
                        local border = sel and Color(150, 150, 160, 255) or Color(55, 58, 66, 255)
                        surface.SetDrawColor(bg)    
                        surface.DrawRect(0, 0, wi, hi)
                        surface.SetDrawColor(border) 
                        surface.DrawOutlinedRect(0, 0, wi, hi)
                        draw.SimpleText(self._weaponName, "DermaDefault", wi * 0.5, hi - 10, sel and Color(235, 235, 235) or Color(180, 180, 185), TEXT_ALIGN_CENTER, TEXT_ALIGN_BOTTOM)
                    end
                    -- Spawn icon
                    local icon = vgui.Create("SpawnIcon", tile)
                    icon:SetSize(64, 64)
                    icon:Dock(TOP)
                    icon:DockMargin(14, 4, 14, 2)
                    icon:SetModel(tile._weaponModel)
                    if string.find(string.lower(tile._weaponModel), "/w_") then
                        local attempts = 0
                        local function tryRotate()
                            attempts = attempts + 1
                            if not IsValid(icon) then return end
                            local ent = icon.Entity
                            if not IsValid(ent) then
                                if attempts < 8 then 
                                    timer.Simple(0.05, tryRotate) 
                                end
                                return
                            end
                            local ang = ent:GetAngles()
                            ang:RotateAroundAxis(ang:Up(), 90)
                            ent:SetAngles(ang)
                        end
                        timer.Simple(0, tryRotate)
                    end
                    icon:SetTooltip(tile._weaponName .. "\n" .. tile._weaponClass)
                    function icon:DoClick()
                        tile:DoClick()
                    end
                    wl._rows[#wl._rows + 1] = tile
                end
                -- Height thingy
                wl:InvalidateLayout(true)
                local containerRef = data.container
                timer.Simple(0, function()
                    if not (IsValid(wl) and IsValid(containerRef)) then return end
                    if not wl:IsVisible() then return end
                    local columns = math.max(1, math.floor((wl:GetWide() - 10) / (92 + 6)))
                    local rows = math.ceil(#wl._rows / columns)
                    local h = rows * (92 + 6) + 6
                    wl:SetTall(h)
                    containerRef:SetTall(24 + wl:GetTall() + 6)
                    if IsValid(pnl) and pnl:GetParent() and pnl:GetParent().InvalidateLayout then 
                        pnl:GetParent():InvalidateLayout(true) 
                    end
                end)
                if wl._autoSelectAll then
                    for _, row in ipairs(wl._rows) do 
                        if IsValid(row) and row.SetSelectedState then 
                            row:SetSelectedState(true) 
                        end 
                    end
                    wl._autoSelectAll = nil
                end
                -- Resize weaponList and container
                if wl:IsVisible() then
                    data.container:SetTall(24 + wl:GetTall() + 6)
                else
                    wl:SetTall(0)
                    data.container:SetTall(24)
                end
                wl:InvalidateLayout(true)
            end
        end
    end
end)

-- Receive full config and populate UI
net.Receive("dr_ritual_cfg_full", function()
    local count = net.ReadUInt(8) or 0
    local list = {}
    for i = 1, count do
        local key = net.ReadString()
        local title = net.ReadString()
        local enabled = net.ReadBool()
        local fcount = net.ReadUInt(8) or 0
        local fields = {}
        local values = {}
        for j = 1, fcount do
            local fkey = net.ReadString()
            local flabel = net.ReadString()
            local ftype = net.ReadString()
            if ftype == "bool" then
                local v = net.ReadBool()
                table.insert(fields, { key = fkey, label = flabel, type = ftype })
                values[fkey] = v and true or false
            else
                local v = net.ReadFloat()
                table.insert(fields, { key = fkey, label = flabel, type = ftype })
                values[fkey] = v
            end
        end
        table.insert(list, { key = key, title = title, enabled = enabled, fields = fields, values = values })
    end
    if IsValid(DRITUAL._openFrame) and DRITUAL._openFrame._populate then
        DRITUAL._openFrame._populate(list)
    end
end)
