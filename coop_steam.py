"""AincradCoop Steam link: carries the co-op mod's state between two game copies through Steam. A Steam lobby is
how the players find each other, and Steam's relay network (SteamNetworkingMessages) carries the traffic - no IP
addresses, ports or firewall rules. Same file interface as coop_link.py: the mod writes its state to
link_<role>_out.txt and reads the other player's from link_<role>_in.txt (role A = host, B = guest).

The mod drives it through two files next to this script:
  steam_cmd.txt     written by the mod: "create <friends|public|lan> <level> <story> <difficulty> <character name>"
                    (host a room), "type <friends|public>" (the host changes it), "list [friends|public|all|lan]"
                    (rooms to join -> steam_rooms.txt), "join <room id>", "join" (a friend's room, else one found by
                    its search tag), "kick", "leave"
  steam_status.txt  written here twice a second: key=value lines (state, role, lobby, me, peer, ...)
  steam_rooms.txt   answer to "list": room=<lobby id>|<players>|<host's Steam name>|<host's character name>|<type>
                    |<level>|<story progress>|<difficulty>
Room types: friends = only the host's Steam friends see and join it, public = anyone with the mod (by the tag),
lan = no Steam lobby: a LAN search (a UDP broadcast, and this PC) finds it, and the guest connects to the host's
port directly (47801-47804; Windows may ask to let Python through its firewall).
Only one runs per game copy, and it leaves its room and stops once the game has closed. --tag gives a second
copy on the same PC its own files (steam_cmd<tag>.txt etc.).
Accepting a Steam invite / "Join game" on the friends list joins that room too (role B).

Uses the game's own steam_api64.dll (Steamworks SDK 1.53). --app is the Steam app id: 480 (Valve's test app, any
account can use it) while testing, 2244210 (Echoes of Aincrad) for real use. Standard library only.
"""
import argparse
import ctypes as C
import os
import socket
import struct
import subprocess
import sys
import time

HERE = os.path.dirname(os.path.abspath(__file__))
GAME_ROOT = os.path.normpath(os.path.join(HERE, *[".."] * 6))   # NetDebug -> Mods -> ue4ss -> Win64 -> Binaries -> EchoesofAincrad -> root
DLL = os.path.join(GAME_ROOT, "Engine", "Binaries", "ThirdParty", "Steamworks", "Steamv153", "Win64", "steam_api64.dll")
MAGIC = b"AC1 "
CONTROL = b"AC1!"              # control messages between the helpers (b"AC1!kick")
TAG = b"aincradcoop"           # lobby data key that marks our rooms (the search tag)
LOCK_PORT = 47791              # a local port held while running: only one helper per PC (two signed in as the same
                               # Steam user split the other player's messages between them)
GAME_EXE = "EchoesofAincrad-Win64-Shipping.exe"
DIRECT_PORT = 47801            # a room's own UDP port (+1 for a tagged copy; a LAN room tries +2 too): LAN guests and a
                               # guest on the same Steam account connect to it directly
LAN_PORTS = range(47801, 47805)   # where a LAN search asks
LAN_QUERY, LAN_ROOM = b"AC1?", b"AC1="   # LAN search: "who's hosting?" and a room's answer

# callback ids (k_i<Interface>Callbacks + n) and enums
CB_LOBBY_ENTER, CB_LOBBY_CHAT_UPDATE, CB_LOBBY_MATCH_LIST, CB_LOBBY_CREATED = 504, 506, 510, 513
CB_LOBBY_JOIN_REQUESTED, CB_CALL_COMPLETED, CB_NET_SESSION_REQUEST = 333, 703, 1251
LOBBY_FRIENDS, LOBBY_PUBLIC = 1, 2
LOBBY_TYPES = {"friends": LOBBY_FRIENDS, "public": LOBBY_PUBLIC}
FRIENDS_IMMEDIATE = 4
DISTANCE_WORLDWIDE = 3
SEND_UNRELIABLE_NO_NAGLE, SEND_RELIABLE = 1, 8
ENTER_SUCCESS = 1
U64 = C.c_uint64


class CallbackMsg(C.Structure):
    _fields_ = [("hSteamUser", C.c_int32), ("iCallback", C.c_int), ("pubParam", C.c_void_p), ("cubParam", C.c_int)]


class FriendGameInfo(C.Structure):
    _fields_ = [("gameID", U64), ("gameIP", C.c_uint32), ("gamePort", C.c_uint16), ("queryPort", C.c_uint16),
                ("lobby", U64)]


Identity = C.c_ubyte * 136     # SteamNetworkingIdentity (filled through the API's own helpers)


class NetMsg(C.Structure):     # the start of SteamNetworkingMessage_t
    _fields_ = [("pData", C.c_void_p), ("cbSize", C.c_int), ("conn", C.c_uint32), ("identityPeer", Identity)]


