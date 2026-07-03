#!/bin/zsh
# v0.2 launcher: first-run installer extraction, then run the wine loader with
# a clean session lifecycle. Lives at Contents/MacOS/$APP_NAME-setup. A Swift
# launcher with a proper progress UI replaces this later; the flow stays the same.
#
# Lifecycle guarantees (v0.2):
#  - open  = fresh wineserver session (any leftover session from an older build
#            is shut down first; mixed old/new builds are a known crash source)
#  - close = full teardown; no wineserver/winedevice processes linger
#  - app update = prefix's builtin-DLL copies refreshed via wineboot -u before
#            the first launch of a new build (build-id stamped at package time)
set -euo pipefail

CONTENTS="${0:A:h:h}"                       # .../Contents
RES="$CONTENTS/Resources"
APP_NAME="${$(basename "${0:A}")%-setup}"
SUPPORT="$HOME/Library/Application Support/$APP_NAME"
export WINEPREFIX="$SUPPORT/prefix"
VCDS_DIR="$WINEPREFIX/drive_c/Ross-Tech/VCDS"

export PATH="$RES/wine/bin:$PATH"
export DYLD_FALLBACK_LIBRARY_PATH="$RES/libs"
export WINESERVER="$RES/wine/bin/wineserver"
export WINELOADER="$CONTENTS/MacOS/$APP_NAME"   # children show the app name, not "wine"
# err class stays on so field crash logs are diagnosable; fixme spam off.
export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all,warn-all,trace-all}"
WINELOADER_BIN="$CONTENTS/MacOS/$APP_NAME"

# Hybrid x86: advertise x86 support so i386 helpers (VCIConfig, VCDSScan,
# LCode) run through Rosetta 2. On by default when the x86_64 slice is
# installed; a disable-x86 flag file turns it off without rebuilding.
if [[ -x "$RES/wine/lib/wine/x86_64-unix/wine" && ! -f "$SUPPORT/disable-x86" ]]; then
    export WINEHYBRIDX86=1
fi

# Session logs: rotate the last 5 (crash backtraces from winedbg land here,
# so one bad launch must not be wiped by the next).
LOGS="$SUPPORT/logs"
mkdir -p "$LOGS"
rm -f "$SUPPORT/last-session.log"           # pre-v0.2 single log
for i in 4 3 2 1; do
    [[ -f "$LOGS/session.$i.log" ]] && mv -f "$LOGS/session.$i.log" "$LOGS/session.$((i+1)).log"
done
[[ -f "$LOGS/session.log" ]] && mv -f "$LOGS/session.log" "$LOGS/session.1.log"
exec 2>"$LOGS/session.log"
print -ru2 -- "$APP_NAME launch $(date '+%Y-%m-%d %H:%M:%S') build=$(cat "$RES/build-id" 2>/dev/null || echo '?')"

# Sample the Option key NOW, before the slow parts, so a quick press-and-hold
# at launch is reliably seen. Option-at-launch = reinstall/update VCDS.
OPTION_HELD=$(osascript -l JavaScript -e \
    'ObjC.import("Cocoa"); ($.NSEvent.modifierFlags & $.NSEventModifierFlagOption) ? 1 : 0' 2>/dev/null || echo 0)

# One launcher at a time: a second copy started during setup/boot must not
# mistake the first one's half-built session for a stale one and sweep it.
LOCKFILE="$SUPPORT/launcher.pid"
if [[ -f "$LOCKFILE" ]] && kill -0 "$(cat "$LOCKFILE" 2>/dev/null)" 2>/dev/null; then
    print -ru2 -- "another launcher (pid $(cat "$LOCKFILE")) is alive -- deferring to it"
    osascript -e 'tell application "System Events" to set frontmost of (first process whose name contains "VCDS") to true' 2>/dev/null || true
    exit 0
fi
print -r -- $$ >"$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

fail() { osascript -e "display dialog \"$1\" buttons {\"Quit\"} default button 1 with icon stop with title \"$APP_NAME\"" >/dev/null; exit 1; }

notify() { osascript -e "display notification \"$1\" with title \"$APP_NAME\"" 2>/dev/null || true; }

# Shut down this prefix's wine session completely (bounded). wineserver -k
# asks the server to kill its clients, but on this port some clients survive
# that (blocked in a server-socket read), so after the server is gone we
# sweep any process still mapping our ntdll.so. Never SIGKILL the server
# while clients live -- that strands them permanently (seen 2026-07-02).
end_session() {
    local i
    "$WINESERVER" -kw 2>/dev/null &
    local kw=$!
    for i in {1..150}; do          # 30s: a full-session teardown can be slow
        kill -0 $kw 2>/dev/null || break
        sleep 0.2
    done
    kill -0 $kw 2>/dev/null && { kill $kw 2>/dev/null || true; }
    # Sweep survivors of this bundle's session (matched by mapped binary, not
    # argv -- wine rewrites argv to Windows-style names).
    local leftovers
    leftovers=$(lsof -t "$RES/wine/lib/wine/aarch64-unix/ntdll.so" 2>/dev/null) || true
    if [[ -n "${leftovers:-}" ]]; then
        print -ru2 -- "end_session: sweeping leftover pids: ${=leftovers}"
        kill -9 ${=leftovers} 2>/dev/null || true
        sleep 1
        "$WINESERVER" -k9 2>/dev/null || true
    fi
}

