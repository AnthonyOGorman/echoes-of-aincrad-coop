-- Enemy sync (host authority). The host copy runs its enemies normally and reports the active ones near either
-- player; the guest copy suppresses its own game's enemies and instead spawns a puppet of the same class and
-- level for every enemy the host reports, steering it and copying its animation state and montages. Enemies that
-- died or never spawned in one copy therefore can't get out of step. When the host's enemy attacks the guest
-- (its target is the guest's stand-in, proxy.lua), the puppet makes that attack for real against the guest's
-- hero. Loaded by coop.lua; shares its environment.
--
-- Both sides read the game's own list (GameState.RODEnemies). Enemies are pooled: a "dead" enemy stays a
-- valid object, hidden or in a dead state, and is later reused under the same name, so the host tags each
-- reuse with a generation number.

Enemies = Enemies or {}

local ReportRadius = 8000      -- host reports enemies within 80 m of either player
local MaxReported = 24
local SnapDistance = 800       -- teleport a puppet that is more than 8 m off
local ArriveDistance = 60
local PuppetTimeout = 1.0      -- remove a puppet the host stopped reporting (out of range)
local CorpseTime = 8.0         -- leave a dead puppet this long for its death animation
local DeadStates = 19          -- EnemyStateValue >= 19: dying / dead / pooled

local function Valid(O) return O ~= nil and O:IsValid() end

local function GameStateOf(World)
    local GS = Valid(World) and World.GameState or nil
    return Valid(GS) and GS or nil
end

local function EnemyList(GS)
    local Out, Arr = {}, GS.RODEnemies
    for i = 1, #Arr do
        local E = Arr[i]
        if type(E) == "userdata" and not E.IsValid and E.get then E = E:get() end
        if Valid(E) then Out[#Out + 1] = E end
    end
    return Out
end

local function Active(E) return not E.bHidden and E.EnemyStateValue < DeadStates end

local function Health(E)
    local Set = E.DefensiveAttributeSet
    return Set.Health.CurrentValue, Set.MaxHealth.CurrentValue
end

-- Set HP directly and tell the enemy (HP bar). Death is handled by the caller.
local function SetHealth(E, HP, Max)
    local Set = E.DefensiveAttributeSet
    if Max then Set.MaxHealth.CurrentValue = Max; Set.MaxHealth.BaseValue = Max end
    Set.Health.CurrentValue = HP
    Set.Health.BaseValue = HP
    E:OnHealthChanged(HP, Set.MaxHealth.CurrentValue)
end

---------------------------------------------------------------------------------------------------------------
-- Host: "E=<key>,<class path>,<x>,<y>,<z>,<yaw>,<vx>,<vy>,<montage>,<action>,<state>,<motion variation>,<hp>,
-- <max hp>,<reaction>,<level>,<attack>;..."
--
-- <attack> is the attack an enemy is making on the guest (its target is the guest's stand-in, proxy.lua), "-"
-- otherwise: "<seq>/<action>/<category>/<variation>/<combo index>/<counter>/<trigger>/<montage section>/<area
-- attack index>/<ability classes, +-joined>". Its sequence number changes per attack, so the guest's puppet of
-- that enemy performs each one once - for real, against the guest's own hero (hit, dodge, guard, damage and
-- reaction all done by the guest's game, the way a client takes damage).

Enemies.Gen = Enemies.Gen or {}       -- host: object name -> { Gen, WasActive, Class }
Enemies.HostByKey = Enemies.HostByKey or {}   -- host: reported key -> enemy actor
Enemies.Applied = Enemies.Applied or {}       -- host: key -> guest damage total already applied

local function Near(L, P)
    return P and (L.X - P.X) ^ 2 + (L.Y - P.Y) ^ 2 < ReportRadius * ReportRadius
end

-- EEnemyAction values that are attacks (Trigger_Attack .. Attack_StepTurnRight, not Attack_ReturnToHomePosition)
local function IsAttackAction(A) return A >= 98 and A <= 160 and A ~= 150 end

-- the enemy abilities that carry out attacks (GA_EnemyMeleeBase_C, GA_EnemyLeapAttack_C, GA_EnemyThrow_Explode_C, ...)
local function IsAttackAbility(Name) return Name:find("Melee") or Name:find("Attack") or Name:find("Throw") or Name:find("Leap") end

local function ActiveAttackAbilities(E)
    local Names = {}
    local Items = E.AbilitySystem.ActivatableAbilities.Items
    for i = 1, #Items do
        local S = Items[i]
        if S.ActiveCount > 0 and Valid(S.Ability) then
            local Name = S.Ability:GetClass():GetFName():ToString()
            if IsAttackAbility(Name) then Names[#Names + 1] = Name end
        end
    end
    return table.concat(Names, "+")
end

Enemies.AttackSeq = Enemies.AttackSeq or 0
-- The one switch between the two ways the guest takes damage (both copies load the same file):
--   true:  the guest's puppets make the host's attacks on the guest themselves, against the guest's hero (the
--          stand-in on the host stays invincible - just a target)
--   false: the host's enemies hit the stand-in and the guest takes the same share of its own HP (proxy.lua)
Enemies.NativeAttacks = true

local function AttackToken(E, G)
    local Target = E.TargetHeroCharacter
    if not Enemies.NativeAttacks or not (Proxy and Valid(Target) and Proxy.Is(Target)) or not IsAttackAction(E.EnemyActionValue) then
        G.AtkSig = nil
        return "-"
    end
    local AN = E.AttackingNumbers
    local Body = string.format("%d/%d/%d/%d/%d/%d/%s/%d", E.EnemyActionValue, AN.AtkCategory, AN.Variation, AN.ComboAttackIndex,
        AN.IsCounterAttack and 1 or 0, AN.IsTriggerAttack and 1 or 0, AN.MontageSectionName:ToString(), AN.AreaAttackNumberIndex)
    if Body ~= G.AtkSig then   -- a new attack (or the next hit of a combo)
        G.AtkSig = Body
        Enemies.AttackSeq = Enemies.AttackSeq + 1
        G.AtkSeq = Enemies.AttackSeq
    end
    -- (the ability may start a frame or two after the action; it's sent but isn't part of what makes an attack new)
    return G.AtkSeq .. "/" .. Body .. "/" .. ActiveAttackAbilities(E)
end

function Enemies.HostToken(Hero, MontageInfo, GuestPos, World)
    local GS = GameStateOf(World)
    if not GS then return "-" end
    local HL = Hero:K2_GetActorLocation()
    local Rows, Listed = {}, {}
    for _, E in ipairs(EnemyList(GS)) do
        local Name = E:GetFName():ToString()
        Listed[Name] = true
        local G = Enemies.Gen[Name]
        if not G then G = {}; Enemies.Gen[Name] = G end
        local IsActive = Active(E)
        if IsActive and not G.WasActive then   -- first seen or reused from the pool: a new enemy
            -- numbered from a counter that survives Reset/reloads, so a key is never reused and a stale damage
            -- total from the guest can't land on a different enemy
            Enemies.KeySeq = (Enemies.KeySeq or (os.time() % 100000) * 100) + 1   -- seeded so a restart doesn't repeat keys
            G.Gen = Enemies.KeySeq
            G.Class = E:GetClass():GetFullName():match("^%S+ (.+)$")
        end
        G.WasActive = IsActive
        -- dying enemies stay visible until their death animation ends; keep reporting them (with their dead
        -- state) so the guest's puppet dies too instead of vanishing
        if not E.bHidden and G.Class then
            local L = E:K2_GetActorLocation()
            if Near(L, HL) or Near(L, GuestPos) then
                Rows[#Rows + 1] = { E = E, L = L, G = G, Name = Name, Key = (Name:match("_(%d+)$") or Name) .. "g" .. G.Gen,
                                    D2 = (L.X - HL.X) ^ 2 + (L.Y - HL.Y) ^ 2 }
            end
        end
    end
    -- a dead enemy drops out of the game's list until the pool reuses it; when it comes back it's a new enemy
    for Name, G in pairs(Enemies.Gen) do
        if not Listed[Name] then G.WasActive = false end
    end
    table.sort(Rows, function(A, B) return A.D2 < B.D2 end)
    local Tokens = {}
    Enemies.HostByKey = {}
    for i = 1, math.min(#Rows, MaxReported) do
        local Row = Rows[i]
        local E, L = Row.E, Row.L
        local V, Rot = E:GetVelocity(), E:K2_GetActorRotation()
        local HP, Max = Health(E)
        Enemies.HostByKey[Row.Key] = E
        local Ok, Attack = pcall(AttackToken, E, Row.G)
        Tokens[#Tokens + 1] = string.format("%s,%s,%.1f,%.1f,%.1f,%.1f,%.1f,%.1f,%s,%d,%d,%d,%.0f,%.0f,%s,%d,%s", Row.Key, Row.G.Class,
            L.X, L.Y, L.Z, Rot.Yaw, V.X, V.Y, MontageInfo(E), E.EnemyActionValue, E.EnemyStateValue,
            E.AnimStatusFlags.MotionVariation, HP, Max, Enemies.HostReactions[Row.Name] or "-", E.EnemyLevel,
            Ok and Attack or "-")
    end
    return #Tokens > 0 and table.concat(Tokens, ";") or "-"
end

---------------------------------------------------------------------------------------------------------------
-- Hit reactions. When an enemy is hit, the game's damage code activates the enemy's reaction ability for the
-- hit (GA_EnemyBlownDeath_C for "Action.Ability.Damage.Death.Blow", GA_EnemyDeath_C, GA_EnemyKnockBack_C, ...)
-- and then calls MulticastNotifyDamageAction(FEnemyDamageActionParam); the ability is waiting for that broadcast
-- (its OnDamageAction) and only then plays: e.g. for a blown death it launches the enemy (OnBeginBlowing,
-- Damage_Blow), SetDeadFlag switches it to Die_Right and it becomes Dead when it lands. Either half alone does
-- nothing (KillingBlow / SetDeadFlag without it jump straight to Dead - no death animation).
-- A reaction travels as "seq/tag/dx/dy/dz/magnitude/knockback/knockup/strikedir/blowpattern/dismember/swordskill/breakdown".

Enemies.ReactionSeq = Enemies.ReactionSeq or 0

local function EncodeReaction(A)
    Enemies.ReactionSeq = Enemies.ReactionSeq + 1
    return string.format("%d/%s/%.2f/%.2f/%.2f/%.1f/%d/%.1f/%d/%d/%.1f/%d/%d", Enemies.ReactionSeq,
        A.ActivateTag.TagName:ToString(), A.Direction.X, A.Direction.Y, A.Direction.Z, A.Magnitude, A.KnockBackLevel,
        A.KnockUpParam, A.StrikeDirection, A.BlowPattern, A.DismembermentStrength, A.IsSwordSkills and 1 or 0,
        A.WithBreakDown and 1 or 0)
end

local function DecodeReaction(S)
    if not S or S == "-" then return nil end
    local F = {}
    for X in S:gmatch("[^/]+") do F[#F + 1] = X end
    if #F < 13 then return nil end
    return { Seq = tonumber(F[1]), Tag = F[2], DX = tonumber(F[3]), DY = tonumber(F[4]), DZ = tonumber(F[5]),
             Mag = tonumber(F[6]), KB = tonumber(F[7]), KU = tonumber(F[8]), SD = tonumber(F[9]), BP = tonumber(F[10]),
             DM = tonumber(F[11]), SS = F[12] == "1", BD = F[13] == "1" }
end

local function AbilityClassFor(E, Tag)
    local ASC = E.AbilitySystem
    if not Valid(ASC) then return nil end
    local Items = ASC.ActivatableAbilities.Items
    for i = 1, #Items do
        local A = Items[i].Ability
        if Valid(A) then
            local T = A.AbilityTags.GameplayTags
            for j = 1, #T do
                if T[j].TagName:ToString() == Tag then return A:GetClass() end
            end
        end
    end
end

-- Play reaction R (decoded; nil = a plain death from Hero's direction) on enemy E, as hit by Hero. Lethal = also
-- make sure it dies: the reaction must then be a death one, falling back to the plain death ability.
function Enemies.PlayReaction(E, Hero, R, Lethal)
    local Tag = R and R.Tag or "Action.Ability.Damage.Death"
    local BP = R and R.BP or 0
    if Lethal and not Tag:find("^Action%.Ability%.Damage%.Death") then Tag, BP = "Action.Ability.Damage.Death", 0 end
    local DX, DY, DZ = R and R.DX, R and R.DY, R and R.DZ or 0
    if not (DX and DY) and Valid(Hero) then
        local HL, L = Hero:K2_GetActorLocation(), E:K2_GetActorLocation()
        local N = math.max(1, math.sqrt((L.X - HL.X) ^ 2 + (L.Y - HL.Y) ^ 2))
        DX, DY = (L.X - HL.X) / N, (L.Y - HL.Y) / N
    end
    Enemies.Replaying = true   -- (our own broadcast below mustn't be recorded as a new hit)
    local Ok, Err = pcall(function()
        local Cls = AbilityClassFor(E, Tag)
        if not Cls and Lethal then Tag, BP = "Action.Ability.Damage.Death", 0; Cls = AbilityClassFor(E, Tag) end
        if Cls then
            E.AbilitySystem:TryActivateAbilityWithPayloadFromClass(Cls, { TagName = FName(Tag) },
                { EventTag = { TagName = FName(Tag) }, Instigator = Hero, Target = E, EventMagnitude = R and R.Mag or 0 })
        end
        E:MulticastNotifyDamageAction({
            ActivateTag = { TagName = FName(Tag) }, Direction = { X = DX or 1, Y = DY or 0, Z = DZ or 0 },
            Magnitude = R and R.Mag or 0, KnockBackLevel = R and R.KB or 0, KnockUpParam = R and R.KU or 0,
            InstigatorCharacter = Hero, StrikeDirection = R and R.SD or 2, BlowPattern = BP,
            DismembermentStrength = R and R.DM or 0, IsSwordSkills = R and R.SS or false, WithBreakDown = R and R.BD or false,
            AirBlowDismembermentChance = false, IsBadStatusDamage = false,
        })
    end)
    Enemies.Replaying = false
    if not Ok then Log("enemies: reaction failed: " .. tostring(Err)) end
    -- a lethal hit whose death ability didn't take (none found / blocked): die without the animation rather than
    -- stand around at 0 HP
    if Lethal and Valid(E) and E.EnemyStateValue < DeadStates then E:KillingBlow(Hero, { TagName = FName("None") }) end
end

-- Host: apply the guest's damage. Token items (";"-separated): "<key>,<damage total>,<reaction or ->,<K or ->",
-- K = the enemy died on the guest's screen (older guests send "<key>,<damage total>[,<reaction>]").
-- Damage is a running total and the reaction carries a sequence number, so lost or repeated updates are harmless.
-- A kill on the guest's side is final: the enemy dies here too even if its HP here hasn't reached 0 (it can be
-- higher than the guest's copy - regeneration, a reset when it "returned home" - which the guest doesn't follow).
Enemies.AppliedAction = Enemies.AppliedAction or {}

-- HateTarget = the guest's stand-in on this copy (proxy.lua) when there is one, so the enemies the guest hits go
-- after the guest; otherwise the host's hero.
function Enemies.ApplyGuestDamage(Token, Hero, HateTarget)
    if not Token or Token == "-" then return end
    HateTarget = Valid(HateTarget) and HateTarget or Hero
    for Item in Token:gmatch("[^;]+") do
        local Key, Total, Reaction, Killed = Item:match("^([^,]+),([^,]+),([^,]*),([K%-])$")
        if not Key then Key, Total, Reaction = Item:match("^([^,]+),([^,]+),?(.*)$") end
        Total = tonumber(Total)
        local E = Enemies.HostByKey[Key]
        if Total and Valid(E) and Active(E) then
            local Delta = Total - (Enemies.Applied[Key] or 0)
            local Dead = false
            if Delta > 0.5 then
                Enemies.Applied[Key] = Total
                local NewHP = math.max(0, Health(E) - Delta)
                SetHealth(E, NewHP)
                E:PopDamageValue(Delta, 0)
                Dead = NewHP <= 0
                -- a real hit also gives the attacker aggro; without any the enemy "returns home" and vanishes. Its
                -- targets can only be avatars on this copy: the guest's stand-in, or the host's hero
                if not Dead then pcall(function() E:SetHateGaugeOfAvatarAttack(HateTarget, math.floor(Delta)) end) end
            end
            if Killed == "K" and not Dead then
                SetHealth(E, 0)
                Dead = true
            end
            local R = DecodeReaction(Reaction)
            local NewR = R and R.Seq > (Enemies.AppliedAction[Key] or 0)
            if NewR then Enemies.AppliedAction[Key] = R.Seq end
            if Dead then
                Enemies.PlayReaction(E, Hero, NewR and R or nil, true)
            elseif NewR then
                Enemies.PlayReaction(E, Hero, R, false)
            end
        end
    end
end

---------------------------------------------------------------------------------------------------------------
-- Guest

local function DecodeAttack(S)
    if not S or S == "-" then return nil end
    local F = {}
    for X in S:gmatch("[^/]+") do F[#F + 1] = X end
    if #F < 9 then return nil end
    local Abilities = {}
    for N in (F[10] or ""):gmatch("[^+]+") do Abilities[#Abilities + 1] = N end
    return { Seq = tonumber(F[1]), Action = tonumber(F[2]), Category = tonumber(F[3]), Variation = tonumber(F[4]),
             Combo = tonumber(F[5]), Counter = F[6] == "1", Trigger = F[7] == "1", Section = F[8], Area = tonumber(F[9]),
             Abilities = Abilities }
end

function Enemies.Parse(Token)
    if not Token or Token == "-" then return nil end
    local List = {}
    for Item in Token:gmatch("[^;]+") do
        local F = {}
        for X in (Item .. ","):gmatch("([^,]*),") do F[#F + 1] = X end
        if #F >= 14 then
            local S = { Key = F[1], Class = F[2], X = tonumber(F[3]), Y = tonumber(F[4]), Z = tonumber(F[5]), Yaw = tonumber(F[6]),
                        VX = tonumber(F[7]), VY = tonumber(F[8]), Action = tonumber(F[10]), State = tonumber(F[11]),
                        MotionVar = tonumber(F[12]), HP = tonumber(F[13]), Max = tonumber(F[14]), Reaction = DecodeReaction(F[15]),
                        Level = tonumber(F[16]), Attack = DecodeAttack(F[17]) }
            if F[9] ~= "-" then
                local Path, Pos = F[9]:match("^(.-)@([%d%.]+)$")
                S.Montage, S.MontagePos = Path, tonumber(Pos)
            end
            List[#List + 1] = S
        end
    end
    return List
end

Enemies.Puppets = Enemies.Puppets or {}   -- guest: host key -> { Actor, Playing, Seen, ... }
Enemies.DeadKeys = Enemies.DeadKeys or {}   -- guest: host keys whose puppet died (host keys are never reused)
Enemies.Ours = Enemies.Ours or {}         -- guest: names of enemies we spawned as puppets

local function StopBrain(E)
    local AIC = E.Controller
    local Brain = Valid(AIC) and AIC.BrainComponent or nil
    if Valid(Brain) and Brain:IsRunning() then Brain:StopLogic("coop puppet") end
end

-- Guest-side enemies that aren't (or are no longer) puppets - the game's own spawning, puppets out of range or
-- left over from a reload - are switched off and hidden, never destroyed. The game puts idle enemies back in its
-- enemy pool by itself. Destroying pooled enemies breaks the game's spawner (nothing spawns any more, puppets
-- included), and the game mode's debug helpers are no good either: EnemySpawnSuppression is an empty stub in this
-- build, and DestroyAllEnemy / PlayerState:ServerDestroyEnemy leave every enemy unable to attack.
local function Neutralize(E)
    StopBrain(E)
    if not E.bHidden then pcall(function() E:SetActorHiddenInGame(true) end) end
end

local function Retire(E)
    Enemies.Ours[E:GetFName():ToString()] = nil   -- (if the game reuses it, it's either a native again or a new puppet)
    Neutralize(E)
end

local function SuppressNative(GS, World)
    if not Enemies.Suppressed then
        Log("enemies: guest - native enemies are replaced by puppets of the host's")
        Enemies.Suppressed = true
    end
    Enemies.Frame = (Enemies.Frame or 0) + 1
    if Enemies.Frame % 15 ~= 0 then return end
    if Enemies.AllowNativeUntil and os.clock() < Enemies.AllowNativeUntil then return end   -- (tests: let one spawn)
    -- the previous version's new-object callbacks still append here (they can't be unregistered); drop it
    Enemies.Pending, Enemies.PendingVolumes = nil, nil
    for _, E in ipairs(EnemyList(GS)) do
        if not Enemies.Ours[E:GetFName():ToString()] and not E.bHidden then Neutralize(E) end
    end
end

-- Puppets come from the game's own spawner (GameState:RODSpawnActor) at the host enemy's level, so they have
-- their stats and attack data and can make real attacks (an engine SpawnActor'd enemy has neither). The spawner
-- registers the enemy right away (it may hand back a pooled one); its behaviour tree is started by the spawner
-- and stopped here - started then stopped, or it never finishes appearing.
local function SpawnPuppet(H, World, FindAsset)
    local Class = FindAsset(H.Class)
    local GS = GameStateOf(World)
    if not (Class and GS) then return nil end
    local Before = {}
    for _, E in ipairs(EnemyList(GS)) do Before[E:GetAddress()] = true end
    local Half = math.rad(H.Yaw) / 2
    local Ok, Err = pcall(function()
        GS:RODSpawnActor(Class, { Rotation = { X = 0, Y = 0, Z = math.sin(Half), W = math.cos(Half) },
            Translation = { X = H.X, Y = H.Y, Z = H.Z }, Scale3D = { X = 1, Y = 1, Z = 1 } },
            { IsStartBehaviorTree = true, Level = math.max(1, H.Level or 1), InitialState = 0, IsDropItems = false, HeroNumber = 1 }, nil, nil, 1)
    end)
    if not Ok then Log("enemies: puppet spawn failed: " .. tostring(Err)) return nil end
    local E
    for _, X in ipairs(EnemyList(GS)) do if not Before[X:GetAddress()] then E = X end end
    if not E then
        -- the spawner reused a pooled enemy: the active one of this class at the spot
        local ClassName = Class:GetFName():ToString()
        for _, X in ipairs(EnemyList(GS)) do
            local L = X:K2_GetActorLocation()
            if X:GetClass():GetFName():ToString() == ClassName and X.EnemyStateValue < DeadStates
                and (L.X - H.X) ^ 2 + (L.Y - H.Y) ^ 2 < 100 * 100 then E = X end
        end
    end
    if not Valid(E) then return nil end
    Enemies.Ours[E:GetFName():ToString()] = true
    StopBrain(E)
    -- straight onto the host enemy's spot (a pooled enemy can come back wherever the pool parked it)
    E:K2_SetActorLocationAndRotation({ X = H.X, Y = H.Y, Z = H.Z }, { Pitch = 0, Yaw = H.Yaw, Roll = 0 }, false, {}, true)
    return { Actor = E, AtkSeq = H.Attack and H.Attack.Seq or 0 }   -- (an attack already under way isn't replayed)
end

-- The host says this puppet's enemy is attacking the guest: the puppet makes the same attack for real, aimed at
-- the guest's hero. Mirroring (steering, animation state, montages) pauses until the attack is over.
local function StartAttack(P, A, Hero, Now)
    local E = P.Actor
    StopBrain(E)
    -- back to a neutral battle stance through the game's own action change first (a mirrored montage or the
    -- previous attack may still be running), or the attack action doesn't register as a change and never starts
    pcall(function() E.Mesh:GetAnimInstance():Montage_Stop(0.1, nil) end)
    E:ServerSetAction(65, Hero:K2_GetActorLocation(), Hero, 0)   -- Battle_AttackStandby
    -- face the guest's hero: the mirrored facing points at the host's (slightly lagging) stand-in, and the swing
    -- only hits what's in front
    local L, HL = E:K2_GetActorLocation(), Hero:K2_GetActorLocation()
    E:K2_SetActorRotation({ Pitch = 0, Yaw = math.deg(math.atan(HL.Y - L.Y, HL.X - L.X)), Roll = 0 }, true)
    E:SetTargetAvatar_Cpp(Hero, true)
    E:SetAttackNumbers(A.Category, A.Variation, FName(A.Section), A.Counter, A.Trigger, A.Combo)
    E:ServerSetAction(A.Action, Hero:K2_GetActorLocation(), Hero, A.Variation)
    -- the enemy blueprint's own attack event: it fills the attack data (CurrentAttackParam - the montage etc.) and
    -- activates the attack ability. The puppet's behaviour tree never runs, so without it that data stays empty
    -- and the ability ends the moment it starts.
    E:BattleAttack()
    local Started = {}
    for Name in ActiveAttackAbilities(E):gmatch("[^+]+") do Started[#Started + 1] = Name end
    P.Attacking, P.AttackStart, P.AttackAbilities = true, Now, Started
    P.Playing, P.Action, P.State = nil, nil, nil   -- (mirroring picks up afresh afterwards)
    -- (host's attack next to what the puppet plays: does BattleAttack follow the attack numbers or pick its own?)
    local AN, M = E.AttackingNumbers, E.CurrentAttackParam.MontageData
    Log(string.format("enemies: puppet %s attacks the hero: host action %d cat %d var %d abilities %s | puppet cat %d var %d montage %s abilities %s, %.1f m away",
        E:GetFName():ToString(), A.Action, A.Category, A.Variation, table.concat(A.Abilities, "+"), AN.AtkCategory, AN.Variation,
        Valid(M) and M:GetFName():ToString() or "null", table.concat(Started, "+"), math.sqrt((L.X - HL.X) ^ 2 + (L.Y - HL.Y) ^ 2) / 100))
end

-- the attack is over once none of the abilities it started is still running (and at least 0.5 s has passed)
local function AttackRunning(P, Now)
    if Now - P.AttackStart < 0.5 then return true end
    if Now - P.AttackStart > 8 then return false end
    local Running = {}
    for _, Name in ipairs(P.AttackAbilities or {}) do Running[Name] = true end
    local Items = P.Actor.AbilitySystem.ActivatableAbilities.Items
    for i = 1, #Items do
        local S = Items[i]
        if S.ActiveCount > 0 and Valid(S.Ability) and Running[S.Ability:GetClass():GetFName():ToString()] then return true end
    end
    return false
end

local function PlayMontage(P, H, FindAsset)
    local Mesh = P.Actor.Mesh
    local AI = Valid(Mesh) and Mesh:GetAnimInstance() or nil
    if not Valid(AI) then return end
    if H.Montage then
        if P.Playing ~= H.Montage then
            local M = FindAsset(H.Montage)
            if M then AI:Montage_Play(M, 1.0, 0, H.MontagePos or 0, true) end
            P.Playing = H.Montage
        end
    elseif P.Playing then
        AI:Montage_Stop(0.2, nil)
        P.Playing = nil
    end
end

-- Idle / prowl / alert / strafe animations are animation-graph states driven by these values, not montages.
local function CopyAnimState(P, H)
    local E = P.Actor
    -- (not attack actions: written behind the game's back they leave the enemy thinking it's mid-attack, and a
    -- real attack (StartAttack) then never starts; the montage carries the look of an attack anyway)
    if H.Action and P.Action ~= H.Action and not IsAttackAction(H.Action) then E.EnemyActionValue = H.Action; P.Action = H.Action end
    if H.State and P.State ~= H.State and not (H.Action and IsAttackAction(H.Action)) then E.EnemyStateValue = H.State; P.State = H.State end
    if H.MotionVar and P.MotionVar ~= H.MotionVar then E.AnimStatusFlags.MotionVariation = H.MotionVar; P.MotionVar = H.MotionVar end
end

local function Steer(P, H, Age)
    local E = P.Actor
    local L = E:K2_GetActorLocation()
    local Dt = math.min(Age, 0.25)
    local WX, WY = H.X + H.VX * Dt, H.Y + H.VY * Dt
    local DX, DY, DZ = WX - L.X, WY - L.Y, H.Z - L.Z
    local Dist = math.sqrt(DX * DX + DY * DY)
    -- The puppet's AI isn't running, so it stays at its default walk speed while the host's enemy runs or
    -- charges: let it go as fast as its twin (plus catch-up headroom), or it falls behind and gets snapped.
    local Speed = math.sqrt(H.VX * H.VX + H.VY * H.VY)
    local WantMax = math.max(150, Speed * 1.25 + math.min(Dist, 400))
    if not P.MaxSpeed or math.abs(P.MaxSpeed - WantMax) > WantMax * 0.1 then
        local CM = E.CharacterMovement
        if Valid(CM) then CM.MaxWalkSpeed = WantMax end
        P.MaxSpeed = WantMax
    end
    if Dist > SnapDistance or math.abs(DZ) > 400 then
        -- (not K2_TeleportTo: it refuses whenever the destination fails its collision test, which left a pooled
        -- puppet stuck at the world origin; a teleporting set-location always moves it)
        E:K2_SetActorLocationAndRotation({ X = WX, Y = WY, Z = H.Z }, { Pitch = 0, Yaw = H.Yaw, Roll = 0 }, false, {}, true)
    elseif Dist > ArriveDistance then
        local Scale = (Speed > 50) and 1 or math.min(1, Dist / 200)
        E:AddMovementInput({ X = DX / Dist, Y = DY / Dist, Z = 0 }, Scale, false)
    else
        E:K2_SetActorRotation({ Pitch = 0, Yaw = H.Yaw, Roll = 0 }, false)
    end
end

-- HP on the guest. The puppet's HP follows the host's downwards (so HP bars match); any other drop is damage
-- done here - by the guest or its AI teammates - and is added to the running total sent to the host. A puppet
-- that reaches 0 locally just dies here; the host's enemy dies from the same damage a moment later.
Enemies.DamageTotals = Enemies.DamageTotals or {}   -- guest: host key -> running damage total
Enemies.DamageAt = Enemies.DamageAt or {}           -- guest: host key -> when its total last changed (os.clock)
Enemies.KilledHere = Enemies.KilledHere or {}       -- guest: host key -> { At, Reaction } of a puppet killed here
local SendFor = 10   -- a total / kill is still sent this many seconds after its last change (the puppet may be gone)

-- Returns false until the puppet has the host's HP (it takes the host's numbers on the first update).
local function SyncHealth(P, H)
    local E = P.Actor
    -- HP sync never takes a puppet to 0 itself: deaths go through KillPuppet (KillingBlow) so the game plays them
    if not P.HostMax then
        if not (H.HP and H.Max) then return false end
        local Start = math.max(H.HP, 1)
        SetHealth(E, Start, H.Max)
        P.HostMax, P.Baseline = H.Max, Start
        return true
    end
    local HP = Health(E)
    if HP < P.Baseline - 0.5 then
        Enemies.DamageTotals[H.Key] = (Enemies.DamageTotals[H.Key] or 0) + (P.Baseline - HP)
        Enemies.DamageAt[H.Key] = os.clock()
    end
    P.Baseline = HP
    if H.HP and H.HP > 0 and H.HP < HP - 0.5 and HP > 0 then   -- host is lower (its own team's damage, or ours applied)
        SetHealth(E, H.HP)
        P.Baseline = H.HP
    end
    return true
end

-- Record the hit reaction the game plays on an enemy, keyed by enemy object name. Host: every enemy, sent with the
-- enemy so the guest's puppet dies the same way. Guest: the puppets the guest (or its AI teammates) hit, sent with
-- the damage. Reactions we replay ourselves aren't recorded.
Enemies.Reactions = Enemies.Reactions or {}           -- guest: puppet object name -> encoded reaction
Enemies.HostReactions = Enemies.HostReactions or {}   -- host: enemy object name -> encoded reaction

function Enemies.OnReaction(E, A)
    if not Coop or Enemies.Replaying or not Valid(E) then return end
    local Name = E:GetFName():ToString()
    if Coop.IsHost then
        Enemies.HostReactions[Name] = EncodeReaction(A)
    elseif Enemies.Ours[Name] then
        Enemies.Reactions[Name] = EncodeReaction(A)
    end
end

-- hooks can't be unregistered, so the hook is installed once and calls whatever Enemies.OnReaction is current
if not Enemies.ReactionHooked then
    local Ok, Err = pcall(RegisterHook, "/Script/ROD.RODEnemyCharacter:MulticastNotifyDamageAction", function(Ctx, Param)
        local Ok2, Err2 = pcall(Enemies.OnReaction, Ctx:get(), Param:get())
        if not Ok2 then Log("enemies: reaction hook: " .. tostring(Err2)) end
    end)
    Enemies.ReactionHooked = Ok
    if not Ok then Log("enemies: reaction hook failed: " .. tostring(Err)) end
end

-- Each enemy the guest has damaged, while its puppet is here or for SendFor seconds after its last change - so the
-- killing blow still reaches the host after the game has hidden the corpse - with the kill flag if it died here.
function Enemies.DamageToken()
    local T, Now = {}, os.clock()
    for Key, Total in pairs(Enemies.DamageTotals) do
        local P = Enemies.Puppets[Key]
        local Here = P and Valid(P.Actor)
        local K = Enemies.KilledHere[Key]
        if Here or Now - (Enemies.DamageAt[Key] or 0) < SendFor or (K and Now - K.At < SendFor) then
            local R = Here and Enemies.Reactions[P.Actor:GetFName():ToString()] or (K and K.Reaction)
            T[#T + 1] = string.format("%s,%.0f,%s,%s", Key, Total, R or "-", K and "K" or "-")
        elseif Now - (Enemies.DamageAt[Key] or 0) > 60 then   -- (long done with: forgotten)
            Enemies.DamageTotals[Key], Enemies.DamageAt[Key], Enemies.KilledHere[Key] = nil, nil, nil
        end
    end
    return #T > 0 and table.concat(T, ";") or "-"
end

-- The host's enemy died: kill the puppet with the host's killing-hit reaction so it plays the same death.
local function KillPuppet(P, Hero, Now, Reaction)
    if not P.Dead then
        SetHealth(P.Actor, 0)
        Enemies.PlayReaction(P.Actor, Hero, Reaction, true)
    end
    P.Dead, P.DiedAt = true, P.DiedAt or Now
end

-- List = host enemies (nil when the host isn't on this map / not connected). Now = seconds.
function Enemies.GuestUpdate(List, Age, Now, World, FindAsset, Hero)
    local GS = GameStateOf(World)
    if not GS then return end
    SuppressNative(GS, World)
    if List then
        for _, H in ipairs(List) do
            local P = Enemies.Puppets[H.Key]
            -- a live puppet the game has put back in its pool (hidden and asleep - idle enemies "go home" and
            -- vanish) is replaced; asleep it can't play anything (the spawner may wake the same one up again)
            if P and Valid(P.Actor) and not P.Dead and P.Actor.bHidden and Now - (P.SpawnedAt or Now) > 5 then
                Enemies.Puppets[H.Key], P = nil, nil
            end
            -- an enemy that's dying on the host (or whose puppet already died here) never gets a new puppet,
            -- or a dead puppet that the game hides would be respawned and killed again every frame
            if not (P and Valid(P.Actor)) and not Enemies.DeadKeys[H.Key] and not (H.State and H.State >= DeadStates) then
                P = SpawnPuppet(H, World, FindAsset)
                if P then P.SpawnedAt = Now end
                Enemies.Puppets[H.Key] = P
            end
            if P and Valid(P.Actor) then
                P.Seen = Now
                if not P.Dead then
                    local HasHP = SyncHealth(P, H)   -- first, so a killing blow is still counted
                    if HasHP and Health(P.Actor) <= 0 then
                        P.Dead, P.DiedAt = true, Now   -- died here: leave it to the game's death
                        Enemies.DeadKeys[H.Key] = true
                        -- (and tell the host it's dead, whatever its HP is there)
                        Enemies.KilledHere[H.Key] = { At = os.clock(), Reaction = Enemies.Reactions[P.Actor:GetFName():ToString()] }
                    elseif H.State and H.State >= DeadStates then
                        KillPuppet(P, Hero, Now, H.Reaction)   -- died on the host
                        Enemies.DeadKeys[H.Key] = true
                    else
                        -- a new attack on the guest: made once its ability is known (it can lag the action by a
                        -- frame or two; after a short wait it's made with the standard melee ability)
                        local A = Enemies.NativeAttacks and H.Attack or nil
                        if A and A.Seq ~= P.AtkSeq then
                            if P.AtkWait ~= A.Seq then P.AtkWait, P.AtkWaitAt = A.Seq, Now end
                            if #A.Abilities > 0 or Now - P.AtkWaitAt > 0.4 then
                                P.AtkSeq, P.AtkWait = A.Seq, nil
                                local Ok, Err = pcall(StartAttack, P, A, Hero, Now)
                                if not Ok then Log("enemies: puppet attack failed: " .. tostring(Err)) end
                            end
                        end
                        if P.Attacking and not AttackRunning(P, Now) then P.Attacking = false end
                        if not P.Attacking then
                            StopBrain(P.Actor)
                            Steer(P, H, Age)
                            CopyAnimState(P, H)
                            PlayMontage(P, H, FindAsset)
                        end
                    end
                end
            end
        end
    end
    for K, P in pairs(Enemies.Puppets) do
        if not Valid(P.Actor) then
            Enemies.Puppets[K] = nil
        elseif P.Dead then
            -- give the death animation time. Once the game hides the corpse it's back in the game's enemy pool
            -- (the spawner may reuse it for a later puppet), so it's only forgotten, not destroyed
            if P.Actor.bHidden then
                Enemies.Puppets[K] = nil
            elseif Now - P.DiedAt > CorpseTime then
                Retire(P.Actor)
                Enemies.Puppets[K] = nil
            end
        elseif not P.Seen or Now - P.Seen > PuppetTimeout then
            Retire(P.Actor)   -- (the host stopped reporting it: out of range)
            Enemies.Puppets[K] = nil
        end
    end
end

function Enemies.Status(World)
    local GS = GameStateOf(World)
    local Total, Visible = 0, 0
    if GS then
        for _, E in ipairs(EnemyList(GS)) do
            if not Enemies.Ours[E:GetFName():ToString()] then
                Total = Total + 1
                if not E.bHidden then Visible = Visible + 1 end
            end
        end
    end
    local Puppets = 0
    for _ in pairs(Enemies.Puppets) do Puppets = Puppets + 1 end
    return string.format("enemies: game=%d (visible %d) puppets=%d suppressed=%s", Total, Visible, Puppets, tostring(Enemies.Suppressed))
end

-- Map change (or a restart of the sync): start over. Puppets still around (a restart on the same map) are
-- switched off and hidden like any native enemy.
function Enemies.Reset()
    for _, P in pairs(Enemies.Puppets or {}) do
        if P and Valid(P.Actor) then pcall(Retire, P.Actor) end
    end
    Enemies.Puppets, Enemies.Ours, Enemies.Gen, Enemies.DeadKeys = {}, {}, {}, {}
    Enemies.HostByKey, Enemies.Applied, Enemies.DamageTotals = {}, {}, {}
    Enemies.DamageAt, Enemies.KilledHere = {}, {}
    Enemies.AppliedAction, Enemies.Reactions, Enemies.HostReactions = {}, {}, {}
    Enemies.Suppressed, Enemies.Frame = nil, 0
end

-- The game's enemy lists (GameState.RODEnemies, the enemy group's EnemyList) must never hold a destroyed enemy:
-- native timers walk them and read every entry's controller, and a null entry there is an access violation (the
-- guest crashed that way right after a checkpoint restart). Skip = addresses to take out as well.
local function Prune(Arr, Skip)
    local Keep, Dropped = {}, 0
    for i = 1, #Arr do
        local E = Arr[i]
        if type(E) == "userdata" and not E.IsValid and E.get then E = E:get() end
        if Valid(E) and not (Skip and Skip[E:GetAddress()]) then Keep[#Keep + 1] = E else Dropped = Dropped + 1 end
    end
    if Dropped > 0 then
        Arr:Empty()
        for i, E in ipairs(Keep) do Arr[i] = E end
    end
    return Dropped
end

-- Guest, every tick: drop destroyed enemies from the game's lists.
function Enemies.CleanList(World)
    local GS = GameStateOf(World)
    if not GS then return end
    local N = Prune(GS.RODEnemies)
    pcall(function() N = N + Prune(GS.ManagerEnemyGroup.EnemyList) end)
    if N > 0 then Log(string.format("enemies: dropped %d destroyed enemies from the game's enemy lists", N)) end
end

-- Guest, before its own checkpoint restart (a real death: same map, the game rebuilds the level): the puppets
-- are switched off and taken out of the game's enemy lists, so the rebuild can't leave them there dangling, and
-- the sync starts over with the host's enemies once the world is back.
function Enemies.ForgetPuppets(World)
    local Skip, N = {}, 0
    for _, P in pairs(Enemies.Puppets or {}) do
        if Valid(P.Actor) then Skip[P.Actor:GetAddress()] = true; N = N + 1 end
    end
    Enemies.Reset()
    local GS = GameStateOf(World)
    if GS then
        Prune(GS.RODEnemies, Skip)
        pcall(function() Prune(GS.ManagerEnemyGroup.EnemyList, Skip) end)
    end
    Log(string.format("enemies: %d puppets let go before the checkpoint restart", N))
end

-- Undo on the guest: retire the puppets (the game's own enemies come back once nothing switches them off).
function Enemies.RestoreNative(World)
    for _, P in pairs(Enemies.Puppets) do if Valid(P.Actor) then pcall(Retire, P.Actor) end end
    Enemies.Puppets = {}
    Enemies.Suppressed = nil
end

-- Host test helper: spawn Count enemies of a class that's already loaded (e.g. "BP_E001001_C", a boar) in an
-- arc Distance cm in front of the hero, through the game's own spawner (GameState:RODSpawnActor) so they come
-- with level, HP and running AI. (An engine SpawnActor'd enemy gets no spawner data and just stands idle.)
function Enemies.HostSpawn(ClassName, Count, Distance)
    local W = UEHelpers.GetWorld()
    local GS = GameStateOf(W)
    local H = UEHelpers.GetPlayerController().Pawn
    if not (GS and Valid(H)) then return "no game state / hero" end
    local Cls
    for _, E in ipairs(EnemyList(GS)) do
        if E:GetClass():GetFName():ToString() == ClassName then Cls = E:GetClass() break end
    end
    if not Valid(Cls) then return ClassName .. " is not loaded on this map" end
    local L, R = H:K2_GetActorLocation(), H:K2_GetActorRotation()
    Count, Distance = Count or 1, Distance or 800
    for i = 1, Count do
        local A = math.rad(R.Yaw + (i - (Count + 1) / 2) * 25)
        local Half = math.rad(R.Yaw + 180) / 2
        GS:RODSpawnActor(Cls, {
            Rotation = { X = 0, Y = 0, Z = math.sin(Half), W = math.cos(Half) },
            Translation = { X = L.X + math.cos(A) * Distance, Y = L.Y + math.sin(A) * Distance, Z = L.Z + 50 },
            Scale3D = { X = 1, Y = 1, Z = 1 },
        }, { IsStartBehaviorTree = true, Level = 6, InitialState = 0, IsDropItems = true, HeroNumber = 1 }, nil, nil, 1)
    end
    return string.format("spawned %d x %s", Count, ClassName)
end

Log("enemies.lua loaded")
