-- read-only: enemy blueprint classes by folder, from the asset registry (no loading)
local AR = StaticFindObject("/Script/AssetRegistry.Default__AssetRegistryHelpers"):GetAssetRegistry()
local Found = {}
AR:GetAssetsByPath(FName("/Game/ROD/Blueprints/Characters/Enemies"), Found, true, false)
local Folders, Order = {}, {}
for i = 1, #Found do
  local A = Found[i]
  if A.get then A = A:get() end
  local Name, Path = A.AssetName:ToString(), A.PackagePath:ToString()
  if Name:find("^BP_E%d") then
    local Folder = Path:match("/Enemies/([^/]+)") or Path
    if not Folders[Folder] then Folders[Folder] = {}; Order[#Order + 1] = Folder end
    table.insert(Folders[Folder], Name)
  end
end
table.sort(Order)
local Out = {}
for _, F in ipairs(Order) do Out[#Out + 1] = F .. ": " .. table.concat(Folders[F], ",") end
return #Out .. " folders | " .. table.concat(Out, " | ")