extract_installer() {
    local installer="$1" target="$2"
    [[ -f "$installer" ]] || fail "Installer not found."
    mkdir -p "$target"
    # Native NSIS extraction -- the (x86) installer stub is never executed.
    "$RES/extractor/7zz" x -y -o"$target" "$installer" >/dev/null \
        || fail "Could not extract the installer. Is this the genuine VCDS download?"
    [[ -f "$target/VCDS-ARM.exe" ]] \
        || fail "This installer does not contain an ARM version of VCDS (need 25.x or later)."
    rm -rf "$target/\$PLUGINSDIR" "$target/\$TEMP"
}

choose_installer() {
    osascript <<'EOF' 2>/dev/null
POSIX path of (choose file with prompt "Select your downloaded VCDS installer (VCDS-Release-….exe).\n\nYou can download it from Ross-Tech's website. It is only read, never run." of type {"com.microsoft.windows-executable", "public.data"})
EOF
}

# Option-at-launch: update (or repair) VCDS from a newer Ross-Tech installer.
# The new tree is unpacked to the side and only swapped in once it verifies,
# so a bad download can't damage the current install. The user's settings
# (*.CFG / *.ini / *.bin -- serial, options, workshop code) carry over; the
# Logs/Scans/Debug symlinks are re-created by map_output_dirs afterwards.
reinstall() {
    local installer tmp f
    osascript -e "display dialog \"Update VCDS from a new Ross-Tech installer?\n\nYour settings and activation are kept.\" buttons {\"Cancel\", \"Choose Installer…\"} default button 2 with title \"$APP_NAME\"" >/dev/null 2>&1 || return 0
    installer=$(choose_installer) || return 0   # user cancelled
    installer="${installer%$'\n'}"
    tmp="$SUPPORT/vcds-update-tmp"
    rm -rf "$tmp"
    notify "Unpacking the new VCDS version…"
    extract_installer "$installer" "$tmp"
    for f in "$VCDS_DIR"/*.CFG(N) "$VCDS_DIR"/*.ini(N) "$VCDS_DIR"/*.bin(N); do
        cp -p "$f" "$tmp/"
    done
    # Atomic-ish swap: the old install is moved aside, not deleted, until the
    # new one is in place -- a failure at any point leaves a usable state.
    rm -rf "$VCDS_DIR.old"
    mv "$VCDS_DIR" "$VCDS_DIR.old"
    if mv "$tmp" "$VCDS_DIR"; then
        rm -rf "$VCDS_DIR.old"
    else
        mv "$VCDS_DIR.old" "$VCDS_DIR"
        fail "Update failed -- your existing VCDS install is untouched."
    fi
    notify "VCDS updated."
}

first_run() {
    local installer
    installer=$(choose_installer) || exit 0   # user cancelled
    installer="${installer%$'\n'}"

    osascript -e "display dialog \"Setting up — this one-time step takes a few minutes.\n\nYou'll get a notification at each stage, and VCDS will open when it's ready.\" buttons {\"OK\"} default button 1 with title \"$APP_NAME\" giving up after 15" >/dev/null 2>&1 || true

    notify "Preparing the Windows environment (1 of 3)…"
    mkdir -p "$WINEPREFIX"
    "$WINELOADER_BIN" wineboot --init 2>/dev/null || fail "Could not initialise the Windows environment."
    notify "Unpacking VCDS from your installer (2 of 3)…"
    extract_installer "$installer" "$VCDS_DIR"
    "$WINELOADER_BIN" regedit /S "$RES/seed/prefix.reg" 2>/dev/null || true
    "$RES/wine/bin/wineserver" -w 2>/dev/null || true
    notify "Finishing up (3 of 3)…"

    cat "$RES/build-id" 2>/dev/null >"$SUPPORT/installed-build" || true
}

# VCDS output lands somewhere a Mac user can find it: Logs, Scans and Debug
# live in ~/Documents/VCDS Logs and the prefix dirs are symlinks. Idempotent
# and run every launch so existing installs pick up newly mapped dirs.
map_output_dirs() {
    local mac_root="$HOME/Documents/VCDS Logs" d
    [[ -d "$VCDS_DIR" ]] || return 0
    for d in Logs Scans Debug; do
        local target="$mac_root"
        [[ "$d" != "Logs" ]] && target="$mac_root/$d"
        [[ -L "$VCDS_DIR/$d" ]] && continue
        # macOS TCC can deny us ~/Documents -- then just leave VCDS's own
        # dirs in place (everything still works, files are only less visible).
        mkdir -p "$target" 2>/dev/null || { print -ru2 -- "map_output_dirs: no access to $target, skipping"; continue; }
        if [[ -d "$VCDS_DIR/$d" ]]; then
            # Copy first, delete ONLY if the copy succeeded -- a partial copy
            # (disk full, permission) must never cost the user their scans.
            if cp -a "$VCDS_DIR/$d/." "$target/" 2>/dev/null; then
                rm -rf "$VCDS_DIR/$d"
            else
                print -ru2 -- "map_output_dirs: copy of $d failed, keeping prefix dir"
                continue
            fi
        fi
        ln -s "$target" "$VCDS_DIR/$d"
    done
}

# Single instance vs stale session. Processes mapping our ntdll.so are this
# bundle's session (wine rewrites argv, so pgrep on the command line is NOT
# reliable). Two cases:
#  - VCDS itself is among them: it's genuinely running -- bring it to the
#    front and leave it alone (it may be mid-conversation with a car);
#  - session remnants but NO VCDS process (aftermath of a crash or force-
#    quit): sweep and boot normally. Without this a wedged session made the
#    app "open" to nothing until cleaned up by hand.
session_pids=$(lsof -t "$RES/wine/lib/wine/aarch64-unix/ntdll.so" 2>/dev/null) || true
if [[ -n "${session_pids:-}" ]]; then
    if ps -o command= -p ${=session_pids} 2>/dev/null | grep -q "VCDS-ARM\.exe"; then
        osascript -e 'tell application "System Events" to set frontmost of (first process whose name contains "VCDS") to true' 2>/dev/null || true
        exit 0
    fi
    print -ru2 -- "stale session with no VCDS process -- sweeping"
fi

# Fresh session on every open. A wineserver left over from an older build of
# this app serves stale DLL mappings to new processes = jump-to-garbage
# crashes (seen 2026-07-02). Cold boot is ~0.6s, so a warm session buys
# nothing worth that risk.
end_session

# No install (or a BROKEN one) = first run; Option held = update/reinstall.
# The exe alone is not proof of an install: a directory with VCDS-ARM.exe
# but no Codes.dat boots to a zombie "VAG-COM" screen with everything
# disabled (seen 2026-07-03 on an account with debris from old experiments).
if [[ ! -f "$VCDS_DIR/VCDS-ARM.exe" || ! -f "$VCDS_DIR/Codes.dat" ]]; then
    if [[ -f "$VCDS_DIR/VCDS-ARM.exe" ]]; then
        osascript -e "display dialog \"The VCDS installation is incomplete and needs to be set up again from your Ross-Tech installer.\" buttons {\"Continue\"} default button 1 with title \"$APP_NAME\" giving up after 20" >/dev/null 2>&1 || true
        rm -rf "$VCDS_DIR"
    fi
    first_run
elif [[ "$OPTION_HELD" == "1" ]]; then
    reinstall
fi

# App updated since this prefix last ran? Refresh the prefix's builtin-DLL
# copies (wineboot -u rewrites everything carrying the "Wine builtin DLL"
# signature and leaves the user's VCDS files alone).
BUNDLE_BUILD="$(cat "$RES/build-id" 2>/dev/null || echo unknown)"
if [[ "$(cat "$SUPPORT/installed-build" 2>/dev/null || true)" != "$BUNDLE_BUILD" ]]; then
    notify "Updating the Windows environment…"
    "$WINELOADER_BIN" wineboot -u || true
    "$WINESERVER" -w 2>/dev/null || true
    print -r -- "$BUNDLE_BUILD" >"$SUPPORT/installed-build"
fi

map_output_dirs

# Run VCDS. The chain from app to interface to car can glitch (interference,
# dropped packets), and VCDS may hang or crash then -- it does on bare-metal
# Windows too. Make recovery one click: an abnormal exit (crash, or the user
# force-quitting a hung VCDS) tears the session down and offers to reopen.
# Crashes are recognised by the loader's "Unhandled ..." marker in this
# session's log, counted per run so an old crash never flags a clean exit.
crash_count() { local n; n=$(grep -c "Unhandled" "$LOGS/session.log" 2>/dev/null) || true; print -r -- "${n:-0}"; }
while :; do
    cd "$VCDS_DIR"   # VCDS requires cwd = its dir (CODES.DAT)
    marks_before=$(crash_count)
    rc=0
    "$WINELOADER_BIN" VCDS-ARM.exe || rc=$?

    # Full teardown on close: without this, winedevice/services keep the
    # session alive indefinitely (nothing may outlive the app).
    end_session

    (( rc != 0 )) || [[ "$(crash_count)" != "$marks_before" ]] || break
    print -ru2 -- "abnormal VCDS exit rc=$rc -- offering reopen"
    ans=$(osascript -e "display dialog \"VCDS quit unexpectedly.\n\nThis can happen after an interface or communication glitch -- your logs and settings are safe.\" buttons {\"Close\", \"Reopen\"} default button \"Reopen\" cancel button \"Close\" with title \"$APP_NAME\" giving up after 60" 2>/dev/null) || break
    [[ "$ans" == *"button returned:Reopen"* ]] || break
done
exit 0
