-- The other player on the HUD: the game's own (dormant) multiplayer party gauge - WBP_AnotherHeroUnitGauge in
-- the cockpit's AnotherHeroUnitGauge grid at the top left - showing the peer's name and HP. The game would
-- normally create it from a remote player state; here it's created directly and fed the HP from the network.
-- Loaded by coop.lua; shares its environment.

Hud = Hud or {}

local GaugeClass = "/Game/ROD/Widget/Cockpit/UnitGauge/WBP_AnotherHeroUnitGauge.WBP_AnotherHeroUnitGauge_C"

local function Valid(O) return O ~= nil and O:IsValid() end

local function Grid(PC)
    local UIM = Valid(PC) and PC.RODUIManagerRef or nil
    local CK = Valid(UIM) and UIM.CockpitWidget or nil
    local G = Valid(CK) and CK.AnotherHeroUnitGauge or nil
    return Valid(G) and G or nil
end

-- Create the gauge (once per map - the cockpit is rebuilt on a map change).
local function Create(PC, Hero, Name, FindAsset)
    local G = Grid(PC)
    local Cls = FindAsset(GaugeClass)
    if not (G and Cls) then return nil end
    local WBL = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary")
    local W = WBL:Create(PC, Cls, PC)
    if not Valid(W) then return nil end
    W.TargetCharacter = Hero   -- display only: nothing is bound to it
    G:AddAnotherNewHeroGauge(W)
    local W2 = PC:GetWorld()
    local GS = Valid(W2) and W2.GameState or nil
    local Town = Valid(GS) and GS.RODCurrentLevel == 3
    if Town then W:SetTownDisplay() else W:SetQuestDisplay() end
    W:OpenAnotherHeroGauge()
    pcall(function() W.PlayerName:SetText(FText(Name)) end)
    -- single player never shows this grid: it's collapsed, the gauge's detail panel (HP bar) is left at opacity 0
    -- by its unplayed open animation, and its slot overlaps the partner list - show it below the partners instead
    -- (it then appears and fades with the rest of the combat HUD)
    G:SetVisibility(4)   -- SelfHitTestInvisible
    G:SetRenderTranslation({ X = 20, Y = 75 })
    pcall(function() W.GaugeDeco:GetParent():SetRenderOpacity(1.0) end)
    Log("hud: peer gauge created (" .. (Town and "town" or "quest") .. ")")
    return W
end

-- The other player on the minimap: the minimap's own "AnotherPlayer" icon kind (EMapIconKind 2), placed at the
-- peer's ghost (UpdateIcon positions it from the actor).
local MapIconKind, MapIconId = 2, 1

local function UpdateMinimap(PC, Ghost)
    local MM = Hud.Minimap
    if not Valid(MM) then
        local UIM = Valid(PC) and PC.RODUIManagerRef or nil
        local CK = Valid(UIM) and UIM.CockpitWidget or nil
        MM = Valid(CK) and CK.Minimap or nil
        if not Valid(MM) then return end
        Hud.Minimap, Hud.MapIcon = MM, nil
    end
    if not Valid(Ghost) then
        if Valid(Hud.MapIcon) then Hud.MapIcon:SetVisibility(1) end
        return
    end
    if not Valid(Hud.MapIcon) then
        local I = MM:GetIconForMap(MapIconKind, MapIconId, true)
        if not (I and Valid(I)) then return end
        Hud.MapIcon = I
    end
    MM:UpdateIcon(MapIconKind, Ghost, Ghost:K2_GetActorLocation(), Hud.MapIcon)
    Hud.MapIcon:SetVisibility(4)
end

-- Per tick: Peer = the peer's state (nil = not here), Ghost = its ghost actor. Only touches the gauge when
-- something changed.
function Hud.Update(Peer, PC, Hero, FindAsset, Ghost)
    Hud.Frame = (Hud.Frame or 0) + 1
    if Hud.Frame % 3 == 0 then
        local Ok, Err = pcall(UpdateMinimap, PC, Peer and Ghost or nil)
        if not Ok and Hud.MapErr ~= tostring(Err) then Hud.MapErr = tostring(Err); Log("hud: minimap: " .. Hud.MapErr) end
    end
    if not Peer or not Peer.MaxHP then
        if Valid(Hud.Gauge) and not Hud.Hidden then Hud.Gauge:SetVisibility(1); Hud.Hidden = true end   -- Collapsed
        return
    end
    if not Valid(Hud.Gauge) then
        if Hud.Failed and os.clock() - Hud.Failed < 5 then return end
        local Ok, W = pcall(Create, PC, Hero, Hud.PeerName or "Player 2", FindAsset)
        if not (Ok and W) then
            Hud.Failed = os.clock()
            if not Ok then Log("hud: gauge failed: " .. tostring(W)) end
            return
        end
        Hud.Gauge, Hud.Failed, Hud.LastHP, Hud.Hidden, Hud.GaugeY = W, nil, nil, false, nil
    end
    if Hud.Hidden then Hud.Gauge:SetVisibility(4); Hud.Hidden = false end   -- SelfHitTestInvisible
    -- below the partner gauges when this player has companions, right under the player's own bars when not
    local WantY = (Party and Party.Hidden) and 0 or 75
    if Hud.GaugeY ~= WantY then
        Hud.GaugeY = WantY
        pcall(function() PC.RODUIManagerRef.CockpitWidget.AnotherHeroUnitGauge:SetRenderTranslation({ X = 20, Y = WantY }) end)
    end
    local Name = Peer.Name or Hud.PeerName or "Player 2"
    local Label = Revive and Revive.PeerLabel(Peer)   -- "DOWN 42s" / "reviving 60%"
    if Label then Name = Name .. "  " .. Label end
    if Hud.ShownName ~= Name then
        Hud.ShownName = Name
        pcall(function() Hud.Gauge.PlayerName:SetText(FText(Name)) end)
    end
    local Key = Peer.HP .. "/" .. Peer.MaxHP
    if Hud.LastHP ~= Key then
        Hud.LastHP = Key
        pcall(function() Hud.Gauge:OnHealthChanged(Peer.HP, Peer.MaxHP) end)
    end
