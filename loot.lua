-- Loot sync (host authority). Enemy drops (BP_DropItem_* pickups) only really happen on the host - the guest's
-- enemies are puppets - so the host reports its drops and the guest spawns copies of them (same pickup class,
-- place and items). Picking one up is reported to the other side. Two modes, chosen on the host (Loot.Mode):
--   "share": every drop is there for both players; each picks up their own copy.
--   "steal": one drop for both - whoever picks it up first takes it, and it disappears for the other.
-- Any drop the guest's game makes by itself is removed (the host's copy is the real one).
-- Loaded by coop.lua; shares its environment.
--
-- Wire format: host "I=<mode>;<id>,<class path>,<x>,<y>,<z>,<cat>:<item>:<num>/...;..." and
-- guest "K=<id>/<id>/..." (ids it picked up, this map).

Loot = Loot or {}
-- mode from coop_loot.txt ("share" or "steal"; only the host's setting counts), default share
do
    local F = io.open("ue4ss/Mods/NetDebug/coop_loot.txt", "r")
    local M = F and F:read("*l")
    if F then F:close() end
    Loot.Mode = (M == "steal") and "steal" or "share"
end

local ReportRadius = 8000
local MaxReported = 40

local function Valid(O) return O ~= nil and O:IsValid() end

Loot.HostDrops = Loot.HostDrops or {}   -- host: drop id -> { Actor, Class, Picked, Removed }
Loot.Replicas = Loot.Replicas or {}     -- guest: host drop id -> { Actor, Picked }
Loot.Picked = Loot.Picked or {}         -- guest: host drop ids it picked up (sent to the host)

local function IsDrop(A) return A:GetClass():GetFName():ToString():find("^BP_DropItem") ~= nil end
local function DropId(A) return A:GetFName():ToString():match("_(%d+)$") end

local function ItemsToken(A)
    local T = {}
    local Items = A.Items
    for i = 1, #Items do
        local It = Items[i]
        T[#T + 1] = string.format("%d:%d:%d", It.Category, It.ItemId, It.Num)
    end
    return table.concat(T, "/")
end

-- The map's drops right now: the gimmick manager's lists of dropped items, read on the game thread. (Not
-- NotifyOnNewObject: its callback runs on whichever thread makes the object - the background loading thread for
-- the pickups placed around a field, as it streams in while you run about - and Lua run there alongside the
-- game thread's crashes the game. Nor FindAllOf, which walks every object in the game.)
local function DropsNow(World)
    local Out = {}
    local GS = World and World.GameState
    local MG = Valid(GS) and GS.ManagerGimmick or nil
    if not Valid(MG) then return Out end
    for _, Field in ipairs({ "KeepDropItems", "KeepDropItemsCanDelete" }) do
        local L = MG[Field]
        for i = 1, #L do
            local A = L[i]
            if type(A) == "userdata" and not A.IsValid and A.get then A = A:get() end
            if Valid(A) and IsDrop(A) then Out[#Out + 1] = A end
        end
    end
    return Out
end

if not Loot.Hooked then
    -- a pickup: GiveItem runs on the gimmick when a player takes it (keyboard "Pick Up" or auto-collect)
    pcall(RegisterHook, "/Script/ROD.RODGimmickBase:GiveItem", function(Ctx)
        local A = Ctx:get()
        if not Coop or not Valid(A) or not IsDrop(A) then return end
        if Coop.IsHost then
            local D = Loot.HostDrops[DropId(A)]
            if D then D.Picked = true end
        else
            for Id, R in pairs(Loot.Replicas) do
                if R.Actor == A or (Valid(R.Actor) and R.Actor:GetFName():ToString() == A:GetFName():ToString()) then
                    R.Picked = true
                    Loot.Picked[Id] = true
                end
            end
        end
    end)
    Loot.Hooked = true
end

---------------------------------------------------------------------------------------------------------------
-- Host

local function Near(L, P)
    return P and (L.X - P.X) ^ 2 + (L.Y - P.Y) ^ 2 < ReportRadius * ReportRadius
end

function Loot.HostToken(Hero, GuestPos)
    -- new drops (the map's drop lists; each drop by its object name, kept with it so a reused address isn't taken
    -- for the drop)
    for _, A in ipairs(DropsNow(Hero:GetWorld())) do
        local Id = DropId(A)
        local D = Id and Loot.HostDrops[Id]
        if Id and not (D and Valid(D.Actor) and D.Name == A:GetFName():ToString()) then
            Loot.HostDrops[Id] = { Actor = A, Name = A:GetFName():ToString(), Class = A:GetClass():GetFullName():match("^%S+ (.+)$") }
        end
    end
    local HL = Hero:K2_GetActorLocation()
    local T = { Loot.Mode }
    for Id, D in pairs(Loot.HostDrops) do
        if not Valid(D.Actor) or (D.Name and D.Actor:GetFName():ToString() ~= D.Name) then
            Loot.HostDrops[Id] = nil
        elseif not D.Picked and not D.Removed and #T <= MaxReported then
            local A = D.Actor
            local L = A:K2_GetActorLocation()
            if (Near(L, HL) or Near(L, GuestPos)) and #A.Items > 0 then
                T[#T + 1] = string.format("%s,%s,%.0f,%.0f,%.0f,%s", Id, D.Class, L.X, L.Y, L.Z, ItemsToken(A))
            end
        end
    end
    return table.concat(T, ";")
end

-- Host: the guest picked these up. In steal mode the host's own copy goes too.
function Loot.ApplyGuestPicks(Token)
    if not Token or Token == "-" then return end
    for Id in Token:gmatch("[^/]+") do
        local D = Loot.HostDrops[Id]
        if D and not D.Removed then
            D.Removed = true
            if Loot.Mode == "steal" and not D.Picked and Valid(D.Actor) then D.Actor:K2_DestroyActor() end
        end
    end
end

---------------------------------------------------------------------------------------------------------------
-- Guest

function Loot.Parse(Token)
    if not Token or Token == "" then return nil end
    local Out = { List = {} }
    local First = true
    for Item in Token:gmatch("[^;]+") do
        if First then
            Out.Mode = Item
            First = false
        else
            local Id, Cls, X, Y, Z, Items = Item:match("^([^,]+),([^,]+),([^,]+),([^,]+),([^,]+),(.*)$")
            if Id then
                local Its = {}
                for C, I, N in Items:gmatch("(%d+):(%d+):(%d+)") do
                    Its[#Its + 1] = { Category = tonumber(C), ItemId = tonumber(I), Num = tonumber(N) }
                end
                Out.List[#Out.List + 1] = { Id = Id, Class = Cls, X = tonumber(X), Y = tonumber(Y), Z = tonumber(Z), Items = Its }
            end
        end
    end
    return Out
end

function Loot.GuestToken()
    local T = {}
    for Id in pairs(Loot.Picked) do T[#T + 1] = Id end
    return #T > 0 and table.concat(T, "/") or "-"
end

local function SpawnReplica(H, World, FindAsset)
    local Cls = FindAsset(H.Class)
    if not Cls then return nil end
    local Ok, A = pcall(function()
        return World:SpawnActor(Cls, { X = H.X, Y = H.Y, Z = H.Z }, { Pitch = 0, Yaw = 0, Roll = 0 })
    end)
    if not (Ok and Valid(A)) then return nil end
    pcall(function() A:SetItem(H.Items, -1, false) end)
    return { Actor = A }
end

-- A drop the guest's own game made next to one of its enemy puppets is removed (the host's copy is the real one):
-- a few times a second, on the game thread. Our replicas and drops away from puppets (a chest the guest opened)
-- stay.
local function RemoveOwnDrops(World)
    if os.clock() < (Loot.OwnCheckAt or 0) then return end
    Loot.OwnCheckAt = os.clock() + 0.25
    local Ours = {}
    for _, R in pairs(Loot.Replicas) do if Valid(R.Actor) then Ours[R.Actor:GetFName():ToString()] = true end end
    for _, A in ipairs(DropsNow(World)) do
        local Name = A:GetFName():ToString()
        if not Ours[Name] then
            local L = A:K2_GetActorLocation()
            for _, P in pairs(Enemies and Enemies.Puppets or {}) do
                if Valid(P.Actor) then
                    local PL = P.Actor:K2_GetActorLocation()
                    if (PL.X - L.X) ^ 2 + (PL.Y - L.Y) ^ 2 < 800 ^ 2 then A:K2_DestroyActor() break end
                end
            end
        end
    end
end

-- S = parsed host loot (nil when the host isn't here)
function Loot.GuestUpdate(S, World, FindAsset)
    pcall(RemoveOwnDrops, World)
    if not S then return end
    local Seen = {}
    for _, H in ipairs(S.List) do
        Seen[H.Id] = true
        local R = Loot.Replicas[H.Id]
        if not R and not Loot.Picked[H.Id] then
            Loot.Replicas[H.Id] = SpawnReplica(H, World, FindAsset) or { Failed = true }
        end
    end
    -- the host's drop is gone (picked up by the host, expired, or out of range): in steal mode it's gone for us too
    for Id, R in pairs(Loot.Replicas) do
        if not Seen[Id] and S.Mode == "steal" and not R.Picked then
            if Valid(R.Actor) then R.Actor:K2_DestroyActor() end
            Loot.Replicas[Id] = nil
        end
    end
end

function Loot.Reset()
    for _, R in pairs(Loot.Replicas) do if Valid(R.Actor) then pcall(function() R.Actor:K2_DestroyActor() end) end end
    Loot.HostDrops, Loot.Replicas, Loot.Picked = {}, {}, {}
end

function Loot.Status()
    local H, R = 0, 0
    for _ in pairs(Loot.HostDrops) do H = H + 1 end
    for _ in pairs(Loot.Replicas) do R = R + 1 end
    return string.format("loot: mode=%s host drops=%d replicas=%d", Loot.Mode, H, R)
end

Log("loot.lua loaded")
