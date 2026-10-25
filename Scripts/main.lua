-- NetDebug: the shipping build has engine logging compiled out, so record console commands and the
-- networking state ourselves. Each game instance writes its own file in Mods/NetDebug/.
local UEHelpers = require("UEHelpers")

-- The game's working directory is Binaries/Win64, so paths are relative to that.
math.randomseed(os.time() + math.floor(os.clock() * 1000000))
local Tag = tostring(math.random(1000, 9999))
local Stamp = os.date("%Y%m%d_%H%M%S") .. "_" .. Tag
local LogPath = "ue4ss/Mods/NetDebug/netdebug_" .. Stamp .. ".log"

local function Log(Message)
    local Line = string.format("[%s] %s", os.date("%H:%M:%S"), Message)
    print("[NetDebug#" .. Tag .. "] " .. Line .. "\n")
    local File = io.open(LogPath, "a")
    if File then
        File:write(Line .. "\n")
        File:close()
    end
end

local function Try(Fn, Fallback)
    local Ok, Result = pcall(Fn)
    if Ok and Result ~= nil then return Result end
    return Fallback
end

local function Name(Object)
    return Try(function()
        if Object and Object:IsValid() then return Object:GetFullName() end
    end, "nil")
end

-- Only the game thread runs Lua here: UE4SS's timers (ExecuteWithDelay, LoopAsync), key binds (RegisterKeyBind)
-- and new-object callbacks run theirs on other threads, and Lua run there alongside the game thread's crashes the
-- game. AfterSeconds is a one-off delay on the game thread.
local function AfterSeconds(Seconds, Fn)
    local At, Done, Handle = os.clock() + Seconds, false, nil
    Handle = LoopInGameThreadAfterFrames(5, function()
        if Done then return true end
        if os.clock() < At then return false end
        Done = true
        if Handle then pcall(CancelDelayedAction, Handle) end
        local Ok, Err = pcall(Fn)
        if not Ok then Log("error: " .. tostring(Err)) end
        return true
    end)
end

-- The world and local player controllers through the game instance (UEHelpers.GetWorld()/GetPlayerController()
-- and FindAllOf walk every object in the game).
local function CurrentWorld()
    local GI = UEHelpers.GetGameInstance()
    return GI:IsValid() and GI:GetWorld() or nil
end