def write_replace(path, data):
    """Replace the file atomically; if the mod has it open right now, overwrite in place instead."""
    tmp = path + ".tmp"
    with open(tmp, "wb") as f:
        f.write(data)
    for _ in range(3):
        try:
            os.replace(tmp, path)
            return
        except PermissionError:
            time.sleep(0.001)
    with open(path, "wb") as f:
        f.write(data)


class Steam:
    def __init__(self, app):
        os.environ["SteamAppId"] = os.environ["SteamGameId"] = str(app)
        self.app = app
        self.api = C.CDLL(DLL)
        if not self.fn("SteamAPI_Init", C.c_bool)():
            raise RuntimeError("SteamAPI_Init failed - is Steam running and signed in?")
        self.fn("SteamAPI_ManualDispatch_Init", None)()
        self.pipe = self.fn("SteamAPI_GetHSteamPipe", C.c_int32)()
        self.mm = self.fn("SteamAPI_SteamMatchmaking_v009", C.c_void_p)()
        self.fr = self.fn("SteamAPI_SteamFriends_v017", C.c_void_p)()
        self.us = self.fn("SteamAPI_SteamUser_v021", C.c_void_p)()
        self.nm = self.fn("SteamAPI_SteamNetworkingMessages_SteamAPI_v002", C.c_void_p)()
        self.nu = self.fn("SteamAPI_SteamNetworkingUtils_SteamAPI_v004", C.c_void_p)()
        f = self.fn
        self.RunFrame = f("SteamAPI_ManualDispatch_RunFrame", None, C.c_int32)
        self.GetNextCallback = f("SteamAPI_ManualDispatch_GetNextCallback", C.c_bool, C.c_int32, C.POINTER(CallbackMsg))
        self.FreeLastCallback = f("SteamAPI_ManualDispatch_FreeLastCallback", None, C.c_int32)
        self.GetAPICallResult = f("SteamAPI_ManualDispatch_GetAPICallResult", C.c_bool, C.c_int32, U64, C.c_void_p,
                                  C.c_int, C.c_int, C.POINTER(C.c_bool))
        mm = "SteamAPI_ISteamMatchmaking_"
        self.CreateLobby = f(mm + "CreateLobby", U64, C.c_void_p, C.c_int, C.c_int)
        self.SetLobbyType = f(mm + "SetLobbyType", C.c_bool, C.c_void_p, U64, C.c_int)
        self.JoinLobby = f(mm + "JoinLobby", U64, C.c_void_p, U64)
        self.LeaveLobby = f(mm + "LeaveLobby", None, C.c_void_p, U64)
        self.SetLobbyData = f(mm + "SetLobbyData", C.c_bool, C.c_void_p, U64, C.c_char_p, C.c_char_p)
        self.GetLobbyData = f(mm + "GetLobbyData", C.c_char_p, C.c_void_p, U64, C.c_char_p)
        self.GetLobbyOwner = f(mm + "GetLobbyOwner", U64, C.c_void_p, U64)
        self.GetNumLobbyMembers = f(mm + "GetNumLobbyMembers", C.c_int, C.c_void_p, U64)
        self.GetLobbyMemberByIndex = f(mm + "GetLobbyMemberByIndex", U64, C.c_void_p, U64, C.c_int)
        self.RequestLobbyList = f(mm + "RequestLobbyList", U64, C.c_void_p)
        self.AddStringFilter = f(mm + "AddRequestLobbyListStringFilter", None, C.c_void_p, C.c_char_p, C.c_char_p, C.c_int)
        self.AddDistanceFilter = f(mm + "AddRequestLobbyListDistanceFilter", None, C.c_void_p, C.c_int)
        self.GetLobbyByIndex = f(mm + "GetLobbyByIndex", U64, C.c_void_p, C.c_int)
        fr = "SteamAPI_ISteamFriends_"
        self.GetFriendCount = f(fr + "GetFriendCount", C.c_int, C.c_void_p, C.c_int)
        self.GetFriendByIndex = f(fr + "GetFriendByIndex", U64, C.c_void_p, C.c_int, C.c_int)
        self.GetFriendPersonaName = f(fr + "GetFriendPersonaName", C.c_char_p, C.c_void_p, U64)
        self.GetFriendGamePlayed = f(fr + "GetFriendGamePlayed", C.c_bool, C.c_void_p, U64, C.POINTER(FriendGameInfo))
        self.GetPersonaName = f(fr + "GetPersonaName", C.c_char_p, C.c_void_p)
        self.SetRichPresence = f(fr + "SetRichPresence", C.c_bool, C.c_void_p, C.c_char_p, C.c_char_p)
        self.ClearRichPresence = f(fr + "ClearRichPresence", None, C.c_void_p)
        self.GetSteamID = f("SteamAPI_ISteamUser_GetSteamID", U64, C.c_void_p)
        nm = "SteamAPI_ISteamNetworkingMessages_"
        self.SendMessageToUser = f(nm + "SendMessageToUser", C.c_int, C.c_void_p, C.POINTER(Identity), C.c_void_p,
                                   C.c_uint32, C.c_int, C.c_int)
        self.ReceiveMessagesOnChannel = f(nm + "ReceiveMessagesOnChannel", C.c_int, C.c_void_p, C.c_int,
                                          C.POINTER(C.c_void_p), C.c_int)
        self.AcceptSessionWithUser = f(nm + "AcceptSessionWithUser", C.c_bool, C.c_void_p, C.POINTER(Identity))
        self.SetSteamID64 = f("SteamAPI_SteamNetworkingIdentity_SetSteamID64", None, C.POINTER(Identity), U64)
        self.GetSteamID64 = f("SteamAPI_SteamNetworkingIdentity_GetSteamID64", U64, C.POINTER(Identity))
        self.ReleaseMessage = f("SteamAPI_SteamNetworkingMessage_t_Release", None, C.c_void_p)
        f("SteamAPI_ISteamNetworkingUtils_InitRelayNetworkAccess", None, C.c_void_p)(self.nu)
        self.me = self.GetSteamID(self.us)

    def fn(self, name, res, *args):
        func = getattr(self.api, name)
        func.restype, func.argtypes = res, list(args)
        return func

    def name(self, steam_id):
        n = self.GetFriendPersonaName(self.fr, steam_id) if steam_id != self.me else self.GetPersonaName(self.fr)
        return (n or b"?").decode("utf-8", "replace")

    def identity(self, steam_id):
        ident = Identity()
        self.SetSteamID64(C.byref(ident), steam_id)
        return ident

    def callbacks(self):
        """(callback id, payload bytes) for everything Steam has queued, call results included."""
        self.RunFrame(self.pipe)
        msg, out = CallbackMsg(), []
        while self.GetNextCallback(self.pipe, C.byref(msg)):
            try:
                cid, data = msg.iCallback, C.string_at(msg.pubParam, msg.cubParam)
                if cid == CB_CALL_COMPLETED:
                    call, rid, size = struct.unpack_from("<QiI", data)
                    buf, failed = C.create_string_buffer(size), C.c_bool()
                    if self.GetAPICallResult(self.pipe, call, buf, size, rid, C.byref(failed)) and not failed.value:
                        out.append((rid, buf.raw))
                else:
                    out.append((cid, data))
            finally:
                self.FreeLastCallback(self.pipe)
        return out


