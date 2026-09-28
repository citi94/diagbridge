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
# A debug-seh flag file (touch "$SUPPORT/debug-seh") additionally traces
# exception dispatch — the tool for hunting intermittent faults in the field
# without launching from a terminal. Verbose; delete the file when done.
if [[ -f "$SUPPORT/debug-seh" ]]; then
    export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all,warn-all,trace-all,trace+seh}"
else
    export WINEDEBUG="${WINEDEBUG:-err+all,fixme-all,warn-all,trace-all}"
fi
WINELOADER_BIN="$CONTENTS/MacOS/$APP_NAME"

# Hybrid x86: advertise x86 support so i386 helpers (VCIConfig, VCDSScan,
# LCode) run through Rosetta 2. On by default when the x86_64 slice is
# installed; a disable-x86 flag file turns it off without rebuilding.
if [[ -x "$RES/wine/lib/wine/x86_64-unix/wine" && ! -f "$SUPPORT/disable-x86" ]]; then
    export WINEHYBRIDX86=1
fi

# Sample the Option key NOW, before the slow parts, so a quick press-and-hold
# at launch is reliably seen. Option-at-launch = reinstall/update VCDS.
OPTION_HELD=$(osascript -l JavaScript -e \
    'ObjC.import("Cocoa"); ($.NSEvent.modifierFlags & $.NSEventModifierFlagOption) ? 1 : 0' 2>/dev/null || echo 0)

# One launcher at a time: a second copy started during setup/boot must not
# mistake the first one's half-built session for a stale one and sweep it.
# Checked BEFORE log rotation: a second launch rotating the logs renamed the
# running session's log out from under it (its crash check then read the
# wrong file, and repeat launches pushed the real log off the end). The pid
# must also still be a launcher: a lock left by a force-quit survives a
# reboot, and a recycled pid made the app silently refuse to open.
LOGS="$SUPPORT/logs"
mkdir -p "$LOGS"
LOCKFILE="$SUPPORT/launcher.pid"
lock_pid=$(cat "$LOCKFILE" 2>/dev/null || true)
if [[ -n "$lock_pid" ]] && ps -o command= -p "$lock_pid" 2>/dev/null | grep -qF -- "${0:t}"; then
    print -r -- "another launcher (pid $lock_pid) is alive -- deferring to it" >>"$LOGS/session.log"
    osascript -e 'tell application "System Events" to set frontmost of (first process whose name contains "VCDS") to true' 2>/dev/null || true
    exit 0
fi
print -r -- $$ >"$LOCKFILE"
trap 'rm -f "$LOCKFILE"' EXIT

# Session logs: rotate the last 5 (crash backtraces from winedbg land here,
# so one bad launch must not be wiped by the next).
rm -f "$SUPPORT/last-session.log"           # pre-v0.2 single log
for i in 4 3 2 1; do
    [[ -f "$LOGS/session.$i.log" ]] && mv -f "$LOGS/session.$i.log" "$LOGS/session.$((i+1)).log"
done
[[ -f "$LOGS/session.log" ]] && mv -f "$LOGS/session.log" "$LOGS/session.1.log"
exec 2>"$LOGS/session.log"
print -ru2 -- "$APP_NAME launch $(date '+%Y-%m-%d %H:%M:%S') build=$(cat "$RES/build-id" 2>/dev/null || echo '?')"

fail() { osascript -e "display dialog \"$1\" buttons {\"Quit\"} default button 1 with icon stop with title \"$APP_NAME\"" >/dev/null; exit 1; }

notify() { osascript -e "display notification \"$1\" with title \"$APP_NAME\"" 2>/dev/null || true; }