local function LocalControllers()
    local Out, GI = {}, UEHelpers.GetGameInstance()
    if not GI:IsValid() then return Out end
    local LPs = GI.LocalPlayers
    for i = 1, #LPs do
        local LP = LPs[i]
        if type(LP) == "userdata" and not LP.IsValid and LP.get then LP = LP:get() end
        if LP and LP:IsValid() and LP.PlayerController and LP.PlayerController:IsValid() then Out[#Out + 1] = LP.PlayerController end
    end
    return Out
end

local function DumpState(Reason)
    Log("---- state (" .. Reason .. ") ----")
    local World = Try(CurrentWorld)
    Log("World: " .. Name(World))
    if not (World and World:IsValid()) then return end

    local Kismet = Try(function() return UEHelpers.GetKismetSystemLibrary() end)
    local Statics = Try(function() return UEHelpers.GetGameplayStatics() end)
    if Kismet and Kismet:IsValid() then
        Log(string.format("IsServer=%s IsStandalone=%s IsDedicatedServer=%s",
            tostring(Try(function() return Kismet:IsServer(World) end, "?")),
            tostring(Try(function() return Kismet:IsStandalone(World) end, "?")),
            tostring(Try(function() return Kismet:IsDedicatedServer(World) end, "?"))))
    end
    if Statics and Statics:IsValid() then
        Log("CurrentLevelName: " .. Try(function() return Statics:GetCurrentLevelName(World, false):ToString() end, "?"))
    end
    Log("World.NetDriver: " .. Try(function() return Name(World.NetDriver) end, "n/a"))
    Log("World.AuthorityGameMode: " .. Try(function() return Name(World.AuthorityGameMode) end, "n/a"))
    Log("World.OwningGameInstance: " .. Try(function() return Name(World.OwningGameInstance) end, "n/a"))

    local Controllers = Try(LocalControllers, {})
    Log("PlayerControllers: " .. #Controllers)
    for _, PC in ipairs(Controllers) do
        Log("   " .. Name(PC) .. "  Pawn=" .. Try(function() return Name(PC.Pawn) end, "?"))
    end
end

local function DumpNetDriverDefinitions()
    local Engine = FindFirstOf("GameEngine")
    if not (Engine and Engine:IsValid()) then Log("GameEngine not found") return end
    local Ok = pcall(function()
        local Defs = Engine.NetDriverDefinitions
        Log("NetDriverDefinitions: " .. #Defs)
        for i = 1, #Defs do
            local D = Defs[i]
            Log(string.format("   [%d] DefName=%s Driver=%s Fallback=%s", i,
                D.DefName:ToString(), D.DriverClassName:ToString(), D.DriverClassNameFallback:ToString()))
        end
    end)
    if not Ok then Log("NetDriverDefinitions: could not read") end
end

Log("NetDebug loaded, writing to " .. LogPath)

RegisterProcessConsoleExecPreHook(function(Context, Command, Parameters, OutputDevice, Executor)
    Log("console> " .. tostring(Command))
end)

RegisterInitGameStatePostHook(function(ContextParam)
    Log("InitGameState: " .. Try(function() return Name(ContextParam:get()) end, "?"))
    AfterSeconds(3, function() DumpState("3s after InitGameState") end)
end)

-- Live Lua: "lua <code>" runs code on the game thread; "luafile <path>" runs a file (path relative to
-- Binaries/Win64). Globals set by remote code persist in Repl between commands; print() goes to the log.
local Repl = setmetatable({}, { __index = _G })
Repl.Log, Repl.UEHelpers, Repl.DumpState, Repl.Tag = Log, UEHelpers, DumpState, Tag
-- Calling GetFName/methods on a null UObject crashes UE4SS natively (pcall can't catch it): use SafeName.
Repl.SafeName = function(O)
    if O == nil or type(O) ~= "userdata" or not O.IsValid or not O:IsValid() then return "null" end
    return O:GetFName():ToString()
end
Repl.print = function(...)
    local Parts = {}
    for i = 1, select("#", ...) do Parts[#Parts + 1] = tostring((select(i, ...))) end
    Log("lua: " .. table.concat(Parts, "\t"))
end

local function RunLua(Code, ChunkName)
    local Chunk, Err = load(Code, ChunkName or "remote", "t", Repl)
    if not Chunk then Log("lua compile error: " .. tostring(Err)) return end
    local Ok, Result = pcall(Chunk)
    if not Ok then
        Log("lua error: " .. tostring(Result))
    elseif Result ~= nil then
        Log("lua => " .. tostring(Result))
    end
end

local function ConsoleCommand(Cmd)
    UEHelpers.GetKismetSystemLibrary():ExecuteConsoleCommand(CurrentWorld(), Cmd, LocalControllers()[1])
end

-- Remote control (development only - on when ue4ss/Mods/NetDebug/remote.txt exists): write a console command
-- into ue4ss/Mods/NetDebug/cmd_<Tag>.txt and it runs here, checked about once a second on the game thread. The
-- special command "dump" logs the current state instead.
local CmdPath = "ue4ss/Mods/NetDebug/cmd_" .. Tag .. ".txt"
local function CheckRemote()
    local File = io.open(CmdPath, "r")
    if not File then return end
    local Cmd = File:read("*a")
    File:close()
    os.remove(CmdPath)
    Cmd = Cmd:gsub("^%s+", ""):gsub("%s+$", "")
    if Cmd == "" then return end
    Log("remote> " .. (#Cmd > 300 and (Cmd:sub(1, 300) .. " ...") or Cmd))
    if Cmd:sub(1, 4) == "lua " then
        RunLua(Cmd:sub(5))
        return
    end
    if Cmd:sub(1, 8) == "luafile " then
        local Path = Cmd:sub(9)
        local F = io.open(Path, "r")
        if not F then Log("luafile: cannot open " .. Path) return end
        local Code = F:read("*a")
        F:close()
        RunLua(Code, "@" .. Path)
        return
    end
    if Cmd == "dump" then
        DumpNetDriverDefinitions()
        DumpState("remote dump")
        return
    end
    local Ok, Err = pcall(ConsoleCommand, Cmd)
    if not Ok then Log("remote command failed: " .. tostring(Err)) end
end

do
    local F = io.open("ue4ss/Mods/NetDebug/remote.txt", "r")
    if F then
        F:close()
        local NextAt = 0
        LoopInGameThreadAfterFrames(10, function()
            if os.clock() >= NextAt then
                NextAt = os.clock() + 1
                local Ok, Err = pcall(CheckRemote)
                if not Ok then Log("remote: " .. tostring(Err)) end
            end
            return false
        end)
        Log("remote control on (" .. CmdPath .. ")")
    end
end

-- Console commands to run at startup, one per line in autoexec.txt (# starts a comment). Used for the
-- 1280x720 window (the game forces borderless fullscreen at startup) and to keep two copies light on the GPU.
local function RunAutoexec()
    local F = io.open("ue4ss/Mods/NetDebug/autoexec.txt", "r")
    if not F then return end
    for Line in F:lines() do
        local Cmd = Line:gsub("#.*$", ""):gsub("^%s+", ""):gsub("%s+$", "")
        if Cmd ~= "" then
            local Ok = pcall(ConsoleCommand, Cmd)
            Log("autoexec: " .. Cmd .. (Ok and "" or " (failed)"))
        end
    end
    F:close()
end

-- Start the co-op ghost sync automatically: the copy launched with the _P2 user dir is "B", the other "A".
local function AutoStartCoop()
    local SavedDir = UEHelpers.GetKismetSystemLibrary():GetProjectSavedDirectory():ToString()
    local Me = SavedDir:find("_P2", 1, true) and "B" or "A"
    -- coop_role.txt ("A" host / "B" guest) overrides that, e.g. on a second PC
    local R = io.open("ue4ss/Mods/NetDebug/coop_role.txt", "r")
    if R then
        local Role = (R:read("*l") or ""):gsub("%s", "")
        R:close()
        if Role == "A" or Role == "B" then Me = Role end
    end
    local Peer = Me == "A" and "B" or "A"
    -- coop_transport.txt: "link" = talk through coop_link.py over UDP, "steam" = through coop_steam.py (Steam lobby
    -- + relay), otherwise same-PC files
    local Transport = "file"
    local T = io.open("ue4ss/Mods/NetDebug/coop_transport.txt", "r")
    if T then
        local V = ((T:read("*l") or ""):gsub("%s", ""))
        Transport = (V == "link" or V == "steam") and V or "file"
        T:close()
    end
    local F = io.open("ue4ss/Mods/NetDebug/coop.lua", "r")
    if not F then return end
    local Code = F:read("*a")
    F:close()
    RunLua(Code, "@coop.lua")
    if Transport == "steam" then return end   -- (co-op starts from the bedroom menu or a Steam invite, lobby.lua)
    RunLua(string.format('Coop.Start("%s", "%s", "%s")', Me, Peer, Transport))
end

AfterSeconds(15, function()
    RunAutoexec()
    AutoStartCoop()
    DumpNetDriverDefinitions()
    DumpState("startup")
end)
