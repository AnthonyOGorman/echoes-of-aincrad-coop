-- kill every live enemy of class KILL_CLASS (e.g. "BP_E016001_C") the way the mod kills: HP 0, then the death
local PC = Coop.LocalPC()
local Hero = PC and PC.Pawn
local GS = PC:GetWorld().GameState
local A, Killed = GS.RODEnemies, {}
for i = 1, #A do
  local E = A[i]
  if type(E) == "userdata" and not E.IsValid and E.get then E = E:get() end
  if E and E:IsValid() and E:GetClass():GetFName():ToString() == KILL_CLASS and E.EnemyStateValue < 19 and not E.bHidden then
    local D = E.DefensiveAttributeSet
    D.Health.CurrentValue, D.Health.BaseValue = 0, 0
    E:OnHealthChanged(0, D.MaxHealth.CurrentValue)
    Enemies.PlayReaction(E, Hero, nil, true)
    Killed[#Killed + 1] = E:GetFName():ToString()
  end
end
return #Killed > 0 and ("killed " .. table.concat(Killed, ", ")) or ("no live " .. KILL_CLASS)
