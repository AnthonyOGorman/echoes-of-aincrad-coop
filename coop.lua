-- AincradCoop: show the other game copy's hero and AI team members (partner, visitor) as animated ghosts.
--
-- Every other frame this copy writes its characters' state (position, velocity, weapon sockets, current
-- montage, map) as one line; it reads the other copy's line and drives the ghosts (ghost2.lua).
-- Transport "file": both copies on this PC read each other's coop_<role>.txt.
-- Transport "link": link_<me>_out.txt / link_<me>_in.txt, carried over UDP by coop_link.py.
-- Load or reload live:  luafile ue4ss/Mods/NetDebug/coop.lua
-- Start:                lua Coop.Start("A", "B", "link")   (and "B", "A" in the other copy)

Coop = Coop or {}
if Coop.Stop then pcall(Coop.Stop) end

-- The local player's controller (nil if none): the game instance (one per game; UEHelpers keeps it) -> its first
-- local player -> that player's controller. A few property reads, always the current map's. Every module uses
-- this: UEHelpers.GetPlayerController()/GetWorld() scan every object in the game for it (~35 ms a time on a fast
-- PC), and doing that on a timer cost a third of the frame rate - far more on a slower PC.
function Coop.LocalPC()
    local GI = UEHelpers.GetGameInstance()
    if not GI:IsValid() or #GI.LocalPlayers < 1 then return nil end
    local LP = GI.LocalPlayers[1]
    if type(LP) == "userdata" and not LP.IsValid and LP.get then LP = LP:get() end
    local PC = LP and LP:IsValid() and LP.PlayerController or nil
    return (PC and PC:IsValid()) and PC or nil
end

-- ghost2.lua (player/team ghosts), enemies.lua (enemy sync), loot.lua (drops), hud.lua (the other player's
-- HP gauge / minimap marker), revive.lua (downed / revive), party.lua (only the host keeps AI companions) and
-- proxy.lua (the guest's stand-in that the host's enemies target and hit; the guest takes those hits) and
-- lobby.lua (the multiplayer point in the bedroom and its Create / Join menu) and quests.lua (only the host picks
-- quests: the guest's terminals are locked) share this environment.
for _, Name in ipairs({ "ghost2.lua", "enemies.lua", "loot.lua", "hud.lua", "revive.lua", "party.lua", "proxy.lua", "lobby.lua",
                        "quests.lua" }) do
    local F = io.open("ue4ss/Mods/NetDebug/" .. Name, "r")
    if F then
        local Chunk, Err = load(F:read("*a"), "@" .. Name, "t", _ENV)
        F:close()
        if Chunk then Chunk() else Log("coop: " .. Name .. ": " .. tostring(Err)) end
    end
end

local Dir = "ue4ss/Mods/NetDebug/"
local SendEveryFrames = 2
local StaleSeconds = 2.0
local HostLostSeconds = 15     -- guest: host silent this long (out in a field) = back to town

local AvatarClass = StaticFindObject("/Script/ROD.RODAvatarCharacter")

-- The controller and world are looked up each time (cheap, Coop.LocalPC), never kept: after a map change a kept
-- one's address can hold another object, which IsValid() accepts (copy 2's hero went missing that way, and a
-- world kept across map changes turned into a sky sub-level).
local function PlayerController()
    return Coop.LocalPC() or CreateInvalidObject()
end

local function World()
    local PC = PlayerController()
    return (PC and PC:IsValid()) and PC:GetWorld() or nil
end

local function Now()
    return UEHelpers.GetGameplayStatics():GetRealTimeSeconds(World())
end

local function Valid(O) return O ~= nil and O:IsValid() end

local function LocalHero()
    local PC = PlayerController()
    if not PC:IsValid() then return nil end
    local Pawn = PC.Pawn
    if Valid(Pawn) and AvatarClass and Pawn:IsA(AvatarClass) then return Pawn end
    return nil
end

-- Name of the map this copy is in. Coordinates only mean the same thing when both copies are on the same map.
local function MapName()
    local W = World()
    return Valid(W) and W:GetFName():ToString() or "-"
end

