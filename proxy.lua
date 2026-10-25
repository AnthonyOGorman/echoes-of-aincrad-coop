-- The other player's stand-in on the host: what the host's enemies target and hit when they go after the guest.
-- Enemies only pick and hit avatars of the players in GameState.RODPlayerArray (hero, partner, visitor,
-- battlers), so the guest gets one: a "battle character" - the game's own extra-ally feature
-- (PlayerState:ServerSpawnBattleCharacter: partner data, abilities, AI controller, in the avatar list). It is kept
-- invisible on the guest's position with its AI off (the ghost is what the host sees). Battlers are made
-- battle-invincible by the game, and enemies only hit characters in their own area, so the stand-in has that
-- invincibility switched off and carries the guest hero's Area.* tags. None while the guest is in a safe zone
-- (Area.Safety: not hit there anyway).
-- Its HP is held high so it never dies; what the host's enemies take off it is sent to the guest, who takes the
-- same share of its own HP and plays the same hit reaction. The guest's hits on the host's enemies give the
-- stand-in their hate, so enemies turn on the guest like on anyone who hits them. Removed while the guest is down.
-- Loaded by coop.lua; shares its environment.
--
-- Wire format:
--   guest -> host "A=<Area tags of the guest's hero, +-joined, or ->"
--   host -> guest "G=<gen>,<damage total>,<hit seq>,<reaction>" - damage in units of the stand-in's max HP (the guest
--   scales it by its own max HP: both grow with level), a running total per stand-in generation, so lost or
--   repeated updates are harmless. Reaction = "<tags +-joined>/<dx>/<dy>/<magnitude>/<action direction>/<blow
--   pattern>/<attacking enemy's key or ->" of the stand-in's last hit.

