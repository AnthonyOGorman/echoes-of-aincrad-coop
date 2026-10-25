-- Ghosts: animated stand-ins for the other copy's characters (its hero, AI partner and visitor).
--
-- Each ghost is a plain engine SkeletalMeshActor dressed like a local "source" character (same body, avatar
-- parts, sword/shield, locomotion and montages). A spawned game character never runs the game's own setup -
-- its animation and movement stay frozen - whereas the plain actor animates normally and runs no game logic.
-- The hero's ghost wears the other player's own look instead once their appearance token has arrived
-- (Ghost2.LookToken / ParseLook / SetLook).
-- Load live:  luafile ue4ss/Mods/NetDebug/ghost2.lua  (coop.lua loads it automatically)

Ghost2 = Ghost2 or {}

local SkeletalMeshActorClass = StaticFindObject("/Script/Engine.SkeletalMeshActor")
local SkeletalMeshComponentClass = StaticFindObject("/Script/Engine.SkeletalMeshComponent")
local Identity = { Rotation = { X = 0, Y = 0, Z = 0, W = 1 }, Translation = { X = 0, Y = 0, Z = 0 }, Scale3D = { X = 1, Y = 1, Z = 1 } }

-- The hero's character-creator parts; partners and visitors are a single body mesh.
Ghost2.HeroParts = { "UpperMesh", "GlovesMesh", "LowerMesh", "HeadGear", "EyebrowsMesh", "EyelineMesh", "PupilMesh", "NoseMesh" }
-- Locomotion blend spaces (e.g. BS_HS_Male_NON_00_Move_Normal_00): X = lean/turn (-45..45), Y = speed
-- (walk 60-250, run 400-420, sprint 710).
Ghost2.MoveThreshold = 20
Ghost2.AssetCache = Ghost2.AssetCache or {}

local function Valid(O) return O ~= nil and O:IsValid() end

local function SkeletalComponentsByName(Actor)
    local Map = {}
    local Comps = Actor:K2_GetComponentsByClass(SkeletalMeshComponentClass)
    for i = 1, #Comps do
        local C = Comps[i]:get()
        if Valid(C) then Map[C:GetFName():ToString()] = C end
    end
    return Map
end

local function CopyMaterials(From, To)
    for i = 0, From:GetNumMaterials() - 1 do
        local M = From:GetMaterial(i)
        if Valid(M) then To:SetMaterial(i, M) end
    end
end

