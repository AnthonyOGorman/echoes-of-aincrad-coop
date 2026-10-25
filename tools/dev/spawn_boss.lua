-- spawn a boss through the game's own spawner (GameState:RODSpawnActor), BOSS_DIST cm in front of the hero, facing it
local Path = BOSS_PATH or "/Game/ROD/Blueprints/Characters/Enemies/016_Giant/BP_E016001.BP_E016001_C"
local PC = Coop.LocalPC()
local Hero = PC and PC.Pawn
if not (Hero and Hero:IsValid()) then return "no hero" end
local GS = PC:GetWorld().GameState
local Cls = Ghost2.FindAsset(Path)
if not Cls then return "could not load " .. Path end
local Lvl = BOSS_LEVEL
if not Lvl then
  pcall(function() Lvl = FindFirstOf("RODSaveLoadSubsystem").CurrentSaveGame.CharacterSaveData[1].Level end)
  Lvl = Lvl or 10
end
local function List()
  local T, A = {}, GS.RODEnemies
  for i = 1, #A do local E = A[i] if type(E) == "userdata" and not E.IsValid and E.get then E = E:get() end if E and E:IsValid() then T[E:GetAddress()] = E end end
  return T
end
local Before = List()
local L, R = Hero:K2_GetActorLocation(), Hero:K2_GetActorRotation()
local Dist, Yaw = BOSS_DIST or 1500, math.rad(R.Yaw)
local X, Y, Z = L.X + math.cos(Yaw) * Dist, L.Y + math.sin(Yaw) * Dist, L.Z + 100
local Half = math.rad(R.Yaw + 180) / 2
GS:RODSpawnActor(Cls, { Rotation = { X = 0, Y = 0, Z = math.sin(Half), W = math.cos(Half) },
  Translation = { X = X, Y = Y, Z = Z }, Scale3D = { X = 1, Y = 1, Z = 1 } },
  { IsStartBehaviorTree = true, Level = Lvl, InitialState = 0, IsDropItems = true, HeroNumber = 1 }, nil, nil, 1)
for Addr, E in pairs(List()) do
  if not Before[Addr] then
    local D = E.DefensiveAttributeSet
    local Spawned = string.format("level %d, HP %.0f", E.EnemyLevel, D.MaxHealth.CurrentValue)
    -- the spawner caps the level at the area's maximum: the enemy's own SetEnemyLevel, ignoring that cap
    if BOSS_FORCE_LEVEL and E.EnemyLevel ~= BOSS_FORCE_LEVEL then
      local Ok, Err = pcall(function() E:SetEnemyLevel(BOSS_FORCE_LEVEL, true) end)
      if not Ok then Spawned = Spawned .. ", level override failed: " .. tostring(Err) end
    end
    if BOSS_HP then   -- max and current HP straight onto its attribute set (and its HP bar)
      D.MaxHealth.CurrentValue, D.MaxHealth.BaseValue = BOSS_HP, BOSS_HP
      D.Health.CurrentValue, D.Health.BaseValue = BOSS_HP, BOSS_HP
      E:OnHealthChanged(BOSS_HP, BOSS_HP)
    end
    return string.format("spawned %s (spawner gave %s; now level %d, HP %.0f/%.0f) %.0f m in front of you", E:GetFName():ToString(),
      Spawned, E.EnemyLevel, D.Health.CurrentValue, D.MaxHealth.CurrentValue, Dist / 100)
  end
end
return "spawn call made, but no new enemy appeared in the game's list (level " .. tostring(Lvl) .. ")"