Proxy = Proxy or {}
Proxy.ID = Proxy.ID or "ASN"      -- partner whose data the stand-in uses (any of DT_PartnerList's rows)
Proxy.Gen = Proxy.Gen or 0
local HoldHP = 100000             -- the stand-in's HP is held here so no single hit can kill it

local function Valid(O) return O ~= nil and O:IsValid() end
local function Addr(O) return Valid(O) and O:GetAddress() or nil end

function Proxy.Is(C)
    return Proxy.Addr ~= nil and Addr(C) == Proxy.Addr
end

-- the stand-in if there is one, else Fallback (who gets the hate of the guest's hits)
function Proxy.Attacker(Fallback)
    return Valid(Proxy.Actor) and Proxy.Actor or Fallback
end

local function AreaTags(C)
    local T = {}
    local G = C:GetAreaTags().GameplayTags
    for i = 1, #G do
        local Tag = G[i]
        if type(Tag) == "userdata" and Tag.get and not Tag.TagName then Tag = Tag:get() end
        T[#T + 1] = Tag.TagName:ToString()
    end
    table.sort(T)
    return T
end

---------------------------------------------------------------------------------------------------------------
-- Host

-- The stand-in's hits: the game broadcasts each one (tags, direction, magnitude, pattern, who hit it). The hook
-- calls Proxy.OnHit, looked up per call, so a reload replaces it (the hook itself can't be unregistered).
function Proxy.OnHit(Ctx, P)
    if not Proxy.Addr or not (Enemies and not Enemies.NativeAttacks) then return end
    if Ctx:get():GetAddress() ~= Proxy.Addr then return end
    local A = P:get()
    local Tags = {}
    local Arr = A.GameplayTags.GameplayTags
    for i = 1, #Arr do Tags[#Tags + 1] = Arr[i].TagName:ToString() end
    -- the attacking enemy, as the key the enemy sync knows it by (the guest has a puppet of it). Follow-up events
    -- (e.g. Blown.Standing) have no attacker: a null object, which must not be touched (pcall doesn't catch a
    -- native access violation - that crashed the host)
    local Key = "-"
    local E = A.InstigatorCharacter:Get()
    if E and E:IsValid() then
        local Name = E:GetFName():ToString()
        local G = Enemies.Gen[Name]
        if G and G.Gen then Key = (Name:match("_(%d+)$") or Name) .. "g" .. G.Gen end
    end
    Proxy.HitSeq = (Proxy.HitSeq or 0) + 1
    Proxy.Hit = string.format("%s/%.2f/%.2f/%.1f/%d/%d/%s", #Tags > 0 and table.concat(Tags, "+") or "-",
        A.Direction.X, A.Direction.Y, A.Magnitude, A.ActionDirection, A.BlowPattern, Key)
end

if not Proxy.Hooked then
    Proxy.Hooked = pcall(RegisterHook, "/Script/ROD.RODAvatarCharacter:MulticastNotifyDamageAction", function(Ctx, P)
        if not Proxy.Addr then return end
        local Ok, Err = pcall(Proxy.OnHit, Ctx, P)
        if not Ok then Log("proxy: hit hook: " .. tostring(Err)) end
    end)
end

function Proxy.Parse(Line)
    local S = Line:match(" A=(%S+)")
    if not S then return nil end
    local T = {}
    if S ~= "-" then for X in S:gmatch("[^+]+") do T[#T + 1] = X end end
    return T
end

local function HideVisuals(P)
    pcall(function() if P.Mesh:IsVisible() then P.Mesh:SetVisibility(false, true) end end)
    for _, A in ipairs({ P.EquippedWeapon, P.EquippedShield }) do
        if Valid(A) and not A.bHidden then pcall(function() A:SetActorHiddenInGame(true); A:SetActorEnableCollision(false) end) end
    end
end

local function StopAI(P)
    local AIC = P.Controller
    local Brain = Valid(AIC) and AIC.BrainComponent or nil
    if Valid(Brain) and Brain:IsRunning() then pcall(function() P:StopAI() end) end
end

-- With Enemies.NativeAttacks the guest's puppets make the attacks on the guest themselves: the stand-in is only a
-- target then (it's still hittable, with its HP held, but its hits aren't sent).
local function HostDamage() return not (Enemies and Enemies.NativeAttacks) end

-- battle invincibility off (the game's own switch; the concentration tick that would lift it never runs for battlers)
local function MakeHittable(P)
    for _ = 1, 4 do
        if not P:K2_IsInvincible() then return end
        P:SetBattleInvincible(false)
    end
end

local function Place(P, Peer)
    P:K2_SetActorLocationAndRotation({ X = Peer.X, Y = Peer.Y, Z = Peer.Z }, { Pitch = 0, Yaw = Peer.Yaw or 0, Roll = 0 }, false, {}, true)
end

-- the stand-in's Area tags = the guest hero's (only changed when they differ)
local function SyncArea(P, Want)
    local Key = table.concat(Want, "+")
    if Proxy.AreaKey == Key then return end
    local Have = {}
    for _, T in ipairs(AreaTags(P)) do Have[T] = true end
    local WantSet = {}
    for _, T in ipairs(Want) do WantSet[T] = true end
    for T in pairs(Have) do if not WantSet[T] then P:ExitAreaWithTag({ TagName = FName(T) }) end end
    for T in pairs(WantSet) do if not Have[T] then P:EnterAreaWithTag({ TagName = FName(T) }) end end
    Proxy.AreaKey = Key
end

local function Spawn(Hero, PC, Peer)
    local PS = PC.PlayerState
    local Before = #Hero.BattlerCharacter
    PS:ServerSpawnBattleCharacter({ FName(Proxy.ID) })
    local B = Hero.BattlerCharacter
    if #B <= Before then Log("proxy: the game spawned no battle character") return end
    local P = B[#B]
    if type(P) == "userdata" and not P.IsValid and P.get then P = P:get() end
    if not Valid(P) then return end
    Proxy.Actor, Proxy.Addr, Proxy.AreaKey = P, P:GetAddress(), nil
    Proxy.Gen, Proxy.Taken, Proxy.HitSeq, Proxy.Hit = Proxy.Gen + 1, 0, 0, nil
    Proxy.NaturalMax, Proxy.Held = nil, nil   -- (its stats arrive a moment later)
    Place(P, Peer)
    HideVisuals(P)
    pcall(function() P:MulticastPartnerGameStart() end)   -- (what the quest start does for the party: abilities, shown)
    StopAI(P)
    pcall(MakeHittable, P)
    Log(string.format("proxy: stand-in for the other player spawned (%s, %s)", P:GetFName():ToString(), Proxy.ID))
end

function Proxy.Despawn(Why)
    if Valid(Proxy.Actor) then
        pcall(function() Coop.LocalPC().PlayerState:ServerDestroyBattleCharacter() end)
        Log("proxy: stand-in removed (" .. (Why or "-") .. ")")
    end
    Proxy.Actor, Proxy.Addr, Proxy.AreaKey, Proxy.Held = nil, nil, nil, nil
end

-- Hold the HP high, and count what was taken since the last tick (in units of the stand-in's own max HP).
local function TrackHP(P)
    local D = P.DefensiveAttributeSet
    local Max, HP = D.MaxHealth.CurrentValue, D.Health.CurrentValue
    if not Proxy.NaturalMax then
        if Max <= 1 or Max == HoldHP then return end
        Proxy.NaturalMax = Max
    end
    if Proxy.Held and Max == HoldHP and HP < Proxy.Held then
        local Lost = math.min(Proxy.Held - HP, Proxy.NaturalMax * 3)   -- (sanity cap)
        Proxy.Taken = Proxy.Taken + Lost / Proxy.NaturalMax
    end
    if Max ~= HoldHP then D.MaxHealth.CurrentValue, D.MaxHealth.BaseValue = HoldHP, HoldHP end
    if HP ~= HoldHP then D.Health.CurrentValue, D.Health.BaseValue = HoldHP, HoldHP end
    Proxy.Held = HoldHP
end

-- whether the guest's hero is in a safe zone (its Area tags)
local function InSafeZone(Peer)
    for _, Tag in ipairs(Peer.AreaTags or {}) do
        if Tag:find("Safety", 1, true) then return true end
    end
    return false
end

-- Per tick on the host. Peer = the guest's state when it's on this map and fresh (nil otherwise).
-- No stand-in while the guest is in a safe zone (enemies don't fight there), nor in its first seconds on this map:
-- a battle character spawned into a quest start terminal's safe area as the guest arrived there was followed by
-- the host freezing (and the arriving guest crashing, the time before).
function Proxy.HostUpdate(Hero, PC, Peer, T, InField)
    local PR = Peer and Peer.Revive
    local Out = PR and (PR.Down or PR.Dead or PR.Gone)
    if Peer then
        Proxy.PeerSeenAt, Proxy.PeerSince = T, Proxy.PeerSince or T
    elseif T - (Proxy.PeerSeenAt or 0) > 5 then
        Proxy.PeerSince = nil
    end
    local Safe = Peer and InSafeZone(Peer)
    if not InField or Out or not Peer or Safe then
        -- (a guest missing for a moment - a hitch, a reload - keeps its stand-in; it stays where it was)
        local Gone = not Peer and T - (Proxy.PeerSeenAt or 0) > 5
        if Valid(Proxy.Actor) and (not InField or Out or Gone or Safe) then
            Proxy.Despawn(Out and "the other player is down" or Safe and "the other player is in a safe zone" or "the other player left")
        end
        return
    end
    if not Valid(Proxy.Actor) and T - Proxy.PeerSince < 5 then return end   -- (settling in after arriving)
    if not Valid(Proxy.Actor) then
        Proxy.Actor, Proxy.Addr = nil, nil
        if (Proxy.RetryAt or 0) > T then return end
        Proxy.RetryAt = T + 5
        local Ok, Err = pcall(Spawn, Hero, PC, Peer)
        if not Ok then Log("proxy: spawn failed: " .. tostring(Err)) end
        return
    end
    local P = Proxy.Actor
    Place(P, Peer)
    pcall(TrackHP, P)   -- (HP held either way, so it never dies)
    if Peer.AreaTags then
        local Ok, Err = pcall(SyncArea, P, Peer.AreaTags)
        if not Ok and Proxy.AreaErr ~= tostring(Err) then Proxy.AreaErr = tostring(Err); Log("proxy: area tags: " .. Proxy.AreaErr) end
    end
    if P:IsDead() then pcall(function() P:Revive(P) end) end
    if (Proxy.CheckAt or 0) <= T then
        Proxy.CheckAt = T + 1
        HideVisuals(P)
        StopAI(P)
        pcall(MakeHittable, P)
    end
end

function Proxy.Token()
    if not Valid(Proxy.Actor) or not HostDamage() then return nil end
    return string.format("G=%d,%.4f,%d,%s", Proxy.Gen, Proxy.Taken or 0, Proxy.HitSeq or 0, Proxy.Hit or "-")
end

---------------------------------------------------------------------------------------------------------------
-- Guest

function Proxy.GuestToken(Hero)
    local Ok, T = pcall(AreaTags, Hero)
    return "A=" .. ((Ok and #T > 0) and table.concat(T, "+") or "-")
end

function Proxy.ParseHit(Line)
    local Gen, Total, Seq, Hit = Line:match(" G=(%d+),([%d%.]+),(%d+),(%S+)")
    if not Gen then return nil end
    local R
    local Tags, DX, DY, Mag, AD, BP, Key = Hit:match("^([^/]+)/([^/]+)/([^/]+)/([^/]+)/([^/]+)/([^/]+)/([^/]+)$")
    if Tags and Tags ~= "-" then
        R = { Tags = Tags, DX = tonumber(DX), DY = tonumber(DY), Mag = tonumber(Mag), ActionDir = tonumber(AD), Blow = tonumber(BP),
              Key = Key ~= "-" and Key or nil }
    end
    return { Gen = tonumber(Gen), Total = tonumber(Total), Seq = tonumber(Seq), Hit = R }
end

-- The hit reaction on the guest's hero, through the hero's own entry point (what its damage handling calls):
-- it activates the damage abilities matching the tags and hands them the parameters. The guest's puppet of the
-- attacking enemy is the instigator (the reaction's direction comes from it).
function Proxy.PlayHit(Hero, R)
    local Tags = {}
    for X in R.Tags:gmatch("[^+]+") do Tags[#Tags + 1] = { TagName = FName(X) } end
    local Instigator = Hero
    pcall(function()
        local P = R.Key and Enemies.Puppets[R.Key]
        if P and Valid(P.Actor) then Instigator = P.Actor end
    end)
    Hero:TryActivateDamageAbility({
        GameplayTags = { GameplayTags = Tags }, OptionalTags = { GameplayTags = {} },
        InstigatorCharacter = Instigator, DamageCauser = Instigator, TargetLoc = Hero:K2_GetActorLocation(),
        Direction = { X = R.DX or 1, Y = R.DY or 0, Z = 0 }, Magnitude = R.Mag or 0,
        ActionDirection = R.ActionDir or 0, BlowPattern = R.Blow or 0, Index = 0,
    })
end

-- Per tick on the guest. Peer = the host's state when it's on this map and fresh (nil otherwise).
function Proxy.GuestUpdate(Hero, PC, Peer, T)
    local G = Peer and Peer.ProxyHit
    if not G then return end
    if G.Gen ~= Proxy.SeenGen then   -- a new stand-in: start counting from what it reports now
        Proxy.SeenGen, Proxy.Applied, Proxy.SeenSeq = G.Gen, G.Total, G.Seq
        return
    end
    local Delta = G.Total - (Proxy.Applied or G.Total)
    Proxy.Applied = G.Total
    if Delta > 0 and Revive then
        local Max = Hero.DefensiveAttributeSet.MaxHealth.CurrentValue
        Revive.TakeDamage(Hero, PC, Delta * Max, T)
    end
    if G.Seq ~= Proxy.SeenSeq then
        Proxy.SeenSeq = G.Seq
        if G.Hit and Revive and Revive.State == "up" then
            local Ok, Err = pcall(Proxy.PlayHit, Hero, G.Hit)
            if not Ok then Log("proxy: hit reaction: " .. tostring(Err)) end
        end
    end
end

function Proxy.Reset()
    -- (a new map: the stand-in went with the old one; the guest waits for the next one's numbers)
    Proxy.Actor, Proxy.Addr, Proxy.AreaKey, Proxy.Held, Proxy.RetryAt = nil, nil, nil, nil, nil
    Proxy.SeenGen, Proxy.PeerSince = nil, nil
end

Log("proxy.lua loaded")