# Every process belonging to a DiagBridge wine session -- from ANY build of
# the app, not only this bundle. wine rewrites argv to Windows names, so we
# enumerate PE processes (".exe" in argv) and keep those with a file mapped
# inside some "$APP_NAME.app" wine tree. That signal is bundle- and location-
# independent (a dev/dist copy, an old build), needs no live wineserver (the
# mmaps outlive it), and works where env vars can't -- macOS won't let us read
# another process's WINEPREFIX. All DiagBridge bundles share one prefix (keyed
# by app name), so "a DiagBridge wine process" == "a process on our prefix".
# This is what reaps strays a per-bundle match cannot see -- e.g. an orphaned
# services.exe left pegging a core for days after its wineserver died (seen
# 2026-07-08: three dev-build sessions, one in a segv storm for six days).
prefix_session_pids() {
    local p pids=()
    for p in $(ps -Ao pid=,command= 2>/dev/null | awk '/\.exe/{print $1}'); do
        [[ "$p" == "$$" ]] && continue
        lsof -p "$p" 2>/dev/null | grep -qF "$APP_NAME.app/Contents/Resources/wine/" \
            && pids+=$p
    done
    print -r -- ${pids}
}

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
    # Cross-bundle safety net: reap any DiagBridge wine process the per-bundle
    # sweep above cannot see -- a stray from a different build sharing this
    # prefix, possibly with a long-dead wineserver of its own.
    local stray
    stray=$(prefix_session_pids)
    if [[ -n "${stray:-}" ]]; then
        print -ru2 -- "end_session: reaping cross-bundle stray pids: ${=stray}"
        kill -9 ${=stray} 2>/dev/null || true
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

# A whole, intact Ross-Tech installer with an ARM build inside -- checked
# before anything is torn down. `7zz t` decompresses every entry, so a
# truncated download fails here rather than half-way through an update.
installer_complete() {
    [[ -s "$1" ]] || return 1
    "$RES/extractor/7zz" t "$1" >/dev/null 2>&1 || return 1
    "$RES/extractor/7zz" l -slt "$1" 2>/dev/null | grep -qx 'Path = VCDS-ARM.exe'
}

choose_installer() {
    osascript <<'EOF' 2>/dev/null
POSIX path of (choose file with prompt "Select your downloaded VCDS installer (VCDS-Release-….exe).\n\nYou can download it from Ross-Tech's website. It is only read, never run." of type {"com.microsoft.windows-executable", "public.data"})
EOF
}

# Option-at-launch: update (or repair) VCDS from a newer Ross-Tech installer.
# The new tree is unpacked to the side and only swapped in once it verifies,
# so a bad download can't damage the current install. See apply_update for
# what carries over; the Logs/Scans/Debug symlinks are re-created by
# map_output_dirs afterwards.
reinstall() {
    local installer
    osascript -e "display dialog \"Update VCDS from a new Ross-Tech installer?\n\nYour settings and activation are kept.\" buttons {\"Cancel\", \"Choose Installer…\"} default button 2 with title \"$APP_NAME\"" >/dev/null 2>&1 || return 0
    installer=$(choose_installer) || return 0   # user cancelled
    installer="${installer%$'\n'}"
    apply_update "$installer"
}

