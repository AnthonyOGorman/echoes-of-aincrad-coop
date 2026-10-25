-- Co-op downed / dead / revive. In single player a hero death is an instant game over (checkpoint restart).
-- With the other player around we catch the lethal hit instead (HP held at 1) and the hero goes:
--   down: falls and lies on the ground, no control; the other player can revive them ("[V] Revive" next to them,
--         stay a few seconds - the game's revive-an-ally animation). Their AI partners carry on (they can't revive
--         a player anyway); Revive.DownPartyWithPlayer = true downs them too (they get back up on the game's own
--         ~28 s timer, so they're knocked down again each time).
--   dead: not revived within DownTime - stays lying there (no game over) until the other player reaches a safe
--         zone (a terminal's safe area), then gets up next to them.
--   both players down / dead = a real death for both (the game's game over and checkpoint restart).
-- Loaded by coop.lua; shares its environment.
--
-- Wire format: "X=<state 0 up / 1 down / 2 dead / 3 gone (real death)>,<seconds left>,<revives done>,<in a safe
-- zone 0/1>" - the downed side gets up when the other side's revive count goes up.

Revive = Revive or {}

local DownTime = 60          -- seconds a downed player can be revived
local ReviveDistance = 250   -- cm between the reviver and the downed player
local ReviveTime = 3.0       -- seconds the reviver has to stay there
local RisePlayRate = 1.4     -- the get-up animation is long; play it a bit faster
local DeathGEName, ReviveGEName = "Default__GE_AvatarInstantDeath_C", "Default__GE_AvatarRevive_C"

local function Valid(O) return O ~= nil and O:IsValid() end

Revive.Done = Revive.Done or 0     -- revives this player has completed (sent to the other side)
Revive.State = Revive.State or "up"

---------------------------------------------------------------------------------------------------------------
-- Game assets and helpers

-- the hero's own animations (the paths depend on the body type: .../Hero/Male/... or .../Hero/Female/...)
local function AnimPaths(Hero)
    local Body = "Male"
    pcall(function() if Hero.Mesh:GetAnimInstance():GetClass():GetFName():ToString():find("Female") then Body = "Female" end end)
    local Dir = "/Game/ROD/ANM/CHR/Humans/Hero/" .. Body .. "/NON/00/"
    local function P(Sub, Name) return Dir .. Sub .. Name:gsub("Male", Body) .. "." .. Name:gsub("Male", Body) end
    return {
        Fall = P("Damage/DownProne_00/", "A_HS_Male_NON_00_Damage_DownProne_00_St"),
        Lie = P("Damage/DownProne_00/", "A_HS_Male_NON_00_Damage_DownProne_00_Lp"),
        Rise = P("Damage/DownProne_00/", "A_HS_Male_NON_00_Damage_DownProne_00_Ed_01"),
        Revive = P("Revive/Ally_00/", "AM_HS_Male_NON_00_Revive_Ally_00"),
    }
end

-- the game's own instant-death effect, and the revive effect's defaults (its modifier holds a Health attribute
-- handle - FGameplayAttribute can't be built from Lua - for setting HP the proper GAS way). Found once.
local function Effects()
    if Revive.DeathGE and Valid(Revive.DeathGE) then return Revive.DeathGE, Revive.ReviveCDO end
    ForEachUObject(function(O)
        local N = O:GetFName():ToString()
        if N == DeathGEName then Revive.DeathGE = O:GetClass() elseif N == ReviveGEName then Revive.ReviveCDO = O end
    end)
    return Revive.DeathGE, Revive.ReviveCDO
end

-- Set the hero's HP and refresh the HUD's HP bar. (Not ApplyInstantGameplayEffect: it creates a transient
-- GameplayEffect object on the character that something keeps alive, and the next map change then dies with
-- "Fatal world leaks detected".)
local function SetHealthGAS(Char, HP)
    local D = Char.DefensiveAttributeSet
    D.Health.CurrentValue, D.Health.BaseValue = HP, HP
    pcall(function()
        Coop.LocalPC().RODUIManagerRef.CockpitWidget:OnHealthChangedEvent(HP, D.MaxHealth.CurrentValue)
    end)
end

local function ApplyEffect(Char, Cls)
    if not (Valid(Char) and Cls) then return end
    local ASC = Char.AbilitySystem
    ASC:BP_ApplyGameplayEffectToSelf(Cls, 1.0, ASC:MakeEffectContext())
end

local function PartyMembers(Hero)
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

local function DownParty(Hero)
    local DeathGE = Effects()
    for _, C in ipairs(PartyMembers(Hero)) do if not C:IsDead() then pcall(ApplyEffect, C, DeathGE) end end
end

-- Hero body animations play on the avatar's linked body anim instance (montages on the main instance don't move
-- the body). Plain animations become a montage on the fly in DefaultSlot. Returns the length (0 if not played).
local function PlayBody(Hero, Path, Loops, Rate)
    local Asset = Ghost2.FindAsset(Path)
    local AI = Hero:GetAvatarLinkedAnimGraphInstance()
    if not (Asset and Valid(AI)) then return 0 end
    Rate = Rate or 1.0
    if Asset:GetClass():GetFName():ToString() == "AnimMontage" then
        return AI:Montage_Play(Asset, Rate, 0, 0, true) or 0
    end
    local M = AI:PlaySlotAnimationAsDynamicMontage(Asset, FName("DefaultSlot"), 0.2, 0.25, Rate, 1, -1.0, 0.0)
    -- looping: point the montage's only section back at itself, so it never ends
    if Loops and Loops > 1 and Valid(M) then
        pcall(function() AI:Montage_SetNextSection(FName("Default"), FName("Default"), M) end)
    end
    return Asset:GetPlayLength() / Rate
end

local function StopBody(Hero)
    local AI = Hero:GetAvatarLinkedAnimGraphInstance()
    if Valid(AI) then AI:Montage_Stop(0.25, nil) end
end

-- The lethal hit we catch still reaches the hero's own HP listeners at 0, and death effects may fade the hero's
-- materials ("Opacity" to 0 on the body and the sword / shield). Keep them at 1 while down.
local MeshComponentClass, MIDClass
local function KeepVisible(Hero)
    MeshComponentClass = MeshComponentClass or StaticFindObject("/Script/Engine.MeshComponent")
    MIDClass = MIDClass or StaticFindObject("/Script/Engine.MaterialInstanceDynamic")
    local Opacity = FName("Opacity")
    for _, A in ipairs({ Hero, Hero.EquippedWeapon, Hero.EquippedShield }) do
        if Valid(A) then
            local Comps = A:K2_GetComponentsByClass(MeshComponentClass)
            for i = 1, #Comps do
                local C = Comps[i]
                if type(C) == "userdata" and not C.IsValid and C.get then C = C:get() end
                if Valid(C) then
                    for m = 0, C:GetNumMaterials() - 1 do
                        local M = C:GetMaterial(m)
                        if Valid(M) and M:IsA(MIDClass) and M:K2_GetScalarParameterValue(Opacity) < 1 then
                            M:SetScalarParameterValue(Opacity, 1.0)
                        end
                    end
                end
            end
        end
    end
end
Revive.KeepVisible = KeepVisible

---------------------------------------------------------------------------------------------------------------
-- Catching the lethal hit. The cockpit's OnHealthChangedEvent is bound to the local hero's HP change and runs
-- before the game decides on death, so setting HP back to 1 there means the hero never dies.

if not Revive.Hooked then
    Revive.Hooked = pcall(RegisterHook, "/Script/ROD.RODCockpitWidgetBase:OnHealthChangedEvent", function(Ctx, NewHealth)
        local Ok, Err = pcall(function()
            if NewHealth:get() > 0 or not Revive.Guard then return end
            local Hero = Revive.Hero
            if not Valid(Hero) then return end
            local D = Hero.DefensiveAttributeSet
            D.Health.CurrentValue = 1
            D.Health.BaseValue = 1
            NewHealth:set(1.0)
            if Revive.State == "up" then Revive.Pending = true end   -- go down on the next tick (not inside the game's damage code)
        end)
        if not Ok then Log("revive: guard: " .. tostring(Err)) end
    end)
end

-- Safe zones are the terminals' safe areas: checked once a second by overlap with the map's terminals, read
-- each time from the map's own list of accessible gimmicks. (Not by hooking
-- RODActivatableTerminalBase:OnEnterExitSafetyArea - a Blueprint overlap event that fires for every actor - which
-- was the prime suspect in a UE4SS crash when a player teleported into one. Not FindAllOf either: it walks every
-- object in the game, racing the field's background streaming; nor a list kept for the whole map, whose
-- terminals are destroyed as their part of the field unloads.)
local function CheckSafe(Hero, T)
    if (Revive.SafeCheckAt or 0) > T then return end
    Revive.SafeCheckAt = T + 1
    if not Valid(Revive.TerminalClass) then Revive.TerminalClass = StaticFindObject("/Script/ROD.RODActivatableTerminalBase") end
    local GS = Hero:GetWorld().GameState
    if not (Valid(GS) and Valid(Revive.TerminalClass)) then return end
    local Inside, L = false, GS.RODAccessibleGimmicks
    for i = 1, #L do
        local A = L[i]
        if type(A) == "userdata" and not A.IsValid and A.get then A = A:get() end
        if Valid(A) and A:IsA(Revive.TerminalClass) and Hero:IsOverlappingActor(A) then Inside = true break end
    end
    if Inside ~= (Revive.InSafe or false) then
        Revive.InSafe = Inside
        Log("revive: " .. (Inside and "entered" or "left") .. " a safe zone")
    end
end

---------------------------------------------------------------------------------------------------------------
-- State changes

local function GoDown(Hero, PC, Peer, T)
    Revive.State, Revive.DownAt, Revive.PeerSeenAt = "down", T, T
    Revive.SeenDone = Peer and Peer.Revive and Peer.Revive.Done or 0
    Revive.Anims = AnimPaths(Hero)
    local Len = PlayBody(Hero, Revive.Anims.Fall, 1)
    Revive.Phase, Revive.PhaseEnd = "fall", T + math.max(0.1, Len - 0.2)
    pcall(function() Hero:DisableInput(PC) end)
    if Revive.DownPartyWithPlayer then DownParty(Hero) end
    Log("revive: down - waiting for the other player")
end

local function GetUp(Hero, PC, T, Why)
    Revive.State = "up"
    Revive.GraceUntil = T + 1.5   -- HP changes right after getting up must not put us straight back down
    Revive.Anims = Revive.Anims or AnimPaths(Hero)
    local Len = PlayBody(Hero, Revive.Anims.Rise, 1, RisePlayRate)
    Revive.Phase, Revive.InputAt = "rise", T + math.max(0.3, Len - 0.3)   -- control back as the get-up ends
    SetHealthGAS(Hero, math.floor(Hero.DefensiveAttributeSet.MaxHealth.CurrentValue * 0.3))
    Revive.Pending = false
    for _, C in ipairs(PartyMembers(Hero)) do if C:IsDead() then pcall(function() C:Revive(C) end) end end
    Log("revive: " .. (Why or "revived"))
end

local function Die(Hero, PC, T)
    Revive.State, Revive.Guard, Revive.GoneAt, Revive.Phase = "gone", false, T, nil
    StopBody(Hero)
    pcall(function() Hero:EnableInput(PC) end)
    local DeathGE = Effects()
    pcall(ApplyEffect, Hero, DeathGE)
    Log("revive: real death (game over)")
end

-- Damage the host's enemies did to this player's stand-in there (proxy.lua): taken on the hero here, with the
-- same rules as a hit here - a lethal one puts the hero down while the other player can help, else it's a real
-- death.
function Revive.TakeDamage(Hero, PC, Amount, T)
    if Revive.State ~= "up" or T < (Revive.GraceUntil or 0) or not Valid(Hero) or Hero:IsDead() then return end
    local HP = math.floor(Hero.DefensiveAttributeSet.Health.CurrentValue - Amount + 0.5)
    if HP > 0 then
        SetHealthGAS(Hero, HP)
    elseif Revive.Guard then
        SetHealthGAS(Hero, 1)
        Revive.Pending = true   -- (down on the next update)
    else
        Die(Hero, PC, T)
    end
end

---------------------------------------------------------------------------------------------------------------

local StateCode = { up = 0, down = 1, dead = 2, gone = 3 }

function Revive.Token(Hero)
    local Left = Revive.State == "down" and math.max(0, DownTime - ((Revive.Now or 0) - (Revive.DownAt or 0))) or 0
    local Code = StateCode[Revive.State] or 0
    if Valid(Hero) and Hero:IsDead() then Code = 3 end
    return string.format("X=%d,%.0f,%d,%d", Code, Left, Revive.Done, Revive.InSafe and 1 or 0)
end

function Revive.Parse(Line)
    local C, L, N, S = Line:match(" X=(%d),([%d%.]+),(%d+),?(%d?)")
    if not C then return nil end
    C = tonumber(C)
    return { Code = C, Down = C == 1, Dead = C == 2, Gone = C == 3, Left = tonumber(L), Done = tonumber(N), Safe = S == "1" }
end

-- Per tick. Peer = the other player's state when it's on this map and fresh (nil otherwise).
-- V (the game's interact key) went down since the last check - read on the game thread from the player
-- controller's key state. (Not RegisterKeyBind: its callbacks run on UE4SS's own thread, and Lua touched from
-- two threads at once crashed the game.)
local VKey = { KeyName = FName("V") }
local function VPressed(PC)
    local Ok, Down = pcall(function() return PC:IsInputKeyDown(VKey) end)
    Down = Ok and Down or false
    local Pressed = Down and not Revive.VDown
    Revive.VDown = Down
    return Pressed
end

function Revive.Update(Hero, PC, Peer, T)
    Revive.Hero, Revive.Now = Hero, T
    pcall(CheckSafe, Hero, T)
    local PR = Peer and Peer.Revive
    local PeerOut = PR and (PR.Down or PR.Dead or PR.Gone)   -- the other player can't help right now

    -- back from a real death (the game's checkpoint restart brings the hero back)
    if Revive.State == "gone" then
        if not Hero:IsDead() and T - (Revive.GoneAt or T) > 5 then Revive.State = "up" end
        Revive.Guard = false
        return
    end

    -- only hold off death while there's someone (not out of it themselves) who can come and help
    Revive.Guard = Peer ~= nil and not PeerOut and not Hero:IsDead()

    if Revive.Pending then
        Revive.Pending = false
        if Revive.State == "up" and T >= (Revive.GraceUntil or 0) then GoDown(Hero, PC, Peer, T) end
    end

    -- getting up: control back when the animation ends
    if Revive.Phase == "rise" and T >= (Revive.InputAt or 0) then
        Revive.Phase = nil
        pcall(function() Hero:EnableInput(PC) end)
    end

    if Revive.State == "down" or Revive.State == "dead" then
        if Peer then Revive.PeerSeenAt = T end
        Revive.Guard = Peer ~= nil and not PeerOut   -- (keep holding HP while waiting)
        -- fall, then lie there (the lying loop is restarted if anything stopped it)
        local AI = Hero:GetAvatarLinkedAnimGraphInstance()
        if Revive.Phase == "fall" and T >= Revive.PhaseEnd then
            PlayBody(Hero, Revive.Anims.Lie, 1000)
            Revive.Phase = "lie"
        elseif Revive.Phase == "lie" and Valid(AI) and not Valid(AI:GetCurrentActiveMontage()) then
            PlayBody(Hero, Revive.Anims.Lie, 1000)
        end
        if (Revive.VisibleCheck or 0) <= T then
            Revive.VisibleCheck = T + 0.25
            pcall(KeepVisible, Hero)
        end
        -- (optional) the party stays down (they'd get back up on their own timer)
        if Revive.DownPartyWithPlayer and (Revive.PartyCheck or 0) < T then
            Revive.PartyCheck = T + 1
            DownParty(Hero)
        end

        if Revive.State == "down" and PR and PR.Done > (Revive.SeenDone or 0) then
            GetUp(Hero, PC, T, "revived")
        elseif PR and PR.Safe and not PeerOut then
            -- the other player made it to a safe zone: get up next to them
            local Back = math.rad((Peer.Yaw or 0) + 180)
            Hero:K2_SetActorLocation({ X = Peer.X + math.cos(Back) * 150, Y = Peer.Y + math.sin(Back) * 150, Z = Peer.Z + 30 }, false, {}, true)
            GetUp(Hero, PC, T, "back with the other player at a safe zone")
        elseif PeerOut or T - (Revive.PeerSeenAt or T) > 10 then
            Die(Hero, PC, T)   -- both out of it, or the other player has been gone for a while
        elseif Revive.State == "down" and T - Revive.DownAt > DownTime then
            Revive.State = "dead"
            Log("revive: not revived in time - dead until the other player reaches a safe zone")
        end
        return
    end

    -- the reviver: next to a downed player the screen says "[V] Revive"; pressing V starts it, then stay there
    local Pressed = VPressed(PC)
    Revive.InRange = false
    if PR and PR.Down and not Hero:IsDead() then
        local L = Hero:K2_GetActorLocation()
        local Dist = math.sqrt((L.X - Peer.X) ^ 2 + (L.Y - Peer.Y) ^ 2)
        local V = Hero:GetVelocity()
        local Moving = V.X * V.X + V.Y * V.Y > 150 * 150
        -- (after finishing a revive, wait for the other side to report it's up before starting another)
        Revive.InRange = Dist <= ReviveDistance and T >= (Revive.CooldownUntil or 0)
        if Revive.InRange and (Revive.ReviveStart or Pressed) and not (Revive.ReviveStart and Moving) then
            if not Revive.ReviveStart then
                Revive.ReviveStart = T
                Revive.Anims = Revive.Anims or AnimPaths(Hero)
                PlayBody(Hero, Revive.Anims.Revive)
                Log("revive: reviving the other player...")
            elseif T - Revive.ReviveStart >= ReviveTime then
                Revive.Done = Revive.Done + 1
                Revive.ReviveStart, Revive.CooldownUntil = nil, T + 2
                StopBody(Hero)
                Log("revive: revived the other player")
            end
        elseif Revive.ReviveStart then
            Revive.ReviveStart = nil
            StopBody(Hero)
        end
    elseif Revive.ReviveStart then
        Revive.ReviveStart = nil
        StopBody(Hero)
    end
end

---------------------------------------------------------------------------------------------------------------
-- Text for the HUD

local function Progress()
    return math.floor(math.min(1, ((Revive.Now or 0) - (Revive.ReviveStart or 0)) / ReviveTime) * 100)
end

-- suffix for the party gauge
function Revive.PeerLabel(Peer)
    local PR = Peer and Peer.Revive
    if not PR then return nil end
    if PR.Dead then return "DEAD" end
    if not PR.Down then return nil end
    if Revive.ReviveStart then return string.format("reviving %d%%", Progress()) end
    return string.format("DOWN %ds", PR.Left or 0)
end

-- the plate over the other player
function Revive.PlateText(Peer, Name)
    if not Peer then return nil end
    local PR = Peer.Revive
    if PR and PR.Dead then return Name .. "  DEAD" end
    if PR and PR.Down then return string.format("%s  DOWN %ds", Name, PR.Left or 0) end
    return Name
end

-- the centre-screen line: our own status, or the reviver's prompt / progress
function Revive.SelfText(PeerName, Peer)
    PeerName = PeerName or "your partner"
    if Revive.State == "down" then
        local Left = math.max(0, DownTime - ((Revive.Now or 0) - (Revive.DownAt or 0)))
        return string.format("You are down - %s can revive you (%ds)", PeerName, math.floor(Left))
    end
    if Revive.State == "dead" then
        return string.format("You died - %s can bring you back by reaching a safe zone", PeerName)
    end
    local PR = Peer and Peer.Revive
    if PR and PR.Down then
        if Revive.ReviveStart then return string.format("Reviving %s...  %d%%", PeerName, Progress()) end
        if Revive.InRange then return "[V] Revive " .. PeerName end
    end
    if PR and PR.Dead then return PeerName .. " died - reach a safe zone to bring them back" end
    return nil
end


function Revive.Reset()
    if (Revive.State == "down" or Revive.State == "dead" or Revive.Phase) and Valid(Revive.Hero) then
        pcall(function()   -- (a reload while down: give control back)
            Revive.Hero:EnableInput(Coop.LocalPC())
            StopBody(Revive.Hero)
        end)
    end
    Revive.State, Revive.Pending, Revive.ReviveStart, Revive.Guard, Revive.Phase = "up", false, nil, false, nil
    Revive.InSafe, Revive.SafeCheckAt = nil, 0
end

Log("revive.lua loaded")
