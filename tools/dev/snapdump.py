"""Write a minidump of a (hung) process without stopping it.  snapdump.py <pid> <out.dmp>"""
import ctypes as C, ctypes.wintypes as W, sys

pid, out = int(sys.argv[1]), sys.argv[2]
k32, dbg = C.WinDLL("kernel32", use_last_error=True), C.WinDLL("dbghelp", use_last_error=True)
k32.OpenProcess.restype = W.HANDLE
h = k32.OpenProcess(0x0400 | 0x0010, False, pid)   # PROCESS_QUERY_INFORMATION | PROCESS_VM_READ
if not h:
    sys.exit(f"OpenProcess failed: {C.get_last_error()}")
k32.CreateFileW.restype = W.HANDLE
f = k32.CreateFileW(out, 0x40000000, 0, None, 2, 0x80, None)   # GENERIC_WRITE, CREATE_ALWAYS
# MiniDumpWithThreadInfo | MiniDumpWithUnloadedModules | MiniDumpWithIndirectlyReferencedMemory (stacks + what they point at)
flags = 0x1000 | 0x20 | 0x40
ok = dbg.MiniDumpWriteDump(h, pid, f, flags, None, None, None)
err = C.get_last_error()
k32.CloseHandle(f)
k32.CloseHandle(h)
print("dump written" if ok else f"MiniDumpWriteDump failed: {err}")