class Link:
    def __init__(self, steam, dir_, tag=""):
        self.s, self.dir, self.tag = steam, dir_, tag
        self.state, self.role, self.lobby, self.peer, self.note = "idle", "-", 0, 0, ""
        self.join_after_search, self.listing = False, False
        self.banned = set()   # host: players kicked from the current room
        self.room_type = "friends"
        self.last_sent, self.sent, self.received = None, 0, 0
        # same Steam account on this PC (testing): Steam can't connect an account to itself, so the two helpers
        # talk over a local UDP port instead (127.0.0.1 only - no firewall prompt)
        self.direct_sock, self.direct_peer, self.direct, self.direct_seen = None, None, False, 0.0
        self.direct_who = ""   # the other end of the direct link: "<Steam id> <name>" (from its pings)
        # LAN rooms: no Steam lobby - a guest finds them by asking the network (lan_search) and connects directly
        self.lan, self.lan_rooms, self.found_lan, self.query_sock, self.query_until = False, {}, {}, None, 0.0
        self.cmd_path = os.path.join(dir_, f"steam_cmd{tag}.txt")
        self.status_path = os.path.join(dir_, f"steam_status{tag}.txt")

    def log(self, text):
        print(time.strftime("[%H:%M:%S] ") + text, flush=True)
        self.note = text

    # --- rooms ---------------------------------------------------------------------------------------------------

    def create(self, room_type="friends"):
        self.leave(quiet=True)
        self.banned, self.room_type = set(), room_type
        if room_type == "lan":
            self.create_lan()
            return
        self.s.CreateLobby(self.s.mm, LOBBY_TYPES[room_type], 4)
        self.state = "creating"
        self.log("creating a room")

    def create_lan(self):
        """A room on the local network only: it answers LAN searches and guests connect to its port."""
        base = DIRECT_PORT + (1 if self.tag else 0)
        for port in (base, base + 2):
            try:
                self.open_direct(port, "0.0.0.0")
                break
            except OSError:
                continue
        else:
            self.state = "error"
            self.log("LAN room failed: its port is in use")
            return
        self.lan, self.role, self.state = True, "A", "hosting"
        self.lobby = int.from_bytes(os.urandom(6), "little") | 1   # (the room's id in LAN searches)
        self.log(f"LAN room created on port {port} - hosting, waiting for a player")

    def room_line(self):
        """This room as a LAN search answer: id|players|host|hero|type|level|story|difficulty|host's Steam id."""
        s, info = self.s, getattr(self, "host_info", {})
        fields = (self.lobby, 2 if (self.direct_peer or self.peer) else 1, s.name(s.me), info.get("hero", ""),
                  self.room_type, info.get("level", ""), info.get("story", ""), info.get("difficulty", ""), s.me)
        return "|".join(str(x).replace("|", "/").replace("\n", " ") for x in fields)

    def lan_search(self):
        """Ask the local network (and this PC) who's hosting; the answers are collected for a second (poll_lan)."""
        if self.query_sock is None:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_BROADCAST, 1)
            sock.bind(("0.0.0.0", 0))
            sock.setblocking(False)
            self.query_sock = sock
        targets = {"127.0.0.1", "255.255.255.255"}
        try:   # (each of this PC's networks, as a /24 - the plain broadcast only goes out on one of them)
            for ip in socket.gethostbyname_ex(socket.gethostname())[2]:
                if not ip.startswith("127."):
                    targets.add(ip.rsplit(".", 1)[0] + ".255")
        except OSError:
            pass
        for host in targets:
            for port in LAN_PORTS:
                try:
                    self.query_sock.sendto(LAN_QUERY, (host, port))
                except OSError:
                    pass
        self.found_lan, self.query_until = {}, time.time() + 1.0
        self.log("looking for LAN rooms")

    def poll_lan(self):
        """Collects the answers to a LAN search; a second after asking, they're the room list."""
        if self.query_sock is None:
            return
        while True:
            try:
                data, addr = self.query_sock.recvfrom(2048)
            except ConnectionResetError:   # (a port nobody listens on, on this PC)
                continue
            except OSError:
                break
            if data.startswith(LAN_ROOM):
                f = data[len(LAN_ROOM):].decode("utf-8", "replace").split("|")
                if len(f) >= 9 and f[0].isdigit():
                    # (a room on this PC answers on its network address too: the loopback one is kept)
                    if int(f[0]) not in self.found_lan or addr[0] == "127.0.0.1":
                        self.found_lan[int(f[0])] = (addr, f)
        if self.query_until and time.time() >= self.query_until:
            self.query_until, self.lan_rooms, self.listing = 0.0, dict(self.found_lan), "lan"
            self.write_rooms([])

    def friends_rooms(self):
        rooms, info = [], FriendGameInfo()
        for i in range(self.s.GetFriendCount(self.s.fr, FRIENDS_IMMEDIATE)):
            f = self.s.GetFriendByIndex(self.s.fr, i, FRIENDS_IMMEDIATE)
            if self.s.GetFriendGamePlayed(self.s.fr, f, C.byref(info)) and (info.gameID & 0xFFFFFF) == self.s.app and info.lobby:
                rooms.append((info.lobby, self.s.name(f)))
        return rooms

    def list_rooms(self, which="all"):
        """Rooms the player can join - "friends": friends' rooms, "public": open rooms found by the search tag,
        "all": both; written to steam_rooms.txt (at once for friends, else when the search answers)."""
        if which == "lan":
            self.lan_search()
            return
        self.listing = which
        if which == "friends":
            self.write_rooms([])
            return
        self.s.AddStringFilter(self.s.mm, TAG, b"1", 0)
        self.s.AddDistanceFilter(self.s.mm, DISTANCE_WORLDWIDE)
        self.s.RequestLobbyList(self.s.mm)
        self.log(f"looking for rooms ({which})")

    def write_rooms(self, found):
        if self.listing == "lan":
            self.listing = None
            lines = [f"time={time.time():.1f}"] + ["room=" + "|".join(f[:8]) for room, (addr, f) in self.lan_rooms.items()
                                                   if room != self.lobby]
            write_replace(os.path.join(self.dir, f"steam_rooms{self.tag}.txt"), ("\n".join(lines) + "\n").encode("utf-8", "replace"))
            self.log(f"{len(lines) - 1} LAN room(s) found")
            return
        s, rooms, seen = self.s, [], set()
        if self.listing in ("friends", "all"):
            for lobby, host in self.friends_rooms():
                rooms.append((lobby, host))
                seen.add(lobby)
        for lobby in found:
            if lobby not in seen and lobby != self.lobby:
                rooms.append((lobby, (s.GetLobbyData(s.mm, lobby, b"host") or b"?").decode("utf-8", "replace")))
        self.listing = None
        lines = [f"time={time.time():.1f}"]
        for lobby, host in rooms:
            data = {k: (s.GetLobbyData(s.mm, lobby, k.encode()) or b"").decode("utf-8", "replace")
                    for k in ("hero", "type", "level", "story", "difficulty")}
            lines.append(f"room={lobby}|{max(1, s.GetNumLobbyMembers(s.mm, lobby))}|{host}|{data['hero']}|"
                         f"{data['type'] or 'friends'}|{data['level']}|{data['story']}|{data['difficulty']}")
        write_replace(os.path.join(self.dir, f"steam_rooms{self.tag}.txt"), ("\n".join(lines) + "\n").encode("utf-8", "replace"))
        self.log(f"{len(rooms)} room(s) found")

    def join(self, lobby=0):
        self.leave(quiet=True)
        if not lobby:
            rooms = self.friends_rooms()
            if rooms:
                lobby = rooms[0][0]
                self.log(f"joining {rooms[0][1]}'s room")
            else:   # not friends on Steam (or they don't show): look the room up by its search tag
                self.s.AddStringFilter(self.s.mm, TAG, b"1", 0)
                self.s.AddDistanceFilter(self.s.mm, DISTANCE_WORLDWIDE)
                self.s.RequestLobbyList(self.s.mm)
                self.state, self.join_after_search = "searching", True
                self.log("no friend's room - searching for one")
                return
        if lobby in self.lan_rooms:
            self.join_lan(lobby)
            return
        if self.join_direct(lobby):
            return
        self.s.JoinLobby(self.s.mm, lobby)
        self.state, self.join_started = "joining", time.time()

    def join_direct(self, lobby):
        """A room hosted by this Steam account on this PC (two copies, one account - testing): Steam can't join an
        account to itself, so connect to the host copy's helper on its local port. The lobby isn't joined/left -
        for one Steam user that membership is the host copy's too."""
        s = self.s
        data = {k: (s.GetLobbyData(s.mm, lobby, k) or b"").decode("utf-8", "replace") for k in (b"owner", b"pc", b"direct")}
        if data[b"owner"] != str(s.me) or data[b"pc"] != socket.gethostname() or not data[b"direct"].isdigit():
            return False
        try:
            self.open_direct(0)
        except OSError as e:
            self.log(f"direct connect failed: {e}")
            return False
        self.lobby, self.role, self.peer, self.state = lobby, "B", 0, "joined"
        self.direct, self.direct_peer, self.direct_seen = True, ("127.0.0.1", int(data[b"direct"])), time.time()
        self.direct_who = f"{s.me} {s.name(s.me)}"
        self.log(f"joined your own room {lobby} directly on this PC (same Steam account - testing)")
        return True

    def join_lan(self, room):
        addr, f = self.lan_rooms[room]
        try:
            self.open_direct(0, "0.0.0.0")
        except OSError as e:
            self.state = "error"
            self.log(f"could not join the LAN room: {e}")
            return
        self.lobby, self.role, self.peer, self.state, self.room_type = room, "B", 0, "joined", "lan"
        self.direct, self.lan, self.direct_peer, self.direct_seen = True, True, addr, time.time()
        self.direct_who = f"{f[8]} {f[2]}"
        self.log(f"joined {f[2]}'s LAN room ({addr[0]}:{addr[1]})")

    def open_direct(self, port, host="127.0.0.1"):
        if self.direct_sock is None:
            sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
            sock.bind((host, port))
            sock.setblocking(False)
            self.direct_sock = sock
        return self.direct_sock.getsockname()[1]

    def close_direct(self):
        if self.direct_sock is not None:
            if self.direct_peer:   # (tells the other copy at once rather than by silence)
                try:
                    self.direct_sock.sendto(CONTROL + b"bye", self.direct_peer)
                except OSError:
                    pass
            self.direct_sock.close()
        self.direct_sock, self.direct_peer, self.direct, self.lan, self.direct_who = None, None, False, False, ""

    def leave(self, quiet=False, state="idle"):
        # (a direct guest is the same Steam user as the host copy: leaving the lobby would take the host out too;
        # a LAN room has no Steam lobby)
        if self.lobby and not self.direct and not self.lan:
            self.s.LeaveLobby(self.s.mm, self.lobby)
            self.s.ClearRichPresence(self.s.fr)
        self.close_direct()
        self.state, self.role, self.lobby, self.peer = state, "-", 0, 0
        self.last_sent, self.direct_ping = None, 0   # (a new connection starts by sending the current state)
        if not quiet:
            self.log("left the room")

    def set_type(self, room_type):
        """Host: friends only <-> open to everyone, for the room as it is."""
        if self.lan:
            return
        self.room_type = room_type
        if self.role == "A" and self.lobby:
            self.s.SetLobbyType(self.s.mm, self.lobby, LOBBY_TYPES[room_type])
            self.s.SetLobbyData(self.s.mm, self.lobby, b"type", room_type.encode())
            self.log(f"room is now {'friends only' if room_type == 'friends' else 'open to all'}")

    def kick(self):
        """Host: the guest's helper is told to leave (Steam has no kick for lobbies); they're not let back in."""
        if self.role != "A":
            return
        if self.direct_peer:
            self.direct_sock.sendto(CONTROL + b"kick", self.direct_peer)
            who = self.direct_who.split(" ", 1)
            if who[0].isdigit() and int(who[0]) != self.s.me:   # (another account: kept out by its Steam id)
                self.banned.add(int(who[0]))
            self.banned.add(self.direct_peer)
            self.direct_peer, self.direct_who = None, ""
            self.log(f"{who[1] if len(who) > 1 else 'the other player'} was removed from the room")
            return
        if not self.peer:
            return
        s, data = self.s, CONTROL + b"kick"
        ident = s.identity(self.peer)
        s.SendMessageToUser(s.nm, C.byref(ident), data, len(data), SEND_RELIABLE, 0)
        self.banned.add(self.peer)
        self.log(f"{s.name(self.peer)} was removed from the room")
        self.peer = 0

    def on_callback(self, cid, data):
        # (with manual dispatch a call's result can arrive twice: as the call result and as a plain callback)
        s = self.s
        if cid == CB_LOBBY_CREATED:
            result, lobby = struct.unpack_from("<ixxxxQ", data)
            if lobby and lobby == self.lobby:
                return
            if result != 1:
                self.state = "error"
                self.log(f"room create failed (EResult {result})")
                return
            self.lobby, self.role, self.state = lobby, "A", "hosting"
            s.SetLobbyData(s.mm, lobby, TAG, b"1")
            s.SetLobbyData(s.mm, lobby, b"type", self.room_type.encode())
            s.SetLobbyData(s.mm, lobby, b"host", s.name(s.me).encode("utf-8", "replace"))
            for key, value in getattr(self, "host_info", {}).items():   # (character name, level, story, difficulty)
                s.SetLobbyData(s.mm, lobby, key.encode(), value.encode("utf-8", "replace"))
            try:   # (for a copy on this PC signed in to the same Steam account)
                port = self.open_direct(DIRECT_PORT + (1 if self.tag else 0))
                s.SetLobbyData(s.mm, lobby, b"owner", str(s.me).encode())
                s.SetLobbyData(s.mm, lobby, b"pc", socket.gethostname().encode("utf-8", "replace"))
                s.SetLobbyData(s.mm, lobby, b"direct", str(port).encode())
            except OSError as e:
                print(f"  (no direct port: {e})", flush=True)
            s.SetRichPresence(s.fr, b"connect", f"+connect_lobby {lobby}".encode())
            s.SetRichPresence(s.fr, b"status", b"Hosting a co-op room")
            self.log(f"room {lobby} created - hosting, waiting for a player")
        elif cid == CB_LOBBY_MATCH_LIST:
            count = struct.unpack_from("<I", data)[0]
            if self.listing:
                self.write_rooms([s.GetLobbyByIndex(s.mm, i) for i in range(count)])
            if self.join_after_search:
                self.join_after_search = False
                if count:
                    lobby = s.GetLobbyByIndex(s.mm, 0)
                    self.log(f"found room {lobby} (hosted by {(s.GetLobbyData(s.mm, lobby, b'host') or b'?').decode('utf-8', 'replace')})")
                    s.JoinLobby(s.mm, lobby)
                    self.state, self.join_started = "joining", time.time()
                else:
                    self.state = "error"
                    self.log("no room found - has the host created one?")
        elif cid == CB_LOBBY_ENTER:
            lobby, _, _, response = struct.unpack_from("<QI?xxxI", data)
            owner = s.GetLobbyOwner(s.mm, lobby)
            if owner == s.me and self.state == "joining":   # (both copies signed in to the same Steam account)
                # (no LeaveLobby here: for one Steam user that's the host copy's membership too)
                if not self.join_direct(lobby):
                    self.state = "error"
                    self.log("that's your own room on another PC - joining needs a different Steam account")
                return
            if owner == s.me or (lobby == self.lobby and self.state == "joined"):
                return   # (the host entering its own new room / a repeat)
            if response != ENTER_SUCCESS:
                self.state = "error"
                self.log(f"could not join room {lobby} (response {response})")
                return
            self.lobby, self.role, self.peer, self.state = lobby, "B", owner, "joined"
            s.SetRichPresence(s.fr, b"status", b"In a co-op room")
            self.log(f"joined {s.name(owner)}'s room {lobby}")
        elif cid == CB_LOBBY_JOIN_REQUESTED:
            lobby, friend = struct.unpack_from("<QQ", data)
            self.log(f"invite from {s.name(friend)} accepted")
            self.join(lobby)
        elif cid == CB_LOBBY_CHAT_UPDATE:
            pass   # (members are re-read every update)
        elif cid == CB_NET_SESSION_REQUEST:
            ident = Identity.from_buffer_copy(data[:136])
            if self.peer and s.GetSteamID64(C.byref(ident)) == self.peer:
                s.AcceptSessionWithUser(s.nm, C.byref(ident))

    def check_join(self):
        """A join Steam hasn't answered within 15 s has failed."""
        if self.state == "joining" and time.time() - getattr(self, "join_started", time.time()) > 15:
            self.state = "error"
            self.log("could not join the room (no answer from Steam)")

    def update_members(self):
        """Host: the peer is the other member of the room (or none yet). Guest: leaves when the host has."""
        if self.role not in ("A", "B") or not self.lobby:
            return
        # (the direct link has no lobby membership to watch: silence means the other copy has gone)
        if self.direct and self.role == "B":
            if time.time() - self.direct_seen > 10:
                self.leave(quiet=True, state="host-left")
                self.log("the host closed the room")
            return
        if self.direct_peer and time.time() - self.direct_seen > 10:
            self.direct_peer, self.direct_who = None, ""
            self.log("the other player left the room")
        if self.lan:
            return
        s = self.s
        members = [s.GetLobbyMemberByIndex(s.mm, self.lobby, i) for i in range(s.GetNumLobbyMembers(s.mm, self.lobby))]
        if self.role == "B":
            if members and self.peer not in members:
                self.leave(quiet=True, state="host-left")
                self.log("the host closed the room")
            return
        peer = next((m for m in members if m != s.me and m not in self.banned), 0)
        if peer != self.peer:
            self.peer = peer
            self.log(f"{s.name(peer)} joined the room" if peer else "the other player left the room")

    # --- traffic -------------------------------------------------------------------------------------------------

    def pump(self):
        if self.role not in ("A", "B") or not (self.peer or self.direct_sock):
            return
        s = self.s
        out_path = os.path.join(self.dir, f"link_{self.role}_out.txt")
        in_path = os.path.join(self.dir, f"link_{self.role}_in.txt")
        try:
            with open(out_path, "rb") as f:
                line = f.readline().strip()
        except OSError:
            line = None
        # (keeps the link alive when idle, and says who's at this end: a guest's first ping is how the host lets it in)
        if self.direct_peer and time.time() - getattr(self, "direct_ping", 0) > 2:
            try:
                self.direct_sock.sendto(CONTROL + b"ping " + f"{s.me} {s.name(s.me)}".encode("utf-8", "replace"),
                                        self.direct_peer)
            except OSError:
                pass
            self.direct_ping = time.time()
        if line and line != self.last_sent and (self.direct_peer or self.peer):
            data = MAGIC + line
            if self.direct_peer:
                try:
                    self.direct_sock.sendto(data, self.direct_peer)
                    self.sent += 1
                except OSError:
                    pass
            elif self.peer:
                ident = s.identity(self.peer)
                if s.SendMessageToUser(s.nm, C.byref(ident), data, len(data), SEND_UNRELIABLE_NO_NAGLE, 0) == 1:
                    self.sent += 1
            self.last_sent = line
        msgs = (C.c_void_p * 32)()
        newest, kicked, full = None, False, False
        ping = CONTROL + b"ping"
        while self.direct_sock is not None:   # the direct link (LAN rooms, and a guest on the same Steam account)
            try:
                data, addr = self.direct_sock.recvfrom(65535)
            except ConnectionResetError:
                continue
            except OSError:
                break
            if data == LAN_QUERY:   # (a LAN search)
                if self.role == "A":
                    self.direct_sock.sendto(LAN_ROOM + self.room_line().encode("utf-8", "replace"), addr)
                continue
            if self.role == "A" and addr != self.direct_peer and data.startswith(ping):   # a guest arriving
                who = data[len(ping):].decode("utf-8", "replace").strip()
                sid = who.split(" ", 1)[0]
                if addr in self.banned or (sid.isdigit() and int(sid) in self.banned):
                    self.direct_sock.sendto(CONTROL + b"kick", addr)
                elif self.direct_peer or self.peer:
                    self.direct_sock.sendto(CONTROL + b"full", addr)
                else:
                    self.direct_peer, self.direct_who = addr, who
                    local = " (on this PC)" if addr[0] == "127.0.0.1" else f" ({addr[0]})"
                    self.log(f"{who.split(' ', 1)[-1]} joined the room directly{local}")
            if addr != self.direct_peer:
                continue
            self.direct_seen = time.time()
            if data.startswith(MAGIC):
                newest = data[len(MAGIC):]
                self.received += 1
            elif data.startswith(ping):
                self.direct_who = data[len(ping):].decode("utf-8", "replace").strip() or self.direct_who
            elif data == CONTROL + b"kick" and self.role == "B":
                kicked = True
            elif data == CONTROL + b"full" and self.role == "B":
                full = True
            elif data == CONTROL + b"bye":
                if self.role == "B":
                    self.leave(quiet=True, state="host-left")
                    self.log("the host closed the room")
                    return
                self.direct_peer, self.direct_who = None, ""
                self.log("the other player left the room")
        if full:
            self.leave(quiet=True, state="error")
            self.log("that room is full")
            return
        while self.peer:
            n = s.ReceiveMessagesOnChannel(s.nm, 0, msgs, 32)
            if n <= 0:
                break
            for i in range(n):
                m = NetMsg.from_address(msgs[i])
                data = C.string_at(m.pData, m.cbSize)
                from_peer = s.GetSteamID64(C.byref(m.identityPeer)) == self.peer
                if data.startswith(MAGIC) and from_peer:
                    newest = data[len(MAGIC):]
                    self.received += 1
                elif data == CONTROL + b"kick" and from_peer and self.role == "B":
                    kicked = True
                s.ReleaseMessage(msgs[i])
        if kicked:
            self.leave(quiet=True, state="kicked")
            self.log("the host removed you from the room")
            return
        if newest is not None:
            write_replace(in_path, newest + b"\n")

    # --- the mod's commands / status -----------------------------------------------------------------------------

    def commands(self):
        try:
            with open(self.cmd_path, "r", encoding="utf-8") as f:
                cmd = f.read().strip()
            os.remove(self.cmd_path)
        except OSError:
            return
        if cmd == "create" or cmd.startswith("create "):
            # create <friends|public|lan> <level> <story> <difficulty> <character name> (shown in room lists)
            words = cmd.split(" ", 5)
            kind = words[1] if len(words) > 1 and (words[1] in LOBBY_TYPES or words[1] == "lan") else "friends"
            keys = ("level", "story", "difficulty", "hero")
            self.host_info = {k: words[i + 2] for i, k in enumerate(keys) if len(words) > i + 2}
            self.create(kind)
        elif cmd.startswith("type ") and cmd[5:].strip() in LOBBY_TYPES:
            self.set_type(cmd[5:].strip())
        elif cmd == "list" or cmd.startswith("list "):
            which = cmd[5:].strip() or "all"
            self.list_rooms(which if which in ("friends", "public", "all", "lan") else "all")
        elif cmd.startswith("join"):
            arg = cmd[4:].strip()
            self.join(int(arg) if arg.isdigit() else 0)
        elif cmd == "leave":
            self.leave()
        elif cmd == "kick":
            self.kick()

    def write_status(self):
        s = self.s
        if self.direct_peer:   # (the direct link: the other end's Steam id and name, from its pings)
            peer = (self.direct_who or f"{s.me} {s.name(s.me)}") + (" (this PC)" if self.direct_peer[0] == "127.0.0.1" else "")
        else:
            peer = f"{self.peer} {s.name(self.peer) if self.peer else '-'}"
        lines = [f"time={time.time():.1f}", f"state={self.state}", f"role={self.role}", f"lobby={self.lobby}",
                 f"me={s.me} {s.name(s.me)}", f"peer={peer}",
                 f"app={s.app}", f"type={self.room_type}", f"sent={self.sent}", f"received={self.received}",
                 f"note={self.note}"]
        write_replace(self.status_path, ("\n".join(lines) + "\n").encode("utf-8", "replace"))