# Unpack a Ross-Tech installer over the current install. Used by the
# Option-launch flow above and by the in-app updater hand-off below.
#
# What carries over from the old install:
#  - every file the new installer does NOT ship -- that is, whatever VCDS or
#    the user created: VCDS.CFG, Scaling/VCPrefs.cfg, adaptation histories,
#    and Logs/Scans/Debug when they are real dirs rather than symlinks
#    (map_output_dirs can fail; the old *.CFG/*.ini/*.bin rule then deleted
#    them with the old tree). Executables and DLLs are left behind, so code
#    Ross-Tech dropped doesn't linger.
#  - top-level *.cfg / *.ini even where the installer ships a default
#    (LCode.ini, vcdsscan.ini are rewritten with the user's preferences).
# Everything else the installer ships wins -- notably the interface firmware
# images (HN121.bin etc.), which the old rule silently reverted to the
# previous version on every update.
#
# Runs as an `if` condition, where set -e is off, so every step is checked
# by hand. The previous install is kept as VCDS.previous (one generation)
# rather than deleted.
apply_update() {
    local installer="$1" tmp f rel
    setopt localoptions extendedglob
    tmp="$SUPPORT/vcds-update-tmp"
    rm -rf "$tmp"
    notify "Unpacking the new VCDS version…"
    extract_installer "$installer" "$tmp"
    while IFS= read -r -d '' rel; do
        rel="${rel#./}"
        [[ "$rel" == (#i)*.(exe|dll) ]] && continue
        [[ -e "$tmp/$rel" || -L "$tmp/$rel" ]] && continue   # case-insensitive fs
        mkdir -p "$tmp/${rel:h}" && cp -pP "$VCDS_DIR/$rel" "$tmp/$rel" \
            || { rm -rf "$tmp"; fail "Update stopped: could not carry over $rel. Your existing VCDS install is untouched."; }
    done < <(cd "$VCDS_DIR" && find . \( -type f -o -type l \) -print0)
    for f in "$VCDS_DIR"/(#i)*.(cfg|ini)(N.); do
        cp -p "$f" "$tmp/" \
            || { rm -rf "$tmp"; fail "Update stopped: could not carry over ${f:t}. Your existing VCDS install is untouched."; }
    done
    # Swap. VCDS.old only exists for the moment between the two moves; if
    # the Mac dies right there, recover_interrupted_update puts it back.
    rm -rf "$VCDS_DIR.old"
    mv "$VCDS_DIR" "$VCDS_DIR.old" \
        || { rm -rf "$tmp"; fail "Update failed -- your existing VCDS install is untouched."; }
    if mv "$tmp" "$VCDS_DIR"; then
        rm -rf "$VCDS_DIR.previous"
        mv "$VCDS_DIR.old" "$VCDS_DIR.previous" || true
    else
        mv "$VCDS_DIR.old" "$VCDS_DIR"
        fail "Update failed -- your existing VCDS install is untouched."
    fi
    notify "VCDS updated."
}

# An update that died between its two moves leaves no VCDS dir and the real
# install parked in VCDS.old. Put it back before anything decides this is a
# first run (which would then have the next update delete it).
recover_interrupted_update() {
    if [[ ! -e "$WINEPREFIX" && -d "$WINEPREFIX.old" ]]; then
        print -ru2 -- "recovering prefix from interrupted repair"
        mv "$WINEPREFIX.old" "$WINEPREFIX" || true
    fi
    if [[ ! -e "$VCDS_DIR" && -d "$VCDS_DIR.old" ]]; then
        print -ru2 -- "recovering VCDS install from interrupted update"
        mv "$VCDS_DIR.old" "$VCDS_DIR" || true
    fi
}

first_run() {
    local installer
    installer=$(choose_installer) || exit 0   # user cancelled
    installer="${installer%$'\n'}"

    osascript -e "display dialog \"Setting up — this one-time step takes a few minutes.\n\nYou'll get a notification at each stage, and VCDS will open when it's ready.\" buttons {\"OK\"} default button 1 with title \"$APP_NAME\" giving up after 15" >/dev/null 2>&1 || true

    # Send one throwaway multicast datagram NOW so macOS raises its Local
    # Network permission prompt during setup, attributed to this app. The
    # grant only applies to processes started after the user accepts -- if
    # VCDS itself triggers the prompt, its network side stays dead until the
    # app is relaunched (seen 2026-07-03 on a fresh account). Asking while
    # the environment is still being prepared means VCDS starts with the
    # permission already effective.
    print -n x | nc -u -w 1 224.0.0.251 5353 2>/dev/null || true

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

# True when every regular file under $1 exists under $2 at the same relative
# path with the same size -- the proof that a copy landed, whatever cp said.
copy_verified() {
    local src="$1" dst="$2" rel
    while IFS= read -r -d '' rel; do
        [[ -f "$dst/$rel" && "$(stat -f %z "$src/$rel")" == "$(stat -f %z "$dst/$rel")" ]] || return 1
    done < <(cd "$src" && find . -type f -print0)
}

# VCDS output lands somewhere a Mac user can find it: Logs, Scans and Debug
# live in ~/Documents/VCDS Logs and the prefix dirs are symlinks. Idempotent
# and run every launch so existing installs pick up newly mapped dirs.
map_output_dirs() {
    local mac_root="$HOME/Documents/VCDS Logs" d cperr
    [[ -d "$VCDS_DIR" ]] || return 0
    for d in Logs Scans Debug; do
        local target="$mac_root"
        [[ "$d" != "Logs" ]] && target="$mac_root/$d"
        # Per-machine override: the first line of $SUPPORT/dir-<Name> (e.g.
        # dir-Scans) redirects that folder anywhere -- say, a long-standing
        # archive. Lives outside the prefix, so it survives app updates and
        # VCDS reinstalls, unlike a hand-edited symlink.
        if [[ -s "$SUPPORT/dir-$d" ]]; then
            local override=""
            IFS= read -r override < "$SUPPORT/dir-$d" || true
            override="${override/#\~\//$HOME/}"
            [[ -n "$override" ]] && target="$override"
        fi
        if [[ -L "$VCDS_DIR/$d" ]]; then
            # Re-point when the override (or default) has changed; the files
            # themselves stay where they are -- moving archives is a human
            # decision, not a launcher's.
            [[ "$(readlink "$VCDS_DIR/$d")" == "$target" ]] && continue
            rm -f "$VCDS_DIR/$d"
        fi
        # macOS TCC can deny us ~/Documents -- then just leave VCDS's own
        # dirs in place (everything still works, files are only less visible).
        mkdir -p "$target" 2>/dev/null || { print -ru2 -- "map_output_dirs: no access to $target, skipping"; continue; }
        if [[ -d "$VCDS_DIR/$d" ]]; then
            # Copy first, delete ONLY if every file verifiably arrived -- a
            # partial copy (disk full, permission) must never cost the user
            # their scans. The check is on the result, not cp's exit status:
            # launched as the app, cp -a copies all the data yet exits non-
            # zero (metadata it may not set in ~/Documents), which kept the
            # dirs in the prefix forever (seen 2026-09, every launch).
            cperr=$(cp -a "$VCDS_DIR/$d/." "$target/" 2>&1) \
                || print -ru2 -- "map_output_dirs: cp of $d reported: ${cperr[1,500]}"
            if copy_verified "$VCDS_DIR/$d" "$target"; then
                rm -rf "$VCDS_DIR/$d"
            else
                print -ru2 -- "map_output_dirs: copy of $d incomplete, keeping prefix dir"
                continue
            fi
        fi
        ln -s "$target" "$VCDS_DIR/$d"
    done
}

# Single instance vs stale session. prefix_session_pids finds every DiagBridge
# wine process on this prefix, across builds (wine rewrites argv, so pgrep on
# the command line is NOT reliable). Two cases:
#  - VCDS itself is among them: it's genuinely running -- bring it to the
#    front and leave it alone (it may be mid-conversation with a car);
#  - session remnants but NO VCDS process (aftermath of a crash or force-
#    quit, or a stray from another build): sweep and boot normally. Without
#    this a wedged session made the app "open" to nothing until cleaned up by
#    hand -- and an orphaned service could peg a core unseen.
session_pids=$(prefix_session_pids)
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

# The x86 helpers (LCode, VCIConfig, VCDSScan) need Rosetta 2. Without it they
# die silently -- the i386 process falls back to the ARM loader and aborts in
# build_wow64_parameters -- so "Long Coding Helper does nothing" is the only
# symptom. macOS 27 upgrades have been seen to remove Rosetta (2026-09-16), so
# check every launch rather than once. VCDS itself runs fine without it.
check_rosetta() {
    [[ -n "${WINEHYBRIDX86:-}" && ! -f "$SUPPORT/no-rosetta-prompt" ]] || return 0
    arch -x86_64 /usr/bin/true 2>/dev/null && return 0
    print -ru2 -- "Rosetta 2 not available -- x86 helpers (LCode, VCIConfig, VCDSScan) will not start"
    local ans
    ans=$(osascript -e "display dialog \"Rosetta 2 is not installed.\n\nVCDS will run, but the Long Coding Helper and the interface Config screen need Rosetta and will not open without it. (macOS upgrades can remove it.)\" buttons {\"Don't Ask Again\", \"Not Now\", \"Install Rosetta…\"} default button 3 with title \"$APP_NAME\"" -e 'button returned of result' 2>/dev/null) || return 0
    case "$ans" in
        "Don't Ask Again") : >"$SUPPORT/no-rosetta-prompt" ;;
        "Install Rosetta…")
            notify "Installing Rosetta 2…"
            if osascript -e 'do shell script "/usr/sbin/softwareupdate --install-rosetta --agree-to-license" with administrator privileges' >/dev/null 2>&1 \
                && arch -x86_64 /usr/bin/true 2>/dev/null; then
                notify "Rosetta 2 installed."
            else
                notify "Rosetta 2 could not be installed -- try again from the next launch."
            fi ;;
    esac
}

# A prefix first set up WITHOUT Rosetta never gets its 32-bit half: wineboot
# builds syswow64 by running syswow64\rundll32.exe, an i386 program, which
# can't start without Rosetta -- and can't start later either, because it is
# the very file that pass creates. wineboot -u / --init on the existing
# prefix don't recover (verified 2026-09-28), so installing Rosetta
# afterwards left LCode/VCIConfig broken for good. Once Rosetta works,
# rebuild: fresh prefix, VCDS cloned across (APFS clone: instant, no extra
# space), verified, then swapped in. VCDS keeps its settings in its own
# folder; the registry holds nothing of the user's beyond VCIConfig's UI
# language.
repair_wow64_prefix() {
    [[ -n "${WINEHYBRIDX86:-}" && -f "$VCDS_DIR/VCDS-ARM.exe" ]] || return 0
    [[ -f "$WINEPREFIX/drive_c/windows/syswow64/rundll32.exe" ]] && return 0
    arch -x86_64 /usr/bin/true 2>/dev/null || return 0
    local new="$WINEPREFIX-new"
    print -ru2 -- "prefix has no 32-bit half (set up without Rosetta) -- rebuilding"
    notify "Repairing the Windows environment for Long Coding and Config (one-time)…"
    rm -rf "$new"
    WINEPREFIX="$new" "$WINELOADER_BIN" wineboot --init 2>/dev/null || true
    WINEPREFIX="$new" "$WINELOADER_BIN" regedit /S "$RES/seed/prefix.reg" 2>/dev/null || true
    WINEPREFIX="$new" "$WINESERVER" -w 2>/dev/null || true
    if [[ ! -f "$new/drive_c/windows/syswow64/rundll32.exe" ]]; then
        print -ru2 -- "repair: new prefix has no 32-bit half either -- keeping the old one"
        rm -rf "$new"; return 0
    fi
    rm -rf "$new/drive_c/Ross-Tech"
    if ! { cp -cRp "$WINEPREFIX/drive_c/Ross-Tech" "$new/drive_c/Ross-Tech" 2>/dev/null \
           || cp -Rp "$WINEPREFIX/drive_c/Ross-Tech" "$new/drive_c/Ross-Tech"; } \
       || [[ ! -f "$new/drive_c/Ross-Tech/VCDS/VCDS-ARM.exe" ]] \
       || ! copy_verified "$WINEPREFIX/drive_c/Ross-Tech" "$new/drive_c/Ross-Tech"; then
        print -ru2 -- "repair: could not carry VCDS across -- keeping the old prefix"
        rm -rf "$new"; return 0
    fi
    # Same two-step swap as apply_update; recover_interrupted_update undoes
    # a half-done one.
    rm -rf "$WINEPREFIX.old"
    mv "$WINEPREFIX" "$WINEPREFIX.old" || { rm -rf "$new"; return 0; }
    if mv "$new" "$WINEPREFIX"; then
        rm -rf "$WINEPREFIX.old"
        cat "$RES/build-id" 2>/dev/null >"$SUPPORT/installed-build" || true
        notify "Repair complete."
    else
        mv "$WINEPREFIX.old" "$WINEPREFIX"
    fi
}

recover_interrupted_update

# Before first run too: a prefix set up without Rosetta needs the rebuild
# below, so offer Rosetta before the one-time setup, not after it.
check_rosetta

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

repair_wow64_prefix

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

    # Self-update hand-off: VCDS downloads Ross-Tech's installer to
    # vcupg.exe in its own dir, launches it and quits. Tearing the session
    # down at that moment kills the installer mid-run and the update never
    # lands (seen 2026-08-27: 26.7.2 downloaded, VCDS stayed on 26.5.2).
    # Give it a moment to appear, wait for it to finish, then reopen VCDS.
    # Detected two ways: the installer process is alive, or a vcupg.exe newer
    # than this launch sits in the VCDS dir -- either means "this exit was an
    # update hand-off". The installer itself must NOT be allowed to do the
    # job: it is an i386 NSIS stub that, run under Wine, believes it is on
    # x64 Windows and installs the x86-64 build into C:\Ross-Tech\VCDS-Beta
    # (verified 2026-08-27) -- no VCDS-ARM.exe, wrong directory. So we stop
    # it and unpack the archive natively, exactly like first run does.
    updated=0 handoff=""
    for i in {1..15}; do pgrep -qf 'vcupg\.exe' && break; sleep 0.2; done
    if pgrep -qf 'vcupg\.exe'; then
        handoff=running        # the user said "install" inside VCDS
    elif [[ -f "$VCDS_DIR/vcupg.exe" && "$VCDS_DIR/vcupg.exe" -nt "$LOCKFILE" ]]; then
        handoff=file           # downloaded, but no installer running
    fi
    if [[ -n "$handoff" ]]; then
        print -ru2 -- "VCDS updater hand-off detected ($handoff)"
        pkill -f 'vcupg\.exe' 2>/dev/null || true
        for i in {1..25}; do pgrep -qf 'vcupg\.exe' || break; sleep 0.2; done
        end_session
        # A file with no running installer is ambiguous: the user may have
        # declined the update, or the installer died at once (no Rosetta).
        # Ask rather than install behind their back. Declining leaves the
        # file where it is; being older than the next launch's lock, it
        # won't prompt again.
        install=1
        if [[ "$handoff" == file ]]; then
            ans=$(osascript -e "display dialog \"VCDS downloaded an update. Install it now?\n\nYour settings, logs and activation are kept.\" buttons {\"Not Now\", \"Install\"} default button 2 with title \"$APP_NAME\" giving up after 120" -e 'button returned of result' 2>/dev/null) || ans=""
            [[ "$ans" == Install ]] || install=0
        fi
        # Only a complete download is worth unpacking; a truncated one (VCDS
        # interrupted mid-download) used to end in a scary "is this the
        # genuine VCDS download?" and a quit.
        if (( install )) && ! installer_complete "$VCDS_DIR/vcupg.exe"; then
            print -ru2 -- "vcupg.exe is incomplete or not a VCDS installer -- discarding"
            notify "The downloaded VCDS update was incomplete -- check for updates in VCDS again."
            rm -f "$VCDS_DIR/vcupg.exe"
            install=0
        fi
        if (( install )); then
            notify "Installing the VCDS update…"
            # Keep a copy outside the install dir: apply_update moves that aside.
            cp -f "$VCDS_DIR/vcupg.exe" "$SUPPORT/vcupg-pending.exe"
            rm -f "$VCDS_DIR/vcupg.exe"
            if apply_update "$SUPPORT/vcupg-pending.exe"; then
                rm -f "$SUPPORT/vcupg-pending.exe"
                # Whatever the stray installer managed to write before we stopped it.
                stray_beta="$WINEPREFIX/drive_c/Ross-Tech/VCDS-Beta"
                [[ -d "$stray_beta" && "$stray_beta" -nt "$LOCKFILE" ]] && rm -rf "$stray_beta"
                map_output_dirs
                updated=1
            fi
        fi
    fi

    # Full teardown on close: without this, winedevice/services keep the
    # session alive indefinitely (nothing may outlive the app).
    end_session
    if (( updated )); then
        notify "VCDS updated -- reopening."
        continue
    fi

    (( rc != 0 )) || [[ "$(crash_count)" != "$marks_before" ]] || break
    print -ru2 -- "abnormal VCDS exit rc=$rc -- offering reopen"
    ans=$(osascript -e "display dialog \"VCDS quit unexpectedly.\n\nThis can happen after an interface or communication glitch -- your logs and settings are safe.\" buttons {\"Close\", \"Reopen\"} default button \"Reopen\" cancel button \"Close\" with title \"$APP_NAME\" giving up after 60" 2>/dev/null) || break
    [[ "$ans" == *"button returned:Reopen"* ]] || break
done
exit 0
