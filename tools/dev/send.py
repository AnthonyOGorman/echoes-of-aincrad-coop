"""Send a remote command to a game copy (NetDebug cmd_<tag>.txt) and print the log lines it writes.
Usage: send.py <tag> "<command>" [seconds]   (command "@file" sends that file's contents as "lua ...")"""
import glob, os, sys, time
ND = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", ".."))   # the mod folder
tag, cmd = sys.argv[1], sys.argv[2]
sys.stdout.reconfigure(encoding="utf-8", errors="replace")
wait = float(sys.argv[3]) if len(sys.argv) > 3 else 4
if cmd.startswith("@"):
    cmd = "lua " + open(os.path.join(os.path.dirname(os.path.abspath(__file__)), cmd[1:]), encoding="utf-8").read()
logs = sorted(glob.glob(os.path.join(ND, f"netdebug_*_{tag}.log")), key=os.path.getmtime)
log = logs[-1] if logs else None
start = os.path.getsize(log) if log else 0
open(os.path.join(ND, f"cmd_{tag}.txt"), "w", encoding="utf-8").write(cmd)
time.sleep(wait)
if log:
    with open(log, "rb") as f:
        f.seek(start)
        sys.stdout.write(f.read().decode("utf-8", "replace"))
