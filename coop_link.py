"""AincradCoop LAN link: carries the co-op mod's state between two game copies over UDP.

The mod (coop.lua in link mode) writes its player state to link_<me>_out.txt and reads the other
player's state from link_<me>_in.txt. Run one link next to each game copy:

    PC 1:  python coop_link.py --me A --port 47777 --peer 192.168.1.20:47777
    PC 2:  python coop_link.py --me B --port 47777 --peer 192.168.1.10:47777

Two copies on one PC:  --me A --port 47777 --peer 127.0.0.1:47778
                       --me B --port 47778 --peer 127.0.0.1:47777

Standard library only. Datagrams are "AC1 <line>"; only the newest state matters, so loss is fine.
"""
import argparse
import os
import socket
import time

MAGIC = b"AC1 "
HERE = os.path.dirname(os.path.abspath(__file__))


def parse_addr(text):
    host, _, port = text.rpartition(":")
    return host, int(port)


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


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--me", required=True, help="this copy's role, matching Coop.Start in the mod (A or B)")
    ap.add_argument("--port", type=int, default=47777, help="UDP port to listen on")
    ap.add_argument("--bind", default="0.0.0.0",
                    help="address to listen on: 0.0.0.0 for LAN (Windows Firewall asks once), 127.0.0.1 for one PC")
    ap.add_argument("--peer", required=True, help="other copy's link, host:port")
    ap.add_argument("--dir", default=HERE, help="folder holding the link files (default: next to this script)")
    args = ap.parse_args()

    out_path = os.path.join(args.dir, f"link_{args.me}_out.txt")
    in_path = os.path.join(args.dir, f"link_{args.me}_in.txt")
    peer = parse_addr(args.peer)

    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind((args.bind, args.port))
    sock.setblocking(False)
    print(f"coop link {args.me}: listening on udp {args.bind}:{args.port}, sending to {peer[0]}:{peer[1]}")
    print(f"  out: {out_path}\n  in:  {in_path}")

    last_sent, sent, received, last_from = None, 0, 0, None
    next_report = time.time() + 5
    while True:
        # local state -> peer (only when the mod wrote something new)
        try:
            with open(out_path, "rb") as f:
                line = f.readline().strip()
        except OSError:
            line = None
        if line and line != last_sent:
            try:
                sock.sendto(MAGIC + line, peer)
                sent += 1
                last_sent = line
            except OSError:
                pass  # peer not up yet / unreachable; the next state will try again

        # peer state -> local file (drain, keep the newest)
        newest = None
        while True:
            try:
                data, addr = sock.recvfrom(65535)   # enemy lists make lines several KB long
            except (BlockingIOError, ConnectionResetError):
                break
            except OSError:
                continue  # e.g. an oversized datagram; drop it and keep going
            if data.startswith(MAGIC):
                newest, last_from = data[len(MAGIC):], addr
                received += 1
        if newest is not None:
            write_replace(in_path, newest + b"\n")

        if time.time() >= next_report:
            print(f"  sent {sent}, received {received}, peer seen at {last_from}")
            next_report = time.time() + 5
        time.sleep(0.004)


if __name__ == "__main__":
    main()
