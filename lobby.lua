-- Multiplayer point in the Town of Beginnings bedroom (every save resumes there). A copy of the game's own
-- database-book gimmick stands by the fireplace with the room action (EValuableActionKind MenuRoom), so the game
-- shows its "(V) Access" prompt and the book's own logic ignores the press. V there opens the game's hidden
-- Rule Select menu (Solo Play / Create Room / Join Room). The game's online code behind that menu needs servers
-- that don't exist, so the menu's own confirm / back are switched off and this file handles them: the game's
-- navigation moves between the rows, Space/Enter (gamepad A) confirm, Esc (gamepad B) closes. Create Room starts
-- co-op as the host, Join Room as the guest, Solo Play stops it - over Steam (a lobby + Steam's relay, see the
-- Steam section) or the LAN link. Runs its own loop (co-op may be stopped). Loaded by coop.lua; shares its
-- environment.

Lobby = Lobby or {}
Lobby.Spot = { X = 54741, Y = 362204, Z = 27670, Yaw = -89 }   -- bedroom, in front of the fireplace
-- (a game that has just started leaves a room its helper is still in from before - the helper outlives a crashed
-- or closed game while another copy runs - so every game starts solo, and rooms are made / joined at the book)
if Lobby.NewGame == nil then Lobby.NewGame = true end

local TownMap = "PL_TOB"
local PointPath = "/Game/ROD/Blueprints/Placement/Gimmick/DataBase/BP_DataBaseGimmick.BP_DataBaseGimmick_C"
local MenuPath = "/Game/ROD/Widget/OutGame/SeveDataSelect/WBP_TitleMenu_SaveDataSelect_RuleSelect.WBP_TitleMenu_SaveDataSelect_RuleSelect_C"
local RoomAction = 3   -- EValuableActionKind::MenuRoom
local RuleSelectKind = 11   -- EMenuKind::StartRuleSelect
local Solo, Create, Join = 0, 1, 2   -- the menu's rows

local function Valid(O) return O ~= nil and O:IsValid() end

local function Get(X)
    if type(X) == "userdata" and not X.IsValid and X.get then return X:get() end
    return X
end

local Cache = {}
-- (looked up each time - cheap, see Coop.LocalPC - so it's always the current map's)
local function Controller() return Coop.LocalPC() end

-- Objects kept here belong to one map. A new map (its GameState, by name: a new one can sit at the old one's
-- address, and so can any object) drops them - the point, an open menu.
local function CheckMap()
    local PC = Controller()
    if not PC then return end
    local GS = PC:GetWorld().GameState
    local Key = Valid(GS) and GS:GetFullName() or ""
    if Key ~= Lobby.MapKey then
        Lobby.MapKey = Key
        Lobby.Point, Lobby.PointAddr, Lobby.Menu = nil, nil, nil
    end
end

local function MenuLibrary()
    if not Valid(Cache.Lib) then Cache.Lib = StaticFindObject("/Script/ROD.Default__RODWidgetBPFunctionLibrary") end
    return Cache.Lib
end

local function LoadClass(Path)
    local C = StaticFindObject(Path)
    if not Valid(C) then C = LoadAsset(Path) end
    return Valid(C) and C or nil
end

---------------------------------------------------------------------------------------------------------------
-- The point

local function EnsurePoint(PC)
    if Valid(Lobby.Point) then return end
    local W = PC:GetWorld()
    if not (Valid(W) and W:GetFName():ToString() == TownMap) then return end
    local Cls = LoadClass(PointPath)
    if not Cls then return end
    local S = Lobby.Spot
    local P = W:SpawnActor(Cls, { X = S.X, Y = S.Y, Z = S.Z }, { Pitch = 0, Yaw = S.Yaw, Roll = 0 })
    if not Valid(P) then Log("lobby: multiplayer point spawn failed") return end
    P.StateParams[1].OpParams[1].Operation = RoomAction
    Lobby.Point, Lobby.PointAddr = P, P:GetAddress()
    Log("lobby: multiplayer point placed in the bedroom")
end

