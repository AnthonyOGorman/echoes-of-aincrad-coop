"""Build the player package: UE4SS + the co-op mod, laid out to extract into the game's install folder.
Usage: python tools/make_package.py [out.zip]   (default: EchoesOfAincrad_Coop.zip on the Desktop)
Takes UE4SS and the embedded Python from this install (this file is in <Win64>/ue4ss/Mods/NetDebug/tools)."""
import os, sys, zipfile

WIN64 = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), *[".."] * 4))
OUT = sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.expanduser("~"), "Desktop", "EchoesOfAincrad_Coop.zip")
ROOT = "EchoesofAincrad/Binaries/Win64/"

MOD_FILES = ["enabled.txt", "Scripts/main.lua", "coop.lua", "ghost2.lua", "enemies.lua", "loot.lua", "hud.lua",
             "revive.lua", "party.lua", "proxy.lua", "lobby.lua", "quests.lua", "coop_steam.py",
             "coop_transport.txt", "coop_loot.txt"]
# (NetDebug loads through its own enabled.txt; none of UE4SS's sample mods are used)
MODS_TXT = "; The co-op mod (NetDebug) is enabled by its own enabled.txt.\n"
MODS_JSON = "[]\n"

entries = []
def add(src, arc):
    if not os.path.isfile(src):
        sys.exit(f"missing: {src}")
    entries.append((src, ROOT + arc))

def add_tree(src_dir, arc_dir, skip=("__pycache__",)):
    for dirpath, dirnames, filenames in os.walk(src_dir):
        dirnames[:] = [d for d in dirnames if d not in skip]
        for f in filenames:
            if f.endswith(".pyc"):
                continue
            full = os.path.join(dirpath, f)
            rel = os.path.relpath(full, src_dir).replace(os.sep, "/")
            add(full, arc_dir + "/" + rel)

add(os.path.join(WIN64, "dwmapi.dll"), "dwmapi.dll")
for f in ("UE4SS.dll", "UE4SS-settings.ini", "LICENSE"):
    add(os.path.join(WIN64, "ue4ss", f), "ue4ss/" + f)
add_tree(os.path.join(WIN64, "ue4ss", "UE4SS_Signatures"), "ue4ss/UE4SS_Signatures")
add_tree(os.path.join(WIN64, "ue4ss", "UE4SS_SDK_Backends"), "ue4ss/UE4SS_SDK_Backends")
add_tree(os.path.join(WIN64, "ue4ss", "Mods", "shared"), "ue4ss/Mods/shared")
nd = os.path.join(WIN64, "ue4ss", "Mods", "NetDebug")
for f in MOD_FILES:
    add(os.path.join(nd, f), "ue4ss/Mods/NetDebug/" + f)
add_tree(os.path.join(nd, "python"), "ue4ss/Mods/NetDebug/python")

with zipfile.ZipFile(OUT, "w", zipfile.ZIP_DEFLATED, compresslevel=9) as z:
    for src, arc in entries:
        z.write(src, arc)
    z.writestr(ROOT + "ue4ss/Mods/mods.txt", MODS_TXT)
    z.writestr(ROOT + "ue4ss/Mods/mods.json", MODS_JSON)

total = sum(os.path.getsize(s) for s, _ in entries)
print(f"{len(entries) + 2} files, {total / 1e6:.1f} MB uncompressed, zip {os.path.getsize(OUT) / 1e6:.1f} MB -> {OUT}")