def game_running():
    # (CSV: the plain table cuts image names at 25 characters; CREATE_NO_WINDOW: no console flash)
    out = subprocess.run(["tasklist", "/FI", f"IMAGENAME eq {GAME_EXE}", "/FO", "CSV", "/NH"], capture_output=True,
                         text=True, creationflags=0x08000000).stdout
    return f'"{GAME_EXE.lower()}"' in out.lower()


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--app", type=int, default=480, help="Steam app id: 480 = Valve's test app (default), 2244210 = the game")
    ap.add_argument("--dir", default=HERE, help="folder holding the link files (default: next to this script)")
    ap.add_argument("--cmd", help="run this command at start (create / join / join <lobby id>)")
    ap.add_argument("--stay", action="store_true", help="keep running when the game isn't (testing)")
    ap.add_argument("--tag", default="", help="file name suffix for a second game copy on this PC (e.g. _P2)")
    args = ap.parse_args()

    lock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    try:
        lock.bind(("127.0.0.1", LOCK_PORT + (1 if args.tag else 0)))
    except OSError:
        print("coop steam: already running", flush=True)
        sys.exit(0)

    try:
        steam = Steam(args.app)
    except Exception as e:
        print(f"coop steam: {e}", flush=True)
        write_replace(os.path.join(args.dir, f"steam_status{args.tag}.txt"),
                      f"time={time.time():.1f}\nstate=error\nnote={e}\n".encode("utf-8", "replace"))
        sys.exit(1)
    link = Link(steam, args.dir, args.tag)
    link.log(f"signed in to Steam as {steam.name(steam.me)} ({steam.me}), app {args.app}")
    if args.cmd:
        write_replace(link.cmd_path, args.cmd.encode())

    next_status, next_report, next_game_check, game_seen = 0.0, time.time() + 10, 0.0, time.time()
    while True:
        for cid, data in steam.callbacks():
            link.on_callback(cid, data)
        link.commands()
        link.update_members()
        link.check_join()
        link.pump()
        link.poll_lan()
        now = time.time()
        if now >= next_status:
            link.write_status()
            next_status = now + 0.5
        if now >= next_report:
            print(f"  {link.state} role={link.role} peer={link.peer} sent {link.sent}, received {link.received}", flush=True)
            next_report = now + 10
        if not args.stay and now >= next_game_check:   # the game closed: leave the room and stop
            next_game_check = now + 5
            if game_running():
                game_seen = now
            elif now - game_seen > 15:
                link.leave(quiet=True)
                link.state, link.note = "stopped", "the game closed"
                link.write_status()
                steam.fn("SteamAPI_Shutdown", None)()
                print("coop steam: the game closed - stopping", flush=True)
                return
        time.sleep(0.004)


if __name__ == "__main__":
    main()