-- Element I of the hero's BattlerCharacter array (extra AI companions some content adds), or nil.
local function Battler(Hero, I)
    local Arr = Hero.BattlerCharacter
    if not Arr or #Arr < I then return nil end
    local C = Arr[I]
    if type(C) == "userdata" and not C.IsValid and C.get then C = C:get() end
    if Proxy and Proxy.Is(C) then return nil end   -- (the other player's stand-in isn't sent back to them)
    return C
end

-- The ghosts, their line tokens, and which local character each one copies its look from.
local Kinds = {
    { Key = "Hero", Parts = Ghost2.HeroParts, Source = function(Hero) return Hero end },
    { Key = "Partner", Token = "P", Source = function(Hero) return Hero.PartnerCharacter end },
    { Key = "Visitor", Token = "V", Source = function(Hero) return Hero.VisitorCharacter end },
    { Key = "Battler1", Token = "B1", Source = function(Hero) return Battler(Hero, 1) end },
    { Key = "Battler2", Token = "B2", Source = function(Hero) return Battler(Hero, 2) end },
    { Key = "Battler3", Token = "B3", Source = function(Hero) return Battler(Hero, 3) end },
}
Coop.Ghosts = {}
for _, K in ipairs(Kinds) do Coop.Ghosts[K.Key] = Ghost2.New(K.Key, K.Parts) end

local function OutPath()
    if Coop.Transport == "link" then return Dir .. "link_" .. Coop.Me .. "_out.txt" end
    return Dir .. "coop_" .. Coop.Me .. ".txt"
end

local function InPath()
    if Coop.Transport == "link" then return Dir .. "link_" .. Coop.Me .. "_in.txt" end
    return Dir .. "coop_" .. Coop.Peer .. ".txt"
end

---------------------------------------------------------------------------------------------------------------
-- Encoding. Line: "<seq> <x> <y> <z> <yaw> <vx> <vy> <vz> W=<sword> S=<shield> M=<montage> L=<map>" followed by
-- a token per present team member: P=<partner> V=<visitor> B1..B3=<battlers>. Sword/shield =
-- "<parent component>:<socket>", montage = "<object path>@<position>", team member =
-- "x,y,z,yaw,vx,vy,vz,<sword>,<shield>,<montage>". Q=<appearance> (ghost2.lua) comes about once a second.

local function NameOf(O)
    return Valid(O) and O:GetFName():ToString() or "-"
end

local function AttachInfo(Actor)
    if not Valid(Actor) then return "-" end
    local Root = Actor.RootComponent
    if not Valid(Root) then return "-" end
    return NameOf(Root:GetAttachParent()) .. ":" .. Root:GetAttachSocketName():ToString()
end

local function MontageInfo(Char)
    -- montages normally run on the main anim instance; avatars (heroes, partners) can also use their linked
    -- graph instance - enemies don't have one
    local Instances = { Char.Mesh:GetAnimInstance() }
    if Char:IsA(AvatarClass) then Instances[2] = Char:GetAvatarLinkedAnimGraphInstance() end
    for _, AI in ipairs(Instances) do
        if Valid(AI) then
            local M = AI:GetCurrentActiveMontage()
            if Valid(M) then
                local Path = M:GetFullName():match("^%S+ (.+)$")
                if Path and Path:find("^/Engine/Transient") then
                    -- a montage made on the fly from a plain animation (e.g. the downed loop): send that animation
                    -- (looping ones wrap around)
                    local Ok, Seq = pcall(function() return M.SlotAnimTracks[1].AnimTrack.AnimSegments[1].AnimReference end)
                    if Ok and Valid(Seq) then
                        local SeqPath, Len = Seq:GetFullName():match("^%S+ (.+)$"), Seq:GetPlayLength()
                        local Pos = AI:Montage_GetPosition(M)
                        if SeqPath then return string.format("%s@%.3f", SeqPath, Len > 0 and Pos % Len or Pos) end
                    end
                elseif Path then
                    return string.format("%s@%.3f", Path, AI:Montage_GetPosition(M))
                end
            end
        end
    end
    return "-"
end

local function TeamMemberToken(Char)
    if not Valid(Char) then return "-" end
    local L, R, V = Char:K2_GetActorLocation(), Char:K2_GetActorRotation(), Char:GetVelocity()
    return string.format("%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%s,%s,%s", L.X, L.Y, L.Z, R.Yaw, V.X, V.Y, V.Z,
        AttachInfo(Char.EquippedWeapon), AttachInfo(Char.EquippedShield), MontageInfo(Char))
