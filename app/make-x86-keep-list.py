#!/usr/bin/env python3
"""Compute the x86 keep-list: runtime-loaded modules from +loaddll captures,
expanded to a static import closure over the bundle trees."""
import glob, os, re, subprocess, sys

SCRATCH = sys.argv[1] if len(sys.argv) > 1 else os.path.dirname(os.path.abspath(__file__))  # dir with loaddll-*.log captures
APP = sys.argv[2] if len(sys.argv) > 2 else os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "dist", "DiagBridge.app"))  # bundle to scan
TREES = {
    "i386-windows": os.path.join(APP, "Contents/Resources/wine/lib/wine/i386-windows"),
    "x86_64-windows": os.path.join(APP, "Contents/Resources/wine/lib/wine/x86_64-windows"),
}
READOBJ = "/opt/homebrew/opt/llvm/bin/llvm-readobj"

# 1) runtime loads
loaded = set()
for log in glob.glob(os.path.join(SCRATCH, "loaddll-*.log")):
    for m in re.finditer(r'Loaded L"([^"]+)"', open(log, errors="replace").read()):
        base = m.group(1).replace("\\\\", "\\").split("\\")[-1].lower()
        loaded.add(base)

# 2) insurance: plausibly-reachable-but-not-exercised
grace = {
    # printing / common dialogs / rich text
    "winspool.drv", "comdlg32.dll", "localspl.dll", "spoolss.dll",
    "riched20.dll", "riched32.dll", "usp10.dll",
    # network stacks helpers might touch (VCIConfig firmware/web paths)
    "wininet.dll", "winhttp.dll", "urlmon.dll", "dnsapi.dll", "mswsock.dll",
    "ws2_32.dll", "iphlpapi.dll", "netapi32.dll", "secur32.dll", "schannel.dll",
    # crypto
    "crypt32.dll", "bcrypt.dll", "rsaenh.dll", "cryptsp.dll", "wintrust.dll",
    # msvc runtimes (small, apps link various)
    "msvcrt.dll", "msvcp60.dll", "msvcp100.dll", "msvcp140.dll",
    "msvcr100.dll", "msvcr110.dll", "msvcr120.dll", "vcruntime140.dll",
    "ucrtbase.dll",
    # infrastructure processes
    "rundll32.exe", "regsvr32.exe", "cmd.exe", "conhost.exe", "start.exe",
    # wow64 host side (x86_64 tree)
    "wow64.dll", "wow64win.dll", "wow64cpu.dll",
    # crash backtraces in session logs come from winedbg
    "winedbg.exe", "dbghelp.dll",
    # manifest-driven comctl32 v6, OLE typelibs, xml parsers, mshtml's
    # dynamically-loaded companions
    "apisetschema.dll",  # loaded via a special path +loaddll never traces
    "comctl32_v6.dll", "stdole2.tlb", "stdole32.tlb", "oledlg.dll",
    "msxml3.dll", "msxml6.dll", "jscript.dll", "icu.dll",
}
keep = loaded | grace

def imports_of(path):
    try:
        out = subprocess.run([READOBJ, "--coff-imports", path],
                             capture_output=True, text=True, timeout=60).stdout
    except Exception:
        return set()
    deps = set(m.group(1).lower() for m in re.finditer(r"Name: (\S+\.(?:dll|drv|cpl|ocx))", out, re.I))
    return deps

# 3) static import closure per tree (delay-loads appear as regular COFF imports in wine builds)
for tree, root in TREES.items():
    files = {f.lower(): os.path.join(root, f) for f in os.listdir(root)}
    frontier = [n for n in keep if n in files]
    seen = set(frontier)
    while frontier:
        cur = frontier.pop()
        for dep in imports_of(files[cur]):
            if dep not in seen:
                seen.add(dep)
                keep.add(dep)
                if dep in files:
                    frontier.append(dep)

# 4) report per tree
total_savings = 0
for tree, root in TREES.items():
    keep_sz = drop_sz = 0
    dropped = []
    for f in sorted(os.listdir(root)):
        p = os.path.join(root, f)
        if not os.path.isfile(p):
            continue
        sz = os.path.getsize(p)
        if f.lower() in keep:
            keep_sz += sz
        else:
            drop_sz += sz
            dropped.append(f)
    total_savings += drop_sz
    n_keep = len(os.listdir(root)) - len(dropped)
    print(f"{tree}: keep {n_keep} files ({keep_sz/1e6:.0f} MB logical), "
          f"drop {len(dropped)} files ({drop_sz/1e6:.0f} MB logical)")

print(f"total logical savings: {total_savings/1e6:.0f} MB (pre-decmpfs)")
with open(os.path.join(SCRATCH, "keep-list.txt"), "w") as fh:
    fh.write("\n".join(sorted(keep)) + "\n")
print(f"keep-list ({len(keep)} names) -> {os.path.join(SCRATCH, 'keep-list.txt')}")