-- V at the point: the game calls the gimmick's MulticastOperated with the point's action. Only noted here; the
-- loop opens the menu.
if not Lobby.Hooked then
    Lobby.Hooked = pcall(RegisterHook, "/Script/ROD.RODGimmickBase:MulticastOperated", function(Ctx, Operator, Op)
        local G = Ctx:get()
        if Lobby.PointAddr and Valid(G) and G:GetAddress() == Lobby.PointAddr and Op:get() == RoomAction then
            Lobby.OpenAt = os.clock()
        end
    end)
end

---------------------------------------------------------------------------------------------------------------
-- The menu

-- Moving through the rows is the game's own menu navigation (keyboard or gamepad). The menu's confirm / back
-- actions are switched off (they'd run its online code); the presses are read here, on the game thread, from the
-- menu's own button state (Accept / Back), or from the player controller's key state. (Not RegisterKeyBind: its
-- callbacks run on UE4SS's own thread, and Lua touched from two threads at once crashed the game.)
local Keys = {
    Ok = { { KeyName = FName("SpaceBar") }, { KeyName = FName("Enter") }, { KeyName = FName("Gamepad_FaceButton_Bottom") } },
    Back = { { KeyName = FName("Escape") }, { KeyName = FName("Gamepad_FaceButton_Right") } },
    Left = { { KeyName = FName("Left") }, { KeyName = FName("A") }, { KeyName = FName("Gamepad_DPad_Left") } },
    Right = { { KeyName = FName("Right") }, { KeyName = FName("D") }, { KeyName = FName("Gamepad_DPad_Right") } },
}
-- EInputButtonKindInWidget: Virtual_Accept / Virtual_Back / Virtual_DPad_Right / Virtual_DPad_Left
local MenuButtons = { Ok = 1, Back = 2, Right = 15, Left = 16 }

-- Room privacy: Create Room's switch (left / right), and the host's room menu (a Steam room switches between
-- friends only and open to all; a LAN room has no Steam lobby and stays LAN)
Lobby.Privacy = Lobby.Privacy or "friends"
local PrivacyOrder = { "friends", "public", "lan" }
local PrivacyLabel = { friends = "Friends Only", public = "Open to All", lan = "LAN" }
local PrivacyDetail = { friends = "Only your Steam friends can see and join it.", public = "Anyone with the co-op mod can find and join it.",
                        lan = "Players on your local network (or this PC) can find and join it." }
local function NextPrivacy(P, Step)
    local I = 1
    for i, X in ipairs(PrivacyOrder) do if X == P then I = i end end
    return PrivacyOrder[(I - 1 + Step) % #PrivacyOrder + 1]
end
local Current, CurrentInactive, Inactive = 2, 7, 5   -- EMenuItemState

local function KeyDown(PC, Action, M)
    for _, K in ipairs(Keys[Action]) do
        if PC:IsInputKeyDown(K) then return true end
    end
    if M then
        for _, X in ipairs({ M.Widget, M.List or M.Widget, M.List2 or M.Widget }) do
            local Ok, Down = pcall(function() return X:IsInputPressed(MenuButtons[Action]) end)
            if Ok and Down then return true end
        end
    end
    return false
end

-- an action whose key went down since the last check
local function Pressed(PC, Action, M)
    local Down = KeyDown(PC, Action, M)
    local Was = Lobby.KeyState[Action]
    Lobby.KeyState[Action] = Down
    return Down and not Was
end

-- The row the game's navigation is on.
local function CurrentRow(M)
    for i, It in ipairs(M.Items) do
        local S = It.MenuItemState
        if S == Current or S == CurrentInactive then return i - 1 end
    end
    return M.Index
end

-- Create Room / Join Room look greyed out (the game is offline). Un-greyed once the menu has finished opening,
-- and redrawn by passing the focus over every row (the rows redraw on focus changes), ending on row I. Redone
-- whenever the game's navigation greys them again.
local function Ungrey(M, I)
    for i = 2, #M.Items do
        local It = M.Items[i]
        It:SetInactive(true)
        It:SetInactive(false)
    end
    for _, It in ipairs(M.Items) do M.List:FocusEvent(It) end
    M.List:FocusEvent(M.Items[I + 1])
    M.Index = I
    if M.ApplyLabels then M.ApplyLabels(M) end   -- (this menu's own row texts, after the redraw)
end

local function Greyed(M)
    for _, It in ipairs(M.Items) do
        local S = It.MenuItemState
        if S == Inactive or S == CurrentInactive then return true end
    end
    return false
end

-- The room menu is the same menu with its rows relabelled: each row's text widgets (RuleText / RuleDetailText /
-- SwitchText) and the menu title, found once when it opens.
local function MenuTexts(W, Items)
    local ByAddr, Rows, Title = {}, {}, nil
    for i, It in ipairs(Items) do ByAddr[It:GetAddress()] = i; Rows[i] = {} end
    local Header = Valid(W.TitleHeader) and W.TitleHeader:GetAddress() or nil
    for _, T in ipairs(FindAllOf("TextBlock") or {}) do
        if T:IsValid() then
            local O, k = T:GetOuter(), 0
            while O and O:IsValid() and k < 6 do
                local A = O:GetAddress()
                if ByAddr[A] then Rows[ByAddr[A]][T:GetFName():ToString()] = T break end
                if A == Header then
                    if T:GetText():ToString():find("mode") then Title = T end
                    break
                end
                O, k = O:GetOuter(), k + 1
            end
        end
    end
    return Rows, Title
end

-- M.Labels = { { title, detail, switch }, ... } written into the rows
local function ApplyLabels(M)
    if not M.Labels then return end
    for i, L in ipairs(M.Labels) do
        local T = M.Texts[i]
        if T then
            if T.RuleText then T.RuleText:SetText(FText(L[1])) end
            if T.RuleDetailText then T.RuleDetailText:SetText(FText(L[2])) end
            if T.SwitchText then T.SwitchText:SetText(FText(L[3])) end
        end
    end
end

-- Solo / Create / Join: Create Room's switch shows the room privacy
local function ApplyRuleLabels(M)
    local T = M.Texts[Create + 1]
    if not T then return end
    if T.SwitchText then T.SwitchText:SetText(FText(PrivacyLabel[Lobby.Privacy])) end
    if T.RuleDetailText then
        T.RuleDetailText:SetText(FText("Create your own room and start playing as the host.\n" .. PrivacyDetail[Lobby.Privacy]))
    end
end

-- Mode "rules" (Solo Play / Create Room / Join Room) or "room" (the room you're in: remove the other player / close
-- or leave it; filled by the Steam section). (Join Room's room browser is the game's Room Select, OpenBrowser.)
local function OpenMenu(PC, Mode)
    if Lobby.Menu then return end
    local Cls, Lib = LoadClass(MenuPath), MenuLibrary()
    if not (Cls and Valid(Lib)) then return end
    local W = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(PC, Cls, PC)
    if not Valid(W) then return end
    W.MenuKind = RuleSelectKind
    W.bIsOffline, W.bIsOnlinePlay, W.bIsPlayWithFriend = false, true, true
    Lib:DebugOpenMenu(PC, W)   -- (pushed on the game's menu stack: the game pauses play input while it's open)
    W:InitializeMenuWidget()
    W:OpenedMenu()
    pcall(function() W.WarningMessage:SetVisibility(1) end)   -- ("You are in offline mode")
    local Items, Rows = {}, W.ListViewItemWidgets
    for i = 1, #Rows do Items[i] = Get(Rows[i]) end
    Lib:SetCurrentMenuInputActionEnable(PC, false)
    Lobby.Menu = { Widget = W, List = W.RuleList, Items = Items, Index = Create, OpenedFrame = Lobby.Frame, Mode = Mode }
    local M = Lobby.Menu
    M.Texts, M.Title = MenuTexts(W, Items)
    if Mode == "rules" then
        M.ApplyLabels = ApplyRuleLabels
    else
        M.Index, M.ApplyLabels = 0, ApplyLabels
        local Title = FText("Your co-op room.")
        if M.Title then M.Title:SetText(Title) end
        pcall(function() W.Message_Text:SetText(Title) end)   -- (the blue bar: "Select a game mode.")
    end
    Lobby.KeyState = {}
    for Action in pairs(Keys) do Lobby.KeyState[Action] = KeyDown(PC, Action, Lobby.Menu) end   -- (keys already held don't count)
    Log("lobby: " .. (Mode == "room" and "room menu" or "multiplayer menu") .. " opened")
end

local function CloseMenu(PC)
    local M = Lobby.Menu
    Lobby.Menu = nil
    local Lib = MenuLibrary()
    if Valid(Lib) then
        pcall(function() Lib:SetCurrentMenuInputActionEnable(PC, true) end)
        if M and Valid(M.Widget) then pcall(function() Lib:EndMenu(PC) end) end
    end
end

---------------------------------------------------------------------------------------------------------------
-- Steam (coop_transport.txt = steam): coop_steam.py finds the other player through a Steam lobby and carries the
-- co-op traffic over Steam's relay (the same link files as the LAN link). It's started from here, hidden, with
-- the Python bundled in python\ (else the one on PATH). The menu's choices go to it through steam_cmd.txt; its
-- steam_status.txt says what it's doing.

local Dir = "ue4ss/Mods/NetDebug/"
local SteamApp = 2244210   -- Echoes of Aincrad (480 = Valve's test app, any account can use it)

-- A second copy on this PC (the _P2 save folder) keeps its own Steam files and helper.
local function CopyTag()
    if Lobby.Tag == nil then
        local Ok, Saved = pcall(function() return UEHelpers.GetKismetSystemLibrary():GetProjectSavedDirectory():ToString() end)
        Lobby.Tag = (Ok and Saved:find("_P2", 1, true)) and "_P2" or ""
    end
    return Lobby.Tag
end

local function ReadFile(Path)
    local F = io.open(Path, "r")
    if not F then return nil end
    local S = F:read("a")
    F:close()
    return S
end

local function SteamStatus()
    local S = ReadFile(Dir .. "steam_status" .. CopyTag() .. ".txt")
    if not S then return nil end
    local T = {}
    for K, V in S:gmatch("([%w_]+)=([^\n]*)") do T[K] = V end
    return T
end

local function SteamCommand(Cmd)
    local F = io.open(Dir .. "steam_cmd" .. CopyTag() .. ".txt", "w")
    if F then F:write(Cmd) F:close() end
end

local function StartSteamHelper()
    local WinDir = (Dir:gsub("/", "\\"))
    local Exe = "pythonw"
    local F = io.open(Dir .. "python/pythonw.exe", "rb")
    if F then F:close() Exe = WinDir .. "python\\pythonw.exe" end
    local Tag = CopyTag() ~= "" and (" --tag " .. CopyTag()) or ""
    os.execute(string.format('start "" "%s" "%scoop_steam.py" --app %d%s', Exe, WinDir, SteamApp, Tag))
end

local function SteamRooms()
    local S = ReadFile(Dir .. "steam_rooms" .. CopyTag() .. ".txt")
    if not S then return nil end
    local T = { Time = tonumber(S:match("time=([%d%.]+)")) or 0, Rooms = {} }
    -- room=<lobby id>|<players>|<host's Steam name>|<character>|<friends/public>|<level>|<story progress>|<difficulty>
    for Line in S:gmatch("room=([^\n]*)") do
        local F = {}
        for X in (Line .. "|"):gmatch("([^|]*)|") do F[#F + 1] = X end
        T.Rooms[#T.Rooms + 1] = { Id = F[1], Players = tonumber(F[2]) or 1, Host = F[3] or "?", Hero = F[4] or "",
                                  Type = F[5], Level = tonumber(F[6]), Story = tonumber(F[7]), Difficulty = tonumber(F[8]) }
    end
    return T
end

---------------------------------------------------------------------------------------------------------------
-- The room browser: the game's own Room Select (host, level, story chapter, room status, players), filled with
-- the rooms the helper finds. Its left column picks which: Friends Only (friends' rooms), Open to All (open
-- rooms, by their search tag), LAN (the game's Quick Match row, relabelled: LAN rooms). The game builds the table from a "friend
-- rooms received" response; UE4SS can't pass that nested struct from Lua (the game gets an empty one), so the
-- handler is called with nothing and a pre-hook fills the response it's about to read.

local BrowserPath = "/Game/ROD/Widget/OutGame/SeveDataSelect/WBP_TitleMenu_SaveDataSelect_RoomSelect.WBP_TitleMenu_SaveDataSelect_RoomSelect_C"
local RoomSelectKind = 13   -- EMenuKind::RoomSelect
local SearchKinds = { [0] = "friends", [1] = "public", [2] = "lan" }   -- the left column's rows

if not Lobby.FeedHooked then
    Lobby.FeedHooked = pcall(RegisterHook, "/Script/ROD.RODRoomSelectMenuWidget:OnRequestSaerchFriendRoomReceived", function(Ctx, Resp)
        local Rooms = Lobby.FeedRooms
        if not Rooms then return end
        Lobby.FeedRooms = nil
        local R = Resp:get()
        R.Result = true
        for i, Room in ipairs(Rooms) do R.Rooms[i] = Room end
    end)
end

-- a room as the game's FLobbyRoomInfo
local function RoomInfo(R)
    return { ID = R.Id, RoomType = R.Type == "friends" and 2 or 1, MaxPlayers = 2, NumPlayers = R.Players,
             HostPlayer = { ID = R.Id, AccountId = R.Id, CharName = R.Hero ~= "" and R.Hero or R.Host, AccountName = R.Host,
                            Level = R.Level or 1, StoryProgress = R.Story or 0, Difficulty = R.Difficulty or 2 } }
end

local function OpenBrowser(PC)
    local Cls, Lib = LoadClass(BrowserPath), MenuLibrary()
    if not (Cls and Valid(Lib)) then return end
    local W = StaticFindObject("/Script/UMG.Default__WidgetBlueprintLibrary"):Create(PC, Cls, PC)
    if not Valid(W) then return end
    W.MenuKind = RoomSelectKind
    Lib:DebugOpenMenu(PC, W)
    W:InitializeMenuWidget()
    W:OpenedMenu()
    Lib:SetCurrentMenuInputActionEnable(PC, false)   -- (its own Search / Confirm would go to the game's servers)
    Lobby.Menu = { Widget = W, List = W.SearchList, List2 = W.RoomList, Mode = "browser", OpenedFrame = Lobby.Frame, Rooms = {} }
    Lobby.KeyState = {}
    for Action in pairs(Keys) do Lobby.KeyState[Action] = KeyDown(PC, Action, nil) end
    Log("lobby: room browser opened")
end

local function BrowserSearch(M, Kind)
    M.Kind, M.ListAt = Kind, os.time()
    SteamCommand("list " .. Kind)
    Log("lobby: looking for rooms (" .. Kind .. ")")
end

-- The left column's third row is the game's Quick Match: it reads "LAN" here (its text found once, and put back
-- if the game redraws it); the quick match notice under the list stays hidden.
local function LabelLanRow(M)
    if not Valid(M.LanText) then
        M.LanText, M.LanTries = nil, (M.LanTries or 0) + 1
        if M.LanTries > 5 then return end   -- (not found: leave the row as it is)
        local Rows = M.Widget.SearchTypeListItemWidgets
        local Row = Rows and #Rows >= 3 and Get(Rows[3]) or nil
        if not Valid(Row) then return end
        local RA, First = Row:GetAddress(), nil
        for _, T in ipairs(FindAllOf("TextBlock") or {}) do
            if T:IsValid() then
                local O, n = T:GetOuter(), 0
                while O and O:IsValid() and n < 5 do
                    if O:GetAddress() == RA then
                        local S = T:GetText():ToString()
                        if S:find("Quick") then M.LanText = T elseif S ~= "" then First = First or T end
                        break
                    end
                    O, n = O:GetOuter(), n + 1
                end
            end
        end
        M.LanText = M.LanText or First
        if not M.LanText then return end
    end
    if M.LanText:GetText():ToString() ~= "LAN" then M.LanText:SetText(FText("LAN")) end
    pcall(function() M.Widget.QuickMessage:SetVisibility(1) end)
end

-- the browser's list rows (search kinds and rooms) that belong to this menu, with their state; and for the
-- current room row, the host names shown in it
local function BrowserFocus(M)
    local WA, Search, Room = M.Widget:GetAddress(), nil, nil
    for _, X in ipairs(FindAllOf("RODMenuItemWidgetBase") or {}) do
        if X:IsValid() and (X.MenuItemState == Current or X.MenuItemState == CurrentInactive) then
            local O, n = X:GetOuter(), 0
            while O and O:IsValid() and n < 8 do
                if O:GetAddress() == WA then
                    local Cls = X:GetClass():GetFName():ToString()
                    if Cls:find("RoomSearch") then Search = X elseif Cls:find("ListItem_Room") then Room = Room or { Item = X } end
                    break
                end
                O, n = O:GetOuter(), n + 1
            end
        end
    end
    if Search then return { Search = SearchKinds[Search.ItemIndex] } end
    if Room then   -- (the host's character and Steam names in the row; a row with none is the empty template)
        local RA = Room.Item:GetAddress()
        for _, T in ipairs(FindAllOf("TextBlock") or {}) do
            if T:IsValid() then
                local O, n = T:GetOuter(), 0
                while O and O:IsValid() and n < 5 do
                    if O:GetAddress() == RA then
                        local N = T:GetFName():ToString()
                        if N == "NameText" then Room.Hero = T:GetText():ToString() elseif N == "ProfileText" then Room.Host = T:GetText():ToString() end
                        break
                    end
                    O, n = O:GetOuter(), n + 1
                end
            end
        end
        local function Shows(R) return R and R.Host == Room.Host and (R.Hero ~= "" and R.Hero or R.Host) == Room.Hero end
        local R = M.Rooms[(Room.Item.ItemIndex or -1) + 1]   -- (by its place first: rooms can show the same names)
        if Shows(R) then return { Room = R } end
        for _, R in ipairs(M.Rooms) do
            if Shows(R) then return { Room = R } end
        end
    end
    return {}
end

local function JoinRoom(PC, R)
    CloseMenu(PC)
    Log("lobby: joining " .. R.Host .. "'s room")
    SteamCommand("join " .. R.Id)   -- (co-op starts once the helper reports the room joined)
end

-- The room you're in (host: who's in it, remove them, close it; guest: leave it), from the helper's status.
local function FillRoomMenu(M)
    local St = Lobby.SteamStatus or {}
    local PeerName = (St.peer or ""):match("^[1-9]%d* (.+)$")
    if St.role == "A" then
        local Privacy = PrivacyLabel[St.type] and St.type or Lobby.Privacy
        M.Entries = { { Privacy = Privacy ~= "lan" }, PeerName and { Kick = true } or {}, { Close = true } }
        M.Labels = { { "Your room", (PeerName and (PeerName .. " is playing with you") or "Waiting for a player to join")
                       .. " (" .. (PeerName and "2" or "1") .. " / 2)\n" .. PrivacyDetail[Privacy], PrivacyLabel[Privacy] },
                     PeerName and { "Remove " .. PeerName, "Send them back to playing solo", "" } or { "No one to remove", "", "" },
                     { "Close Room", "End the room and play solo", "" } }
    else
        local Host = PeerName or "the host"
        M.Entries = { {}, { Leave = true }, {} }
        M.Labels = { { Host .. "'s room", "You are a guest in " .. Host .. "'s room", "2 / 2" },
                     { "Leave Room", "Go back to playing solo", "" }, { "", "", "" } }
    end
    M.ApplyLabels(M)
end

local function CoopRunning(Me) return Coop.Handles and #Coop.Handles > 0 and (not Me or Coop.Me == Me) end

local function StartCoop(Me, Peer)
    if CoopRunning() then Coop.Stop() end
    Coop.Start(Me, Peer, Coop.Transport or "link")
end

-- Once a second: keep the helper running, report what it's doing, and follow a room joined through Steam itself
-- (an accepted invite / "Join game" on the friends list) by starting co-op as the guest.
local function UpdateSteam()
    if Lobby.SteamMode == nil then Lobby.SteamMode = (ReadFile(Dir .. "coop_transport.txt") or ""):match("^%s*steam") ~= nil end
    if not Lobby.SteamMode then return end
    -- (the helper rewrites its status twice a second; a read can miss it mid-replace, so it only counts as gone
    -- when nothing fresh has been seen for 10 s)
    local St = SteamStatus()
    local Fresh = St and tonumber(St.time) and os.time() - tonumber(St.time) < 5
    if Fresh then Lobby.HelperSeenAt = os.clock() end
    if not Lobby.HelperSeenAt or os.clock() - Lobby.HelperSeenAt > 10 then
        if not Lobby.HelperStartedAt or os.clock() - Lobby.HelperStartedAt > 30 then
            Lobby.HelperStartedAt = os.clock()
            Log("lobby: starting the Steam helper")
            StartSteamHelper()
        end
        return
    end
    if not Fresh then return end
    Lobby.SteamStatus = St
    if Lobby.NewGame then
        Lobby.NewGame = false
        if St.role == "A" or St.role == "B" then
            Log("lobby: left the room the helper was still in from before this game started - start or join one at the book")
            SteamCommand("leave")
            St.role, St.state = "-", "idle"
            if CoopRunning() then Coop.Stop() end
            return
        end
    end
    local Now = (St.state or "") .. "|" .. (St.role or "") .. "|" .. (St.peer or "")
    if Now ~= Lobby.SteamSeen then
        Lobby.SteamSeen = Now
        Log(string.format("lobby: steam %s, role %s, peer %s (%s)", St.state or "?", St.role or "?", St.peer or "?", St.note or ""))
    end
    -- (after a choice at the book, the status written before the helper acted on it is old news: wait for the
    -- role the choice leads to, or a few seconds)
    local E = Lobby.Expect
    if E then
        if St.role ~= E.Role and os.clock() < E.Until then return end
        Lobby.Expect = nil
    end
    local InRoom = St.role == "A" or St.role == "B"
    if (St.state == "kicked" or St.state == "host-left") and CoopRunning("B") then
        Log(St.state == "kicked" and "lobby: the host removed you from the room - co-op off" or "lobby: the host closed the room - co-op off")
        Coop.Stop()
    elseif not InRoom and CoopRunning() then
        Log("lobby: not in a room any more - co-op off")
        Coop.Stop()
    elseif St.role == "B" and not CoopRunning("B") then
        Log("lobby: joined a room - co-op as the guest")
        StartCoop("B", "A")
    elseif St.role == "A" and not CoopRunning("A") then   -- (co-op stopped by a reload of coop.lua)
        Log("lobby: still hosting a Steam room - co-op as the host")
        StartCoop("A", "B")
    end
end

local function Choose(PC, M)
    local Row = M.Index
    if M.Mode == "room" then
        local E = M.Entries and M.Entries[Row + 1] or {}
        if E.Kick then
            Log("lobby: removing the other player from the room")
            SteamCommand("kick")
        elseif E.Close or E.Leave then
            Log(E.Close and "lobby: closing the room - co-op off" or "lobby: leaving the room - co-op off")
            SteamCommand("leave")
            Lobby.Expect = { Role = "-", Until = os.clock() + 5 }
            if CoopRunning() then Coop.Stop() end
        else
            return
        end
        CloseMenu(PC)
        return
    end
    if M.Mode == "browser" then
        local F = BrowserFocus(M)
        if F.Search then BrowserSearch(M, F.Search)
        elseif F.Room then JoinRoom(PC, F.Room) end
        return
    end
    CloseMenu(PC)
    if Row == Create then
        Log("lobby: Create Room (" .. PrivacyLabel[Lobby.Privacy] .. ") - hosting")
        if Lobby.SteamMode then   -- (with what the room lists show: level, story progress, difficulty, character)
            local Info = { 1, 0, 2, "" }
            pcall(function()
                local D = FindFirstOf("RODSaveLoadSubsystem").CurrentSaveGame.CharacterSaveData[1]
                Info = { D.Level, D.MainStoryProgress, D.DifficultyLevel, Info[4] }
            end)
            pcall(function() Info[4] = PC.PlayerState:GetPlayerName():ToString() end)
            SteamCommand(string.format("create %s %d %d %d %s", Lobby.Privacy, Info[1], Info[2], Info[3], Info[4]))
            Lobby.Expect = { Role = "A", Until = os.clock() + 15 }
        end
        StartCoop("A", "B")
    elseif Row == Join then
        if Lobby.SteamMode then
            Lobby.OpenAt, Lobby.OpenMode = os.clock() + 0.3, "browser"   -- (once this menu has closed)
        else
            Log("lobby: Join Room - joining the host")
            StartCoop("B", "A")
        end
    else
        Log("lobby: Solo Play - co-op off")
        if Lobby.SteamMode then
            SteamCommand("leave")
            Lobby.Expect = { Role = "-", Until = os.clock() + 5 }
        end
        if CoopRunning() then Coop.Stop() end
    end
end

local function Update()
    Lobby.Frame = (Lobby.Frame or 0) + 1
    if Lobby.Frame % 30 == 0 then CheckMap() end
    local PC = Controller()
    if not PC then return end
    if Lobby.Frame % 30 == 0 then EnsurePoint(PC) end
    if Lobby.Frame % 60 == 0 then UpdateSteam() end
    if Lobby.OpenAt and os.clock() >= Lobby.OpenAt then
        -- (the book: the room menu while in a Steam room, else Solo / Create / Join)
        local Role = Lobby.SteamMode and Lobby.SteamStatus and Lobby.SteamStatus.role
        local Mode = Lobby.OpenMode or ((Role == "A" or Role == "B") and "room" or "rules")
        Lobby.OpenAt, Lobby.OpenMode = nil, nil
        if Mode == "browser" then OpenBrowser(PC) else OpenMenu(PC, Mode) end
    end
    local M = Lobby.Menu
    if not M then return end
    if not Valid(M.Widget) then Lobby.Menu = nil return end   -- (closed by the game, e.g. a map change)
    local Age = Lobby.Frame - M.OpenedFrame
    if Age % 10 == 0 then MenuLibrary():SetCurrentMenuInputActionEnable(PC, false) end   -- (until it sticks)
    if Age < 15 then return end
    if M.Mode == "browser" then
        if Age == 15 then BrowserSearch(M, "friends") end   -- (the left column starts on Friends Only)
        if Age % 30 == 15 then LabelLanRow(M) end
        if M.ListAt and Age % 15 == 0 then
            local R = SteamRooms()
            if R and R.Time >= M.ListAt then
                M.ListAt, M.Rooms = nil, R.Rooms
                Lobby.FeedRooms = {}
                for i, Room in ipairs(R.Rooms) do Lobby.FeedRooms[i] = RoomInfo(Room) end
                M.Widget:OnRequestSaerchFriendRoomReceived({})   -- (the pre-hook fills in the rooms)
                Log(string.format("lobby: %d room(s) listed", #R.Rooms))
            end
        end
        if Pressed(PC, "Ok", M) then Choose(PC, M) return end
        if Pressed(PC, "Back", M) then CloseMenu(PC) end
        return
    end
    if Age == 15 then Ungrey(M, M.Index) else   -- (opened on Create Room / the first room)
        M.Index = CurrentRow(M)
        if Greyed(M) then Ungrey(M, M.Index) end
    end
    if M.Mode == "room" and (Age == 15 or Age % 30 == 0) then FillRoomMenu(M) end   -- (players come and go)
    -- left / right: the room privacy (Create Room's switch; the host's room menu, for the room as it is)
    local Left, Right = Pressed(PC, "Left", M), Pressed(PC, "Right", M)
    if Left or Right then
        local E = M.Mode == "room" and M.Entries and M.Entries[M.Index + 1] or {}
        if E.Privacy then   -- (the Steam room as it is: friends only <-> open to all)
            local Now = Lobby.SteamStatus and Lobby.SteamStatus.type or Lobby.Privacy
            Lobby.Privacy = Now == "friends" and "public" or "friends"
            SteamCommand("type " .. Lobby.Privacy)
            if Lobby.SteamStatus then Lobby.SteamStatus.type = Lobby.Privacy end
            FillRoomMenu(M)
            Log("lobby: room privacy " .. PrivacyLabel[Lobby.Privacy])
        elseif M.Mode == "rules" and M.Index == Create then
            Lobby.Privacy = NextPrivacy(Lobby.Privacy, Right and 1 or -1)
            ApplyRuleLabels(M)
            Log("lobby: room privacy " .. PrivacyLabel[Lobby.Privacy])
        end
    end
    if Pressed(PC, "Ok", M) then Choose(PC, M) return end
    if Pressed(PC, "Back", M) then CloseMenu(PC) end
end

if Lobby.Handle then pcall(CancelDelayedAction, Lobby.Handle) end
Lobby.Handle = LoopInGameThreadAfterFrames(1, function()
    local Ok, Err = pcall(Update)
    if not Ok and Lobby.LastErr ~= tostring(Err) then
        Lobby.LastErr = tostring(Err)
        Log("lobby error: " .. Lobby.LastErr)
    end
end)

Log("lobby.lua loaded")