end

local function WriteState(Seq)
    local Hero = LocalHero()
    local Line
    if Hero then
        local L, R, V = Hero:K2_GetActorLocation(), Hero:K2_GetActorRotation(), Hero:GetVelocity()
        local Parts = { string.format("%d %.2f %.2f %.2f %.2f %.2f %.2f %.2f W=%s S=%s M=%s L=%s", Seq,
            L.X, L.Y, L.Z, R.Yaw, V.X, V.Y, V.Z, AttachInfo(Hero.EquippedWeapon), AttachInfo(Hero.EquippedShield),
            MontageInfo(Hero), MapName()) }
        -- companions (a guest's are switched off - the story party is the host's - so none are sent; nor the host's
        -- when it has switched its own off too)
        local Solo = Party and (Coop.IsHost and Party.HostSolo or (not Coop.IsHost and Party.GuestSolo))
        if not Solo then
            for _, K in ipairs(Kinds) do
                if K.Token then
                    local C = K.Source(Hero)
                    if Valid(C) then Parts[#Parts + 1] = K.Token .. "=" .. TeamMemberToken(C) end
                end
            end
        end
        -- the guest reports the damage it has dealt to the host's enemies (running totals)
        if not Coop.IsHost and Enemies then Parts[#Parts + 1] = "D=" .. Enemies.DamageToken() end
        -- the host reports its enemies (refreshed every other update, ~15 times a second)
        if Coop.IsHost and Enemies then
            if Seq % 2 == 0 or not Coop.EnemyToken then
                -- also cover enemies around the guest (only meaningful while it's on the same map)
                local G = Coop.Target
                local GuestPos = (G and G.Map == MapName()) and G or nil
                Coop.EnemyToken = Enemies.HostToken(Hero, MontageInfo, GuestPos, World())
            end
            Parts[#Parts + 1] = "E=" .. Coop.EnemyToken
        end
        -- loot: the host's drops (refreshed a few times a second) / the drops the guest picked up
        if Loot then
            if Coop.IsHost then
                if Seq % 8 == 0 or not Coop.LootToken then
                    local G = Coop.Target
                    Coop.LootToken = Loot.HostToken(Hero, (G and G.Map == MapName()) and G or nil)
                end
                Parts[#Parts + 1] = "I=" .. Coop.LootToken
            else
                Parts[#Parts + 1] = "K=" .. Loot.GuestToken()
            end
        end
        -- HP and name for the other player's gauge (the name percent-encoded: it may contain spaces)
        local DS = Hero.DefensiveAttributeSet
        if DS then Parts[#Parts + 1] = string.format("H=%.0f,%.0f", DS.Health.CurrentValue, DS.MaxHealth.CurrentValue) end
        if not Coop.MyName then
            local Ok, Name = pcall(function() return PlayerController().PlayerState:GetPlayerName():ToString() end)
            Coop.MyName = (Ok and Name ~= "") and Name:gsub("[^%w_%-]", function(C) return string.format("%%%02X", C:byte()) end) or "-"
        end
        Parts[#Parts + 1] = "N=" .. Coop.MyName
        -- appearance, so the other copy's ghost wears this hero's own look. Several KB and tens of ms to build:
        -- rebuilt only when a cheap check sees new gear (or every 30 s), sent about once a second and right after
        -- a change (the other copy keeps the last one)
        if Seq % 15 == 0 or not Coop.LookToken or Coop.LookToken == "-" then
            local Sig, T = Ghost2.LookSignature(Hero), Now()
            if Sig ~= Coop.LookSig or not Coop.LookToken or Coop.LookToken == "-" or T - (Coop.LookBuiltAt or 0) > 30 then
                Coop.LookSig, Coop.LookToken, Coop.LookBuiltAt = Sig, Ghost2.LookToken(Hero), T
                Coop.LookSendUntil = Seq + 10
            end
        end
        if Seq % 20 == 0 or Seq <= (Coop.LookSendUntil or 0) then Parts[#Parts + 1] = "Q=" .. Coop.LookToken end
        -- downed state (and who it is being revived by) for the revive sync
        if Revive then Parts[#Parts + 1] = Revive.Token(Hero) end
        -- the guest's stand-in on the host: the guest sends the Area tags its hero is in, the host what the stand-in took
        if Proxy then
            if Coop.IsHost then Parts[#Parts + 1] = Proxy.Token() else Parts[#Parts + 1] = Proxy.GuestToken(Hero) end
        end
        -- the quest the host has set off on, for the guest to follow (quests.lua)
        if Quests and Coop.IsHost then Parts[#Parts + 1] = Quests.HostToken() end
        Line = table.concat(Parts, " ") .. "\n"
    else
        Line = string.format("%d none\n", Seq)
    end
    local F = io.open(OutPath(), "w")
    if F then F:write(Line) F:close() end
end

local function ParseMontage(S, M)
    if M and M ~= "-" then
        local Path, Pos = M:match("^(.-)@([%d%.]+)$")
        S.Montage, S.MontagePos = Path, tonumber(Pos)
    end
end

local function ParseTeamMember(Token)
    if not Token or Token == "-" then return nil end
    local X, Y, Z, Yaw, VX, VY, VZ, W, Sh, M = Token:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),([^,]+)$")
    if not X then return nil end
    local S = { X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z), Yaw = tonumber(Yaw), VX = tonumber(VX), VY = tonumber(VY),
                VZ = tonumber(VZ), Weapon = W, Shield = Sh }
    ParseMontage(S, M)
    return S
end

local function ReadPeer()
    local F = io.open(InPath(), "r")
    if not F then return nil end
    local Line = F:read("*l")
    F:close()
    if not Line then return nil end
    local Seq, X, Y, Z, Yaw, VX, VY, VZ = Line:match("^(%d+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+)")
    if not Seq then return { Seq = tonumber(Line:match("^(%d+)")), None = true } end
    local S = { Seq = tonumber(Seq), X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z), Yaw = tonumber(Yaw),
                VX = tonumber(VX), VY = tonumber(VY), VZ = tonumber(VZ) }
    S.Weapon, S.Shield, S.Map = Line:match(" W=(%S+)"), Line:match(" S=(%S+)"), Line:match(" L=(%S+)")
    ParseMontage(S, Line:match(" M=(%S+)"))
    for _, K in ipairs(Kinds) do
        if K.Token then S[K.Key] = ParseTeamMember(Line:match(" " .. K.Token .. "=(%S+)")) end
    end
    if Enemies then S.Enemies, S.Damage = Enemies.Parse(Line:match(" E=(%S+)")), Line:match(" D=(%S+)") end
    if Loot then S.Loot, S.Picks = Loot.Parse(Line:match(" I=(%S+)")), Line:match(" K=(%S+)") end
    local HP, MaxHP = Line:match(" H=([%d%.]+),([%d%.]+)")
    S.HP, S.MaxHP = tonumber(HP), tonumber(MaxHP)
    local Name = Line:match(" N=(%S+)")
    if Name and Name ~= "-" then S.Name = Name:gsub("%%(%x%x)", function(H) return string.char(tonumber(H, 16)) end) end
    if Revive then S.Revive = Revive.Parse(Line) end
    if Proxy then S.AreaTags, S.ProxyHit = Proxy.Parse(Line), Proxy.ParseHit(Line) end
    if Quests then S.Quest = Quests.Parse(Line) end
    S.LookRaw = Line:match(" Q=(%S+)")
    S.Hero = S
    return S
end

---------------------------------------------------------------------------------------------------------------

local function HideAll()
    for _, G in pairs(Coop.Ghosts) do Ghost2.SetHidden(G, true) end
end

-- (testing aid: Coop.Off = { Enemies = true, ... } switches individual parts of the sync off)
local function On(Part) return not (Coop.Off and Coop.Off[Part]) end

local F8Key = { KeyName = FName("F8") }

local function Tick()
    Coop.Frame = Coop.Frame + 1
    if Coop.Frame % SendEveryFrames == 0 then
        Coop.Seq = Coop.Seq + 1
        WriteState(Coop.Seq)
    end
    -- F8: teleport next to the other player
    local PC = PlayerController()
    local F8 = PC:IsValid() and PC:IsInputKeyDown(F8Key)
    if F8 and not Coop.F8Down then Log("F8: " .. tostring(Coop.TeleportToPeer())) end
    Coop.F8Down = F8

    local T = Now()
    local S = Coop.FakePeer and Coop.FakePeer(T) or ReadPeer()
    if S and S.Seq ~= Coop.PeerSeq then
        Coop.PeerSeq, Coop.PeerChangedAt = S.Seq, T
        if not S.None then Coop.Target, Coop.TargetAt = S, T end
    end

    local Hero = LocalHero()
    local Map = MapName()
    if Map ~= Coop.LastMap then   -- new map: all enemies (and puppets) from the old one are gone
        Coop.LastMap = Map
        if Enemies then Enemies.Reset() end
        if Loot then Loot.Reset() end
        if Hud then Hud.Reset() end
        if Revive then Revive.Reset() end
        if Party then Party.Reset() end
        if Proxy then Proxy.Reset() end
        Coop.MyName = nil
    end
    local Tg = Coop.Target
    local Fresh = Coop.PeerChangedAt and (T - Coop.PeerChangedAt) < StaleSeconds and Tg and (T - Coop.TargetAt) < StaleSeconds
    local SameMap = Fresh and Hero and (Tg.Map == nil or Tg.Map == Map)

    -- guest: the host is gone (no updates for HostLostSeconds after we'd had a connection, out in a field) -> back
    -- to town. That's the title screen: the save always resumes in the Town of Beginnings.
    if not Coop.IsHost and Hero then
        if Fresh then Coop.HostSeenAt = T end
        local InField = Map ~= "PL_TOB" and Map ~= "PL_ROD"
        if InField and Coop.HostSeenAt and not Coop.KickAt and T - Coop.HostSeenAt > HostLostSeconds then
            Coop.KickAt = T + 4
            Coop.KickText = "Lost connection to the host - returning to town..."
            Log("coop: host lost for " .. HostLostSeconds .. " s - returning to town")
        end
        if Coop.KickAt and Fresh then   -- (came back in time: stay)
            Coop.KickAt, Coop.KickText = nil, nil
            Log("coop: host back")
        elseif Coop.KickAt and T >= Coop.KickAt then
            Coop.KickAt, Coop.HostSeenAt = nil, nil
            Coop.KickText = nil
            pcall(function() World().OwningGameInstance:RequestLeaveRoom(true, 0) end)
        end
    end

    -- the guest's stand-in on the host (what the host's enemies target and hit), and its hits reaching the guest
    if Proxy and Hero and On("Proxy") then
        local Ok, Err
        if Coop.IsHost then
            local InField = Map ~= "PL_TOB" and Map ~= "PL_ROD"
            Ok, Err = pcall(Proxy.HostUpdate, Hero, PlayerController(), SameMap and Tg or nil, T, InField)
        else
            Ok, Err = pcall(Proxy.GuestUpdate, Hero, PlayerController(), SameMap and Tg or nil, T)
        end
        if not Ok and Coop.ProxyErr ~= tostring(Err) then Coop.ProxyErr = tostring(Err); Log("proxy: " .. Coop.ProxyErr) end
    end

    -- the host applies damage the guest dealt to its enemies (their hate goes to the guest's stand-in)
    if Enemies and On("Enemies") and Coop.IsHost and Hero and SameMap and Tg.Damage then
        Enemies.ApplyGuestDamage(Tg.Damage, Hero, Proxy and Proxy.Attacker(nil))
    end

    -- the guest's enemies are puppets of the host's (their own AI stays off even while the host is away)
    if Enemies and On("Enemies") and not Coop.IsHost then
        pcall(Enemies.CleanList, World())   -- (also while there's no hero: game over, checkpoint restart)
        if Hero then
            Enemies.GuestUpdate(SameMap and Tg.Enemies or nil, SameMap and (T - Coop.TargetAt) or 0, T, World(), Ghost2.FindAsset, Hero)
        end
    end

    -- loot: the guest copies the host's drops; the host applies the guest's pickups
    if Loot and On("Loot") and Hero and SameMap then
        if Coop.IsHost then
            Loot.ApplyGuestPicks(Tg.Picks)
        elseif Coop.Frame % 4 == 0 then
            Loot.GuestUpdate(Tg.Loot, World(), Ghost2.FindAsset)
        end
    end

    if Party and On("Party") and Hero then pcall(Party.Update, Hero, PlayerController(), Coop.IsHost, T) end

    -- downed / revive (before the HUD, which shows the downed countdown)
    if Revive and On("Revive") and Hero then
        local Ok, Err = pcall(Revive.Update, Hero, PlayerController(), SameMap and Tg or nil, T)
        if not Ok and Coop.ReviveErr ~= tostring(Err) then Coop.ReviveErr = tostring(Err); Log("revive: " .. Coop.ReviveErr) end
        -- guest: a real death brings the game's checkpoint restart - the enemy sync lets go of its puppets first
        local Gone = Revive.State == "gone"
        if Gone and not Coop.WasGone and not Coop.IsHost and Enemies and On("Enemies") then pcall(Enemies.ForgetPuppets, World()) end
        Coop.WasGone = Gone
    end

    -- the other player's HP in the party gauges (top left) and their marker on the minimap
    if Hud and On("Hud") and Hero then Hud.Update(SameMap and Tg or nil, PlayerController(), Hero, Ghost2.FindAsset, Coop.Ghosts.Hero.Actor) end
    -- name plate over the other player (downed state / "[V] Revive" prompt) and the local "You are down" line
    if Hud and On("Hud") and Hero then
        local Peer = SameMap and Tg or nil
        local PeerName = (Tg and Tg.Name) or Hud.PeerName or "Player 2"
        local Ok, Err = pcall(Hud.UpdatePlates, PlayerController(), Ghost2.FindAsset, Peer and Coop.Ghosts.Hero.Actor or nil,
            Revive and Revive.PlateText(Peer, PeerName) or (Peer and PeerName), Peer and Peer.Revive and Peer.Revive.Down,
            Coop.KickText or (Revive and Revive.SelfText(PeerName, Peer)))
        if not Ok and Coop.PlateErr ~= tostring(Err) then Coop.PlateErr = tostring(Err); Log("hud: plates: " .. Coop.PlateErr) end
    end

    if not SameMap or not On("Ghosts") then
        HideAll()
        return
    end

    -- the other player's appearance (it comes every so often; the last one is kept)
    if Tg.LookRaw and Tg.LookRaw ~= Coop.PeerLookRaw then
        Coop.PeerLookRaw, Coop.PeerLook = Tg.LookRaw, Ghost2.ParseLook(Tg.LookRaw)
    end
    Ghost2.SetLook(Coop.Ghosts.Hero, Coop.PeerLook)

    local W, Age = World(), T - Coop.TargetAt
    for _, K in ipairs(Kinds) do
        local G, Sub = Coop.Ghosts[K.Key], Tg[K.Key]
        if Sub then
            Ghost2.Update(G, Sub, Age, K.Source(Hero), W)
            Ghost2.SetHidden(G, false)
        else
            Ghost2.SetHidden(G, true)
        end
    end
end

function Coop.Start(Me, Peer, Transport)
    Coop.Me, Coop.Peer = Me, Peer
    Coop.IsHost = (Me == "A")   -- the host owns the enemies; the guest mirrors them
    if Hud then Hud.PeerName = Coop.IsHost and "Player 2" or "Player 1 (Host)" end
    Coop.LastMap, Coop.EnemyToken = nil, nil
    Coop.Transport = Transport or Coop.Transport or "file"
    Coop.Frame, Coop.Seq, Coop.PeerSeq, Coop.Target = 0, 0, nil, nil
    Coop.StartCount = (Coop.StartCount or 0) + 1
    -- (lines left from an earlier session must not count as the other player now: the guest once followed the
    -- host to a quest it had been on before the host's game restarted)
    os.remove(InPath())
    os.remove(OutPath())
    Coop.Handles = {
        LoopInGameThreadAfterFrames(1, function()
            local Ok, Err = pcall(Tick)
            if not Ok and Coop.LastErr ~= tostring(Err) then
                Coop.LastErr = tostring(Err)
                Log("coop tick error: " .. Coop.LastErr)
            end
        end),
    }
    Log("coop: started as " .. Me .. ", peer " .. Peer .. " via " .. Coop.Transport)
end

function Coop.Stop()
    for _, H in ipairs(Coop.Handles or {}) do pcall(CancelDelayedAction, H) end
    Coop.Handles = {}
    for _, G in pairs(Coop.Ghosts or {}) do pcall(Ghost2.Destroy, G) end
    if Proxy then pcall(Proxy.Despawn, "co-op stopped") end
    Coop.Target = nil
    Log("coop: stopped")
end

function Coop.Status()
    local Hero = LocalHero()
    local L = Hero and Hero:K2_GetActorLocation()
    local Ghosts = {}
    for _, K in ipairs(Kinds) do
        local G = Coop.Ghosts[K.Key]
        Ghosts[#Ghosts + 1] = K.Key .. "=" .. (Valid(G.Actor) and (G.Hidden and "hidden" or tostring(G.Playing)) or "none")
    end
    return string.format("me=%s%s peer=%s via=%s hero=%s pos=%s map=%s peerSeq=%s ghosts: %s | %s",
        tostring(Coop.Me), Coop.IsHost and "(host)" or "(guest)", tostring(Coop.Peer), tostring(Coop.Transport),
        Hero and Hero:GetClass():GetFName():ToString() or "none", L and string.format("%.0f,%.0f,%.0f", L.X, L.Y, L.Z) or "-",
        MapName(), tostring(Coop.PeerSeq), table.concat(Ghosts, " "), (Enemies and Enemies.Status(World()) or "no enemy sync") .. (Loot and (" | " .. Loot.Status()) or ""))
end

-- Test without a moving peer: a fake peer that starts Ahead cm in front and to the left of the local hero, runs
-- across the view to the right at Speed for Seconds, then stands for 2 s before handing back to the real peer.
function Coop.FakeRun(Seconds, Speed, Ahead)
    local Hero = LocalHero()
    if not Hero then return "no local hero" end
    Ahead = Ahead or 400
    local L, R = Hero:K2_GetActorLocation(), Hero:K2_GetActorRotation()
    local Fwd, Right = math.rad(R.Yaw), math.rad(R.Yaw + 90)
    local Half = Speed * Seconds / 2
    local Start = { X = L.X + math.cos(Fwd) * Ahead - math.cos(Right) * Half, Y = L.Y + math.sin(Fwd) * Ahead - math.sin(Right) * Half, Z = L.Z }
    local VX, VY = math.cos(Right) * Speed, math.sin(Right) * Speed
    local Yaw = R.Yaw + 90
    local T0, Seq = Now(), 0
    Coop.FakePeer = function(T)
        local E = T - T0
        if E > Seconds + 2 then Coop.FakePeer = nil return nil end
        local Run = math.min(E, Seconds)
        local Moving = E < Seconds
        Seq = Seq + 1
        local S = { Seq = Seq, X = Start.X + VX * Run, Y = Start.Y + VY * Run, Z = Start.Z, Yaw = Yaw,
                    VX = Moving and VX or 0, VY = Moving and VY or 0, VZ = 0, Map = MapName() }
        S.Hero = S
        return S
    end
    return string.format("fake peer running %.0f s at %.0f", Seconds, Speed)
end

-- Teleport the local hero 2 m in front of the other copy's hero, facing it. Bound to F8.
function Coop.TeleportToPeer()
    local Hero, Tg = LocalHero(), Coop.Target
    if not Hero then return "no local hero" end
    if not (Tg and Coop.TargetAt and (Now() - Coop.TargetAt) < StaleSeconds) then return "no fresh peer position" end
    if Tg.Map and Tg.Map ~= MapName() then return "other player is on a different map (" .. Tg.Map .. ")" end
    local Yaw = math.rad(Tg.Yaw)
    local Spot = { X = Tg.X + math.cos(Yaw) * 200, Y = Tg.Y + math.sin(Yaw) * 200, Z = Tg.Z }
    local Ok = Hero:K2_TeleportTo(Spot, { Pitch = 0, Yaw = Tg.Yaw + 180, Roll = 0 })
    return string.format("teleport to %.0f,%.0f,%.0f -> %s", Spot.X, Spot.Y, Spot.Z, tostring(Ok))
end

-- F8 is read in Tick (the game thread) - not RegisterKeyBind, whose callbacks run on UE4SS's own thread: Lua run
-- there alongside the game thread's crashes the game.

Log("coop.lua loaded")
