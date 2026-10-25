-- Quests in co-op: only the host picks them, and the guest goes along.
--
-- Lock: on the guest's copy the town's main terminal (the Large Teleport Gate, where quests are picked) gets the
-- game's own access-deny flag (EAccessibleGimmickFlag::AccessDeny - what the game's event lock sets on each
-- terminal: V there says it can't be accessed during an event), taken off again when co-op stops (leaving the
-- room, the host closing it). Everything else - warp terminals, the field's terminals, shops, the book - stays
-- usable. (The game's event lock itself can only lock every terminal at once; and blanking the gate's access
-- action instead, as an earlier version did, is the suspect in a guest crashing at the gate.) Each visit to town
-- has its own gate, locked anew.
--
-- Follow: once the host has set off on a quest (its quest select status past QuestSelectPrepare) or is in one, it
-- sends "J=<quest id>,<start terminal>" (coop.lua's state line). A guest that isn't in a quest then makes the same
-- choice: ServerReadyForcedQuest + DebugQuestStart, the terminal's quest menu with the host's start terminal, and
-- DecideQuest (the recipe that loads the same field at the same start point). That opens the game's partner select
-- and quest list on the guest; they're decided from here through the menus' own handlers (the highlighted partner;
-- the host's quest, looked up by id - whichever way closes each menu is logged), and left alone once the map is
-- changing. A guest that joins the room while the host is out on a quest follows it there too.
--
-- Runs its own loop (co-op may be stopped). Loaded by coop.lua; shares its environment.

Quests = Quests or {}

local AccessibleGimmick = 1   -- EAccessRestrictionGimmickKind::AccessibleGimmick (the old, every-terminal lock)
local LockKey = "AincradCoopGuest"
local GateClass = "BP_TeleportGate_C"   -- the town's main terminal
local AccessDeny = 0   -- EAccessibleGimmickFlag::AccessDeny
local QuestSelectPrepare, Ready = 11, 23   -- EQuestSelectStatus: the host has set off on the quest
local FollowMenus = { [61] = "quest list", [62] = "quest level", [63] = "partner select" }   -- EMenuKind
local FollowSeconds = 40   -- how long a follow may take to get through its menus and away

local function Valid(O) return O ~= nil and O:IsValid() end
local function Running(Me) return Coop.Handles and #Coop.Handles > 0 and Coop.Me == Me end

-- (looked up each time - cheap, see Coop.LocalPC - not kept: a controller kept across a map change is the old map's)
local function Controller() return Coop.LocalPC() end

-- (the gameplay maps' GameState only: the title screen's has no quests or terminals)
local function CurrentGameState()
    local PC = Controller()
    local GS = PC and PC:GetWorld().GameState
    if not Valid(Quests.GSClass) then Quests.GSClass = StaticFindObject("/Script/ROD.RODGameState") end
    return (Valid(GS) and Valid(Quests.GSClass) and GS:IsA(Quests.GSClass)) and GS or nil
end

---------------------------------------------------------------------------------------------------------------
-- The guest's terminal lock

-- (from the map's own list of accessible gimmicks - not FindAllOf, which scans every object in the game)
local function Gates(GS)
    local Out, L = {}, GS.RODAccessibleGimmicks
    for i = 1, #L do
        local G = L[i]
        if type(G) == "userdata" and not G.IsValid and G.get then G = G:get() end
        if Valid(G) and G:GetClass():GetFName():ToString() == GateClass then Out[#Out + 1] = G end
    end
    return Out
end

local function HasFlag(G, Flag)
    local L = G.Flags
    for i = 1, #L do
        local V = L[i]
        if type(V) == "userdata" and V.get then V = V:get() end
        if V == Flag then return true end
    end
    return false
end

-- the gate's access-deny flag on; true if this set it (a deny the game already has - a story event - is left alone)
local function LockGate(G)
    if HasFlag(G, AccessDeny) then return false end
    G:ToggleFlags(true, AccessDeny)
    return true
end

local function UnlockGate(G)
    G:ToggleFlags(false, AccessDeny)
end

-- (the map by its GameState's name: a new map's can reuse the old one's address - and so can a gate)
local function UpdateLock(GS)
    local Name = GS:GetFullName()
    if Quests.LockedIn then   -- (the every-terminal event lock of an earlier version: lifted)
        if Quests.LockedIn == Name then pcall(function() GS:ToggleAccessDenyGimmick(AccessibleGimmick, false, FName(LockKey)) end) end
        Quests.LockedIn = nil
        Log("quests: the old every-terminal lock is lifted")
    end
    local L = Quests.GateLock
    if L and L.Map ~= Name then Quests.GateLock, L = nil, nil end   -- (that map's gate went with it)
    local Following = Quests.Follow and os.clock() < Quests.Follow.Until
    local Want = Running("B") and not Following and not GS:IsInQuest()
    if Want and not L then
        local Found, Locked = Gates(GS), {}
        for _, G in ipairs(Found) do
            if LockGate(G) then Locked[#Locked + 1] = { G = G, Name = G:GetFullName() } end
        end
        if #Found > 0 then   -- (no gate yet: tried again on the next pass)
            Quests.GateLock = { Map = Name, Gates = Locked }
            Log("quests: the main terminal is locked - the host picks the quest")
        end
    elseif not Want and L then
        for _, E in ipairs(L.Gates) do
            if Valid(E.G) and E.G:GetFullName() == E.Name then UnlockGate(E.G) end
        end
        Quests.GateLock = nil
        if not Following then Log("quests: the main terminal is unlocked") end
    end
end

---------------------------------------------------------------------------------------------------------------
-- The host's quest, for the state line

local function UpdateHostToken(GS)
    local Ok, Token = pcall(function()
        local Id, Status = GS.QuestManager.QuestId, GS.GameQuestSelectStatus
        if Id and Id > 0 and ((Status >= QuestSelectPrepare and Status <= Ready) or GS:IsInQuest()) then
            return string.format("J=%d,%s", Id, GS.StartTerminalId:ToString())
        end
        return "J=-"
    end)
    Token = Ok and Token or "J=-"
    if Token ~= Quests.Token then
        Quests.Token = Token
        if Token ~= "J=-" then Log("quests: host set off on quest " .. Token:sub(3) .. " - the guest follows") end
    end
end

-- coop.lua: the host's token / the guest reads it from the host's line
function Quests.HostToken() return Quests.Token or "J=-" end
function Quests.Parse(Line)
    local Id, Terminal = Line:match(" J=(%d+),(%S+)")
    return Id and { Id = tonumber(Id), Terminal = Terminal } or nil
end

---------------------------------------------------------------------------------------------------------------
-- The guest following

local function StartFollow(Q, MenusUp)
    local PC = Controller()
    local PS, GS = PC.PlayerState, PC:GetWorld().GameState
    Quests.Follow = { Key = Q.Id .. "," .. Q.Terminal, Id = Q.Id, Until = os.clock() + FollowSeconds, Menus = {}, From = GS:GetFullName() }
    UpdateLock(GS)   -- (lifted while following)
    if MenusUp then   -- (an earlier follow's partner select / quest list are still up: just get past them)
        Log(string.format("quests: following the host to quest %d - its menus are already up", Q.Id))
        return
    end
    Log(string.format("quests: following the host to quest %d (start %s)", Q.Id, Q.Terminal))
    PS:ServerReadyForcedQuest()
    PC:DebugQuestStart(Q.Id, true)
    PS:ServerSelectQuestTopMenu(true)
    PS:ServerDecideStartTerminal(FName(Q.Terminal))
    GS:DecideQuest(Q.Id, 0, 0, false, 0)
    GS:SetQuestSelectStatus(5, FName("None"))   -- EQuestSelectStatus::QuestSelect
    GS:DecideQuest(Q.Id, 0, 0, false, 0)
end

-- The follow's menus, decided through the game's own handlers (what a confirm press on the entry calls) - the
-- partner select on the highlighted partner, the quest list on the host's quest (looked up by its id, so the guest
-- can't end up on another one). Each menu's ways are tried in turn, a moment apart, until it has gone.
local function PartnerItem(M)
    local L = M.PartnerList
    local Item = Valid(L) and L.ListItems[L.CurrentIndex + 1] or nil
    if not Valid(Item) then error("no highlighted partner") end
    return Item
end

-- (only the menus' own decide handlers on a real entry: the generic accept callback / button presses tried first
-- picked entries blind, and copy 2 died arriving in the field after them). The partner select is the one that
-- matters: once it's decided the trip starts by itself a few seconds later, with the quest list still up - so the
-- quest list is left alone (its entry for the host's quest isn't found anyway).
local Confirms = {
    [63] = {   -- partner select (URODSelectPartnerMenuWidgetBase)
        { "click on the highlighted partner", function(M) M:ListClickDelegate(PartnerItem(M), 1, 1) end },     -- Accept, Single
        { "accept on the highlighted partner", function(M) M:ListButtonDownDelegate(PartnerItem(M), 1) end },   -- Virtual_Accept
        { "the partner decision", function(M) M:OnDecision(M.CurrentPartnerID) end },
    },
}

local function CurrentMenu()
    local PC = Controller()
    local UI = PC and PC.RODUIManagerRef
    local M = Valid(UI) and UI:GetCurrentMenuWidget() or nil
    return Valid(M) and M or nil
end

local function ConfirmMenus()
    local F = Quests.Follow
    local M = CurrentMenu()
    if not M then return end
    local Kind, Addr = M.MenuKind, M:GetAddress()
    local Seen = F.Menus[Addr]
    if not Seen then
        Seen = { Kind = Kind, At = os.clock(), Step = 0, Class = M:GetClass():GetFName():ToString() }
        F.Menus[Addr] = Seen
        Log(string.format("quests: follow - %s menu up (%s, kind %s)", FollowMenus[Kind] or "other", Seen.Class, tostring(Kind)))
    end
    local Ways = Confirms[Kind]
    if not Ways then return end
    if os.clock() - Seen.At < 0.5 + Seen.Step * 1.5 then return end   -- (after it has opened / since the last try)
    Seen.Step = Seen.Step + 1
    if Seen.Step > 1 and Ways[Seen.Step - 1] then Log("quests: follow - " .. Ways[Seen.Step - 1][1] .. " didn't close it") end
    local C = Ways[Seen.Step]
    if not C then
        if Seen.Step == #Ways + 1 then Log("quests: follow - couldn't get past the " .. FollowMenus[Kind]) end
        return
    end
    local Ok, Err = pcall(C[2], M, F.Id)
    Log(string.format("quests: follow - %s: %s", FollowMenus[Kind], Ok and C[1] or (C[1] .. " failed: " .. tostring(Err))))
end

local function UpdateFollow(GS)
    local F = Quests.Follow
    if F then
        -- (a new map, and it's the quest - or the host's map)
        local Tg = Coop.Target
        local Arrived = GS:GetFullName() ~= F.From and (GS:IsInQuest() or (Tg and Tg.Map == GS:GetWorld():GetFName():ToString()))
        if Arrived or os.clock() >= F.Until or not Running("B") then
            -- (arrived, or given up: the next follow of the same quest waits a while)
            Log(Arrived and "quests: follow - arrived in the quest" or "quests: follow - stopped (not in the quest)")
            Quests.Follow, Quests.LastKey, Quests.LastAt = nil, F.Key, os.clock()
            for Addr, Seen in pairs(F.Menus) do
                if FollowMenus[Seen.Kind] and Seen.Step > 0 then
                    Log(string.format("quests: follow - %s took %d tr%s", FollowMenus[Seen.Kind], Seen.Step, Seen.Step == 1 and "y" or "ies"))
                end
            end
            return
        end
        if GS:GetFullName() == F.From then ConfirmMenus() end   -- (hands off the menus once the map is changing)
        return
    end
    if not Running("B") then return end
    -- (the host's line counts once it has been seen to change since co-op started - never a single line, which
    -- may be one left over from an earlier session)
    if Quests.StartCount ~= Coop.StartCount then
        Quests.StartCount, Quests.PeerSeq, Quests.PeerAt, Quests.SeqChanges = Coop.StartCount, Coop.PeerSeq, nil, 0
    end
    if Coop.PeerSeq ~= Quests.PeerSeq then
        Quests.PeerSeq, Quests.SeqChanges = Coop.PeerSeq, (Quests.SeqChanges or 0) + 1
        if Quests.SeqChanges >= 2 then Quests.PeerAt = os.clock() end
    end
    local Tg = Coop.Target
    local Q = Tg and Quests.PeerAt and os.clock() - Quests.PeerAt < 3 and Tg.Quest   -- (the host's line, while it's live)
    if not Q or GS:IsInQuest() then return end
    local Map = GS:GetWorld():GetFName():ToString()
    if Tg.Map == Map then return end   -- (already where the host is)
    local Status = GS.GameQuestSelectStatus
    if Status >= QuestSelectPrepare and Status <= Ready then return end   -- (already on its way somewhere)
    local Key = Q.Id .. "," .. Q.Terminal
    if Key == Quests.LastKey and os.clock() - (Quests.LastAt or 0) < 90 then return end
    local M = CurrentMenu()
    local MenusUp = M and Confirms[M.MenuKind] ~= nil
    if M and not MenusUp then return end   -- (the guest is in a menu of its own: once it's closed)
    StartFollow(Q, MenusUp)
end

---------------------------------------------------------------------------------------------------------------

local function Update()
    local GS = CurrentGameState()
    if not GS then return end
    Quests.Frame = (Quests.Frame or 0) + 1
    if Running("A") then UpdateHostToken(GS) else Quests.Token = nil end
    UpdateFollow(GS)
    if Quests.Frame % 3 == 0 then UpdateLock(GS) end
end

if Quests.Handle then pcall(CancelDelayedAction, Quests.Handle) end
Quests.Follow = nil
Quests.Handle = LoopInGameThreadAfterFrames(10, function()
    local Ok, Err = pcall(Update)
    if not Ok and Quests.LastErr ~= tostring(Err) then
        Quests.LastErr = tostring(Err)
        Log("quests error: " .. Quests.LastErr)
    end
end)

Log("quests.lua loaded")
