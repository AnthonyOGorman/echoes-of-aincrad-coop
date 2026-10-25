-- teleport this copy's hero next to the town's main terminal (the Large Teleport Gate orb), facing it.
-- TP_ANGLE (degrees, set before running) picks the side so two copies don't land on each other.
local PC = UEHelpers.GetPlayerController()
local Hero = PC and PC.Pawn
if not (Hero and Hero:IsValid()) then return "no hero" end
local Gate
for _, G in ipairs(FindAllOf("BP_TeleportGate_C") or {}) do
  if G:IsValid() and not G:GetFullName():find("Default__") then Gate = G break end
end
local C = Gate and Gate:K2_GetActorLocation() or { X = 53410, Y = 380125, Z = 27271 }
local Base = TP_ANGLE or 0
for _, Ring in ipairs({ 350, 500, 700 }) do
  for k = 0, 11 do
    local A = math.rad(Base + k * 30)
    local Spot = { X = C.X + math.cos(A) * Ring, Y = C.Y + math.sin(A) * Ring, Z = C.Z + 120 }
    local Yaw = math.deg(math.atan(C.Y - Spot.Y, C.X - Spot.X))
    if Hero:K2_TeleportTo(Spot, { Pitch = 0, Yaw = Yaw, Roll = 0 }) then
      return string.format("teleported to %.0f %.0f %.0f (%s, ring %d, angle %d)", Spot.X, Spot.Y, Spot.Z,
        Gate and Gate:GetFName():ToString() or "saved spot", Ring, Base + k * 30)
    end
  end
end
return "no clear spot near the terminal"
