-- Story party: only the host has AI companions. A guest's own partner / visitor / battlers are switched off
-- (AI stopped, hidden, no collision, gone from its party HUD) and not sent to the host as ghosts; the guest sees
-- the host's companions as ghosts instead. The companions still exist (the game expects them - quest start,
-- partner menus), they're just out of the way. Loaded by coop.lua; shares its environment.

Party = Party or {}
Party.GuestSolo = true   -- set false to let guests keep their own companions
Party.HostSolo = Party.HostSolo or false   -- true: the host's companions are switched off too (just the players)

local function Valid(O) return O ~= nil and O:IsValid() end

local function Companions(Hero)
    local T = {}
    for _, C in ipairs({ Hero.PartnerCharacter, Hero.VisitorCharacter }) do if Valid(C) then T[#T + 1] = C end end
    pcall(function()
        local B = Hero.BattlerCharacter
        for i = 1, #B do
            local C = B[i]
            if Valid(C) and not (Proxy and Proxy.Is(C)) then T[#T + 1] = C end   -- (not the other player's stand-in)
        end
    end)
    return T
end
Party.Companions = Companions

-- a companion and the weapon / shield actors it carries (those are separate actors - hiding only the companion
-- leaves them floating)
local function SetShown(C, Shown)
    for _, A in ipairs({ C, C.EquippedWeapon, C.EquippedShield }) do
        if Valid(A) and A.bHidden == Shown then
            pcall(function() A:SetActorHiddenInGame(not Shown); A:SetActorEnableCollision(Shown) end)
        end
    end
end

local function SetGauges(PC, Visible)
    pcall(function()
        local CK = PC.RODUIManagerRef.CockpitWidget
        for _, Name in ipairs({ "PartnerUnitGauge", "VisitorUnitGauge" }) do
            local G = CK[Name]
            if Valid(G) then G:SetVisibility(Visible and 4 or 1) end   -- SelfHitTestInvisible / Collapsed
        end
    end)
end

-- each companion's own AI switch (not the player controller's ServerStopAI, which reaches further than the
-- companions - it's the prime suspect for enemies on the guest being unable to attack)
local function SetAI(C, On)
    pcall(function()
        local Brain = C.Controller.BrainComponent
        local Running = Brain:IsRunning()
        if On and not Running then C:RestartAI() elseif not On and Running then C:StopAI() end
    end)
end

-- Per tick (cheap: does its work once a second). IsHost: the host keeps its companions (unless HostSolo).
function Party.Update(Hero, PC, IsHost, T)
    local Solo = IsHost and Party.HostSolo or (not IsHost and Party.GuestSolo)
    if not Solo then
        if Party.Hidden then   -- (switched back on)
            for _, C in ipairs(Companions(Hero)) do SetShown(C, true); SetAI(C, true) end
            SetGauges(PC, true)
            Party.Hidden = false
        end
        return
    end
    if (Party.NextCheck or 0) > T then return end
    Party.NextCheck = T + 1
    if not Party.Hidden then
        Party.Hidden = true
        Log("party: guest companions switched off (story party is the host's)")
    end
    for _, C in ipairs(Companions(Hero)) do
        SetShown(C, false); SetAI(C, false)
        -- (no invincible characters: the game makes partners battle-invincible while their concentration is
        -- high - lifted once per map with the game's own switch)
        if not Party.InvincibilityOff then
            pcall(function() for _ = 1, 4 do if C:K2_IsInvincible() then C:SetBattleInvincible(false) end end end)
        end
    end
    Party.InvincibilityOff = true
    SetGauges(PC, false)
end

function Party.Reset()
    Party.Hidden, Party.NextCheck = false, 0   -- new map: new companion actors, switch them off again
    Party.InvincibilityOff = false
end

Log("party.lua loaded")