end

---------------------------------------------------------------------------------------------------------------
-- Floating name plates: the game's (dormant) multiplayer plate, WBP_AnotherHeroNamePlate, kept over the other
-- player's ghost (name, downed state, "[V] Revive" prompt), and a second one at the bottom centre for the local
-- player's own status ("You are down ..."). Positioned by projecting to the screen every tick.

local PlateClass = "/Game/ROD/Widget/Cockpit/UnitGauge/WBP_AnotherHeroNamePlate.WBP_AnotherHeroNamePlate_C"

local function NewPlate(PC, FindAsset, Scale)
    local Cls = FindAsset(PlateClass)
    if not Cls then return nil end
    local W = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(PC, Cls, PC)
    if not Valid(W) then return nil end
    W:AddToViewport(50)
    -- the plate's content is centred on the widget's top-left corner (that's how the game's own UI manager places
    -- it over a head), so place that corner on the spot and scale around it
    W:SetAlignmentInViewport({ X = 0, Y = 0 })
    W:SetRenderTransformPivot({ X = 0, Y = 0 })
    W:SetRenderScale({ X = Scale, Y = Scale })
    pcall(function() W:SetHeroColor(1) end)
    W:SetVisibility(1)
    return { W = W }
end

local function SetPlate(P, Text, Retire, X, Y)
    local W = P.W
    if not Text then
        if P.Shown then W:SetVisibility(1); P.Shown = false end
        return
    end
    W:SetPositionInViewport({ X = X, Y = Y }, false)   -- (X, Y are already in widget units)
    if P.Text ~= Text then P.Text = Text; W:SetPlayerName(FText(Text)) end
    if P.Retire ~= Retire then P.Retire = Retire; pcall(function() W:ChangeHeroRetireState(Retire) end) end
    if not P.Shown then W:SetVisibility(4); P.Shown = true end
end

-- Ghost = the peer's ghost actor (nil = not here); PeerText / SelfText from revive.lua (nil = nothing to show).
function Hud.UpdatePlates(PC, FindAsset, Ghost, PeerText, PeerDown, SelfText)
    if not (Valid(Hud.PeerPlate and Hud.PeerPlate.W) and Valid(Hud.SelfPlate and Hud.SelfPlate.W)) then
        if (Hud.PlateRetry or 0) > os.clock() then return end
        Hud.PlateRetry = os.clock() + 5   -- (not every tick if the widget class can't be loaded)
        if not Valid(Hud.PeerPlate and Hud.PeerPlate.W) then Hud.PeerPlate = NewPlate(PC, FindAsset, 1.3) end
        if not Valid(Hud.SelfPlate and Hud.SelfPlate.W) then Hud.SelfPlate = NewPlate(PC, FindAsset, 1.8) end
    end
    local WLL = StaticFindObject("/Script/UMG.Default__WidgetLayoutLibrary")
    local P = Hud.PeerPlate
    if P then
        local Text, X, Y = nil, 0, 0
        if Valid(Ghost) and PeerText then
            -- just above the ghost's head bone (follows it when the player is lying down too)
            local Head = Ghost.SkeletalMeshComponent:GetSocketLocation(FName("head"))
            local S = {}
            if WLL:ProjectWorldLocationToWidgetPosition(PC, { X = Head.X, Y = Head.Y, Z = Head.Z + 35 }, S, false) and S.X then
                Text, X, Y = PeerText, S.X, S.Y
            end
        end
        SetPlate(P, Text, PeerDown and true or false, X, Y)
    end
    local Me = Hud.SelfPlate
    if Me then
        local X, Y = 960, 780   -- (bottom centre in widget units at 1080p scale; replaced below)
        pcall(function()
            local V, Scale = WLL:GetViewportSize(PC), WLL:GetViewportScale(PC)
            X, Y = V.X * 0.5 / Scale, V.Y * 0.72 / Scale
        end)
        SetPlate(Me, SelfText, SelfText ~= nil, X, Y)
    end
end

function Hud.Reset()
    for _, P in ipairs({ Hud.PeerPlate or {}, Hud.SelfPlate or {} }) do
        if Valid(P.W) then pcall(function() P.W:RemoveFromParent() end) end
    end
    Hud.PeerPlate, Hud.SelfPlate, Hud.PlateRetry = nil, nil, nil
    if Valid(Hud.Gauge) then pcall(function() Hud.Gauge:RemoveFromParent() end) end
    if Valid(Hud.MapIcon) then pcall(function() Hud.MapIcon:SetVisibility(1) end) end
    Hud.Gauge, Hud.LastHP, Hud.Failed, Hud.Hidden, Hud.ShownName, Hud.GaugeY = nil, nil, nil, nil, nil, nil
    Hud.Minimap, Hud.MapIcon = nil, nil
end

Log("hud.lua loaded")