-- (the object's "/Path/To.Asset" - its full name without the class)
local function PathOf(A)
    return A:GetFullName():match("^%S+ (.+)$")
end

-- An asset by path, kept for reuse - but a kept one only counts while it still IS that asset: one the game itself
-- doesn't use is freed by garbage collection (at the latest on a map change), and its address can then hold any
-- other object, which IsValid() still accepts. Ghosts / name plates / puppets built from such a stand-in crashed
-- or froze a copy as the other player arrived in a new map.
local function FindAsset(Path)
    local A = Ghost2.AssetCache[Path]
    if Valid(A) and PathOf(A) == Path then return A end
    Ghost2.AssetCache[Path] = nil
    A = StaticFindObject(Path)
    if not Valid(A) then A = LoadAsset(Path) end
    if Valid(A) and PathOf(A) == Path then Ghost2.AssetCache[Path] = A return A end
    return nil
end
Ghost2.FindAsset = FindAsset

-- A ghost object. PartNames lists extra skeletal mesh components to copy from the source (hero only).
function Ghost2.New(Name, PartNames)
    return { Name = Name, PartNames = PartNames or {}, Parts = {}, Equipment = {} }
end

---------------------------------------------------------------------------------------------------------------
-- Appearance (the "Q=" line token): what a copy's hero wears, so the other copy's ghost of it looks the same.
-- Per part the mesh asset, and per material slot the asset material plus the colour / customisation values the
-- game set on its runtime copy (a MaterialInstanceDynamic). Upper, gloves and lower are runtime meshes too (the
-- player's body-shape sliders baked in, /Engine/Transient): for those the unbaked mesh the game made them from
-- is sent (ResourceManager.AvatarMeshParts, indexed by EAvatarPartsKind). Both copies have every asset.
--
-- Token: "<part>~<mesh>~<material>~...|<part>~...", part = Body / a HeroParts name / Weapon / Shield, material =
-- "<slot>*<asset material>*<name>=<value>,...*<name>=<r>/<g>/<b>/<a>,...". Names and paths percent-encoded.

local PartKinds = { Body = 1, HeadGear = 0, UpperMesh = 2, GlovesMesh = 3, LowerMesh = 4, EyebrowsMesh = 5,
                    EyelineMesh = 6, PupilMesh = 7, NoseMesh = 8 }
local EquipmentFields = { Weapon = "EquippedWeapon", Shield = "EquippedShield" }

local function Get(X)
    if type(X) == "userdata" and not X.IsValid and X.get then return X:get() end
    return X
end

local function Enc(S) return (S:gsub("[^%w_%-%./]", function(C) return string.format("%%%02X", C:byte()) end)) end
local function Dec(S) return (S:gsub("%%(%x%x)", function(H) return string.char(tonumber(H, 16)) end)) end
local function Num(V) return string.format("%.4g", V) end

local function AssetPath(O)
    if not Valid(O) then return nil end
    local P = O:GetFullName():match("^%S+ (.+)$")
    if not P or P:find("^/Engine/Transient") then return nil end
    return P
end

local function MaterialsToken(C)
    local T = {}
    for i = 0, C:GetNumMaterials() - 1 do
        local M = C:GetMaterial(i)
        if Valid(M) then
            local Asset, Scalars, Vectors = M, {}, {}
            if M:GetClass():GetFName():ToString() == "MaterialInstanceDynamic" then
                Asset = M.Parent
                local S = M.ScalarParameterValues
                for j = 1, #S do
                    Scalars[#Scalars + 1] = Enc(S[j].ParameterInfo.Name:ToString()) .. "=" .. Num(S[j].ParameterValue)
                end
                local V = M.VectorParameterValues
                for j = 1, #V do
                    local Cl = V[j].ParameterValue
                    Vectors[#Vectors + 1] = Enc(V[j].ParameterInfo.Name:ToString()) .. "=" .. Num(Cl.R) .. "/" .. Num(Cl.G) .. "/" .. Num(Cl.B) .. "/" .. Num(Cl.A)
                end
            end
            local P = AssetPath(Asset)
            if P then T[#T + 1] = i .. "*" .. Enc(P) .. "*" .. table.concat(Scalars, ",") .. "*" .. table.concat(Vectors, ",") end
        end
    end
    return table.concat(T, "~")
end

local function PartToken(Name, C, Hero)
    if not (Valid(C) and C:IsVisible()) then return nil end
    local Path = AssetPath(C.SkeletalMeshAsset)
    if not Path and PartKinds[Name] then
        -- a baked runtime mesh: the unbaked one the game made it from
        local Ok, Src = pcall(function() return Get(Hero.ResourceManager.AvatarMeshParts[PartKinds[Name] + 1]) end)
        Path = Ok and AssetPath(Src) or nil
    end
    if not Path then return nil end
    local Mats = MaterialsToken(C)
    return Name .. "~" .. Enc(Path) .. (Mats ~= "" and ("~" .. Mats) or "")
end

-- This copy's hero's appearance token ("-" while it isn't built yet).
function Ghost2.LookToken(Hero)
    if not (Valid(Hero) and Valid(Hero.Mesh) and Valid(Hero.UpperMesh)) then return "-" end
    local Parts, Comps = {}, SkeletalComponentsByName(Hero)
    Parts[#Parts + 1] = PartToken("Body", Hero.Mesh, Hero)
    for _, Name in ipairs(Ghost2.HeroParts) do Parts[#Parts + 1] = PartToken(Name, Comps[Name], Hero) end
    for Key, Field in pairs(EquipmentFields) do
        local E = Hero[Field]
        local Root = Valid(E) and E.RootComponent or nil
        if Valid(Root) and Root:IsA(SkeletalMeshComponentClass) then Parts[#Parts + 1] = PartToken(Key, Root, Hero) end
    end
    return #Parts > 0 and table.concat(Parts, "|") or "-"
end

-- Cheap change check for LookToken (which takes tens of ms): the meshes and material objects the hero wears - a
-- new item or colour comes with new ones.
function Ghost2.LookSignature(Hero)
    if not (Valid(Hero) and Valid(Hero.Mesh)) then return "-" end
    local T, Comps = {}, SkeletalComponentsByName(Hero)
    local function Add(C)
        if not Valid(C) then T[#T + 1] = "x" return end
        local M = C.SkeletalMeshAsset
        T[#T + 1] = (Valid(M) and M:GetAddress() or 0) .. (C:IsVisible() and "v" or "h")
        for i = 0, C:GetNumMaterials() - 1 do
            local Mat = C:GetMaterial(i)
            T[#T + 1] = Valid(Mat) and Mat:GetAddress() or 0
        end
    end
    Add(Hero.Mesh)
    for _, Name in ipairs(Ghost2.HeroParts) do Add(Comps[Name]) end
    for _, Field in pairs(EquipmentFields) do
        local E = Hero[Field]
        Add(Valid(E) and E.RootComponent or nil)
    end
    return table.concat(T, ",")
end

function Ghost2.ParseLook(Token)
    if not Token or Token == "-" then return nil end
    -- (Sig: what's worn - meshes and asset materials, not the material values, some of which drift over time; a
    -- ghost is rebuilt only when that changes)
    local Look = { Sig = (Token:gsub("%*[^*~|]*%*[^*~|]*~", "~"):gsub("%*[^*~|]*%*[^*~|]*|", "|"):gsub("%*[^*~|]*%*[^*~|]*$", "")), Parts = {} }
    for Part in Token:gmatch("[^|]+") do
        local F = {}
        for X in Part:gmatch("[^~]+") do F[#F + 1] = X end
        if #F >= 2 then
            local P = { Mesh = Dec(F[2]), Materials = {} }
            for k = 3, #F do
                local Slot, Path, Sc, Ve = F[k]:match("^(%d+)%*([^*]*)%*([^*]*)%*([^*]*)$")
                if Slot then
                    local M = { Slot = tonumber(Slot), Path = Dec(Path), Scalars = {}, Vectors = {} }
                    for N, V in Sc:gmatch("([^,=]+)=([^,]+)") do M.Scalars[#M.Scalars + 1] = { Dec(N), tonumber(V) } end
                    for N, R, G, B, A in Ve:gmatch("([^,=]+)=([^/,]+)/([^/,]+)/([^/,]+)/([^/,]+)") do
                        M.Vectors[#M.Vectors + 1] = { Dec(N), { R = tonumber(R), G = tonumber(G), B = tonumber(B), A = tonumber(A) } }
                    end
                    P.Materials[#P.Materials + 1] = M
                end
            end
            Look.Parts[F[1]] = P
        end
    end
    return Look
end

-- A new look for ghost G (nil: copy the local source): rebuilt on its next update when it changed.
function Ghost2.SetLook(G, Look)
    local Sig = Look and Look.Sig or nil
    if Sig == G.LookSig then return end
    G.Look, G.LookSig = Look, Sig
    if Valid(G.Actor) then Ghost2.Destroy(G) end
end

local MaterialLibrary
local function ApplyMaterials(C, Mats, Outer)
    MaterialLibrary = Valid(MaterialLibrary) and MaterialLibrary or StaticFindObject("/Script/Engine.Default__KismetMaterialLibrary")
    for _, M in ipairs(Mats) do
        local Asset = FindAsset(M.Path)
        if Asset then
            if (#M.Scalars > 0 or #M.Vectors > 0) and Valid(MaterialLibrary) then
                local D = MaterialLibrary:CreateDynamicMaterialInstance(Outer, Asset, FName("None"), 0)
                if Valid(D) then
                    for _, S in ipairs(M.Scalars) do D:SetScalarParameterValue(FName(S[1]), S[2]) end
                    for _, V in ipairs(M.Vectors) do D:SetVectorParameterValue(FName(V[1]), V[2]) end
                    C:SetMaterial(M.Slot, D)
                end
            else
                C:SetMaterial(M.Slot, Asset)
            end
        end
    end
end

-- Idle sequence and locomotion blend space for the normal environment (ECharaAnimEnvType 0).
local function InitAnimSet(G, Source)
    local Data = Source.MovementAnimData
    if not Valid(Data) then return false end
    Data.NormalBlendSpaceSet:ForEach(function(Key, Value)
        if Key:get() == 0 then
            local Set = Value:get()
            G.IdleAnim, G.MoveBS = Set.Idle, Set.MoveBlendSpace
        end
    end)
    return Valid(G.IdleAnim) and Valid(G.MoveBS)
end

-- What one part wears: from the ghost's look (the other player's appearance), else copied from the local source
-- component. Returns the mesh and a function that puts the materials on a component (nil: not worn).
local function Wear(G, Name, SourceComp)
    if G.Look then
        local P = G.Look.Parts[Name]
        local Mesh = P and FindAsset(P.Mesh)
        if not Mesh then return nil end
        return Mesh, function(C) ApplyMaterials(C, P.Materials, G.Actor) end
    end
    local Mesh = Valid(SourceComp) and SourceComp:IsVisible() and SourceComp.SkeletalMeshAsset or nil
    if not Valid(Mesh) then return nil end
    return Mesh, function(C) CopyMaterials(SourceComp, C) end
end

-- Body + parts, all following the body's pose.
local function BuildBody(G, Source, Actor)
    local Body = Actor.SkeletalMeshComponent
    local Mesh, Dress = Wear(G, "Body", Source.Mesh)
    if not Mesh then Mesh, Dress = Source.Mesh.SkeletalMeshAsset, function(C) CopyMaterials(Source.Mesh, C) end end
    Body:SetSkeletalMeshAsset(Mesh)
    Dress(Body)
    Body:SetCollisionEnabled(0)
    G.Parts = {}
    if #G.PartNames == 0 then return 0 end
    local Src, Added = SkeletalComponentsByName(Source), 0
    for _, Name in ipairs(G.PartNames) do
        local Asset, PartDress = Wear(G, Name, Src[Name])
        if Asset then
            local C = Actor:AddComponentByClass(SkeletalMeshComponentClass, true, Identity, false)
            if Valid(C) then
                C:K2_AttachToComponent(Body, FName("None"), 2, 2, 2, false)
                C:SetSkeletalMeshAsset(Asset)
                PartDress(C)
                C:SetLeaderPoseComponent(Body, false, false)
                C:SetCollisionEnabled(0)
                G.Parts[Name] = C
                Added = Added + 1
            end
        end
    end
    return Added
end

-- Sword and shield (the look's, else copies of the source's); attachment follows the peer's "<parent>:<socket>".
local function BuildEquipment(G, Source, Actor)
    G.Equipment = {}
    for Key, Field in pairs(EquipmentFields) do
        local E = Source[Field]
        local Root = Valid(E) and E.RootComponent or nil
        local Asset, Dress = Wear(G, Key, Valid(Root) and Root:IsA(SkeletalMeshComponentClass) and Root or nil)
        if Asset then
            local C = Actor:AddComponentByClass(SkeletalMeshComponentClass, true, Identity, false)
            if Valid(C) then
                C:SetSkeletalMeshAsset(Asset)
                Dress(C)
                C:SetCollisionEnabled(0)
                G.Equipment[Key] = { Comp = C, Attach = nil }
            end
        end
    end
end

local function AttachEquipment(G, Key, Info)
    local Slot = G.Equipment[Key]
    if not (Slot and Valid(Slot.Comp)) or not Info or Info == "-" or Info == Slot.Attach then return end
    local ParentName, Socket = Info:match("^(.-):(.*)$")
    local Parent = (ParentName and G.Parts[ParentName]) or G.Actor.SkeletalMeshComponent
    if not Valid(Parent) then return end
    Slot.Comp:K2_AttachToComponent(Parent, FName(Socket ~= "" and Socket or "None"), 2, 2, 2, false)
    Slot.Attach = Info
end

-- The ghost copies its source's look and animations, so wait until the source is fully built (right after
-- loading, the body exists but parts and the movement anim data are not set yet).
local function SourceReady(G, Source)
    if not (Valid(Source) and Valid(Source.Mesh) and Valid(Source.Mesh.SkeletalMeshAsset) and Valid(Source.MovementAnimData)) then
        return false
    end
    if #G.PartNames > 0 then return Valid(Source.UpperMesh) and Valid(Source.UpperMesh.SkeletalMeshAsset) end
    return true
end

local function Ensure(G, S, Source, World)
    if Valid(G.Actor) then return G.Actor end
    if not SourceReady(G, Source) or not Valid(World) then return nil end
    -- Where the source's body mesh sits relative to the character (capsule centre): below it and turned.
    local SL, SR = Source:K2_GetActorLocation(), Source:K2_GetActorRotation()
    local ML, MR = Source.Mesh:K2_GetComponentLocation(), Source.Mesh:K2_GetComponentRotation()
    G.MeshZ, G.MeshYaw = ML.Z - SL.Z, MR.Yaw - SR.Yaw
    local A = World:SpawnActor(SkeletalMeshActorClass, { X = S.X, Y = S.Y, Z = S.Z + G.MeshZ },
        { Pitch = 0, Yaw = S.Yaw + G.MeshYaw, Roll = 0 })
    if not Valid(A) then Log("ghost " .. G.Name .. ": spawn failed") return nil end
    G.Actor, G.Playing, G.Pos = A, nil, nil
    local Parts = BuildBody(G, Source, A)
    BuildEquipment(G, Source, A)
    local HasAnims = InitAnimSet(G, Source)
    Log(string.format("ghost %s spawned: %s, %d parts, anims %s, look %s", G.Name, A:GetFName():ToString(), Parts,
        HasAnims and "ok" or "missing", G.Look and "the other player's" or "copied from this copy's"))
    return A
end

-- The peer's character is playing a montage (attack, dodge, skill): play the same asset at the same position.
local function PlayMontage(G, Path, Pos, Age)
    local Body = G.Actor.SkeletalMeshComponent
    local Montage = FindAsset(Path)
    if not Montage then return false end
    local Want = Pos + math.min(Age, 0.25)
    if G.Playing ~= Path then
        Body:PlayAnimation(Montage, false)
        Body:SetPosition(Want, false)
        G.Playing = Path
    elseif math.abs(Body:GetPosition() - Want) > 0.2 then
        Body:SetPosition(Want, false)
    end
    return true
end

local function Animate(G, Speed, S, Age)
    if S.Montage and PlayMontage(G, S.Montage, S.MontagePos or 0, Age) then return end
    local Body = G.Actor.SkeletalMeshComponent
    local Moving = Speed > Ghost2.MoveThreshold
    local Want = Moving and "move" or "idle"
    local Asset = Moving and G.MoveBS or G.IdleAnim
    if not Valid(Asset) then return end
    if G.Playing ~= Want then
        Body:PlayAnimation(Asset, true)
        G.Playing = Want
    end
    if Moving then
        local Single = Body:GetAnimInstance()
        if Valid(Single) then Single:SetBlendSpacePosition({ X = 0, Y = Speed, Z = 0 }) end
    end
end

local function LerpAngle(A, B, T)
    local D = (B - A + 180) % 360 - 180
    return A + D * T
end

-- Per-frame update of ghost G toward the peer state S {X,Y,Z,Yaw,VX,VY,VZ,Weapon,Shield,Montage,MontagePos}
-- received Age seconds ago. Source = the local character whose look it copies; World from coop.lua's cache.
function Ghost2.Update(G, S, Age, Source, World)
    local A = Ensure(G, S, Source, World)
    if not A then return end
    -- right after a map load the sword/shield can appear after the ghost was built: add them then
    local HasGear = G.Look and (G.Look.Parts.Weapon or G.Look.Parts.Shield)
        or (not G.Look and Valid(Source) and (Valid(Source.EquippedWeapon) or Valid(Source.EquippedShield)))
    if next(G.Equipment) == nil and HasGear then BuildEquipment(G, Source, A) end
    local Dt = math.min(Age, 0.25)
    local Want = { X = S.X + S.VX * Dt, Y = S.Y + S.VY * Dt, Z = S.Z + S.VZ * Dt }
    local P = G.Pos
    if not P then P = { X = Want.X, Y = Want.Y, Z = Want.Z }; G.Pos = P; G.Yaw = S.Yaw end
    local Far = (Want.X - P.X) ^ 2 + (Want.Y - P.Y) ^ 2 + (Want.Z - P.Z) ^ 2 > 1500 ^ 2
    local K = Far and 1 or 0.35
    P.X, P.Y, P.Z = P.X + (Want.X - P.X) * K, P.Y + (Want.Y - P.Y) * K, P.Z + (Want.Z - P.Z) * K
    G.Yaw = LerpAngle(G.Yaw, S.Yaw, Far and 1 or 0.35)
    A:K2_TeleportTo({ X = P.X, Y = P.Y, Z = P.Z + G.MeshZ }, { Pitch = 0, Yaw = G.Yaw + G.MeshYaw, Roll = 0 })
    AttachEquipment(G, "Weapon", S.Weapon)
    AttachEquipment(G, "Shield", S.Shield)
    Animate(G, math.sqrt(S.VX * S.VX + S.VY * S.VY), S, Age)
end

function Ghost2.SetHidden(G, Hidden)
    if Valid(G.Actor) and G.Hidden ~= Hidden then
        G.Actor:SetActorHiddenInGame(Hidden)
        G.Hidden = Hidden
    end
end

function Ghost2.Destroy(G)
    if Valid(G.Actor) then G.Actor:K2_DestroyActor() end
    G.Actor, G.Parts, G.Equipment, G.Hidden = nil, {}, {}, nil
end

Log("ghost2.lua loaded")
