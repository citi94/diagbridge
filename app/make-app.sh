#!/bin/zsh
# Assemble the self-contained .app from the ARM64 wine build tree.
#
#   APP_NAME=DiagBridge IDENTITY="Developer ID Application: ..." ./make-app.sh
#
# APP_NAME default is a PLACEHOLDER -- final name is Peter's call and must not
# use VCDS / Ross-Tech / VW / VAG marks (see PACKAGING.md, Branding).
# Without IDENTITY the bundle is ad-hoc signed (local testing only).
set -euo pipefail

APP_NAME="${APP_NAME:-DiagBridge}"
BUNDLE_ID="${BUNDLE_ID:-uk.harding.diagbridge}"
VERSION="${VERSION:-0.2.0}"
IDENTITY="${IDENTITY:--}"                 # "-" = ad-hoc

HERE="${0:A:h}"
ARM_PORT="${HERE:h}"
BUILD="$ARM_PORT/build"
DIST="$ARM_PORT/dist"
APP="$DIST/$APP_NAME.app"
C="$APP/Contents"
ENTITLEMENTS="$HERE/entitlements-dist.plist"

echo "==> Staging wine install"
STAGING="$DIST/staging"
rm -rf "$APP" "$STAGING"
mkdir -p "$C/MacOS" "$C/Resources/extractor" "$C/Resources/seed" "$C/Resources/licenses" "$C/Resources/libs"
make -C "$BUILD" install-lib DESTDIR="$STAGING" prefix=/wine -j"$(sysctl -n hw.ncpu)" >/dev/null
cp -a "$STAGING/wine" "$C/Resources/wine"

echo "==> Hybrid x86 slice (i386 helpers via Rosetta 2)"
# The x86_64 build tree contributes its loader + unix .so's and the
# x86_64/i386 PE trees. All its .so's link against system libs only; the
# universal dylibs in Resources/libs cover freetype/gnutls for both arches.
BUILD_X86="$ARM_PORT/build-x86_64"
if [[ -d "$BUILD_X86" ]]; then
    make -C "$BUILD_X86" install-lib DESTDIR="$STAGING-x86" prefix=/wine -j"$(sysctl -n hw.ncpu)" >/dev/null
    for d in x86_64-unix x86_64-windows i386-windows; do
        rm -rf "$C/Resources/wine/lib/wine/$d"
        cp -a "$STAGING-x86/wine/lib/wine/$d" "$C/Resources/wine/lib/wine/$d"
    done
    rm -rf "$STAGING-x86"

    # Prune to the helpers' measured DLL closure. x86-keep-list.txt is the
    # union of +loaddll captures (VCIConfig, VCDSScan, LCode, LCode-Classic,
    # CSVConv-64, fresh-prefix wow64 boot) + static import closure + an
    # insurance set (printing, network, crypto, winedbg, comctl32_v6, xml).
    # Regenerate with scratchpad closure.py if helpers gain features.
    KEEP_LIST="$HERE/x86-keep-list.txt"
    if [[ -f "$KEEP_LIST" ]]; then
        for d in x86_64-windows i386-windows; do
            find "$C/Resources/wine/lib/wine/$d" -type f | while read -r f; do
                grep -qixF "$(basename "$f")" "$KEEP_LIST" || rm "$f"
            done
            echo "    $d pruned to $(ls "$C/Resources/wine/lib/wine/$d" | wc -l | tr -d ' ') files"
        done
    fi
else
    echo "    (no build-x86_64 -- x86-only VCDS helpers will fail fast)"
fi

echo "==> Stripping debug info (PE DWARF + Mach-O debug symbols)"
# PE builtins carry full DWARF (~2/3 of their size). Crash RVAs from stripped
# binaries still symbolize against the unstripped build tree.
LLVM_STRIP=/opt/homebrew/opt/llvm/bin/llvm-strip
find "$C/Resources/wine/lib/wine" -type f \( -name '*.dll' -o -name '*.exe' -o -name '*.sys' -o -name '*.drv' -o -name '*.ocx' -o -name '*.cpl' -o -name '*.acm' -o -name '*.ax' \) \
    -exec "$LLVM_STRIP" --strip-debug {} \; 2>/dev/null || true
find "$C/Resources/wine" -type f \( -name '*.so' -o -name '*.dylib' \) \
    -exec "$LLVM_STRIP" --strip-debug {} \; 2>/dev/null || true
for f in "$C/Resources/wine/bin/"*; do
    file -b "$f" | grep -q Mach-O && "$LLVM_STRIP" --strip-debug "$f" 2>/dev/null || true
done
du -sh "$C/Resources/wine" | awk '{print "    wine tree after strip: " $1}'

echo "==> Loader into MacOS/ (bundle identity for Dock/menu bar)"
# The Dock and menu-bar bold name come from the GUI process's executable name.
# So the REAL loader binary (lib/wine/aarch64-unix/wine -- bin/wine re-execs
# and loses identity) is named after the app itself; the first-run script is a
# separate "-setup" executable that CFBundleExecutable points at and which
# exec()s the loader.
cp "$C/Resources/wine/lib/wine/aarch64-unix/wine" "$C/MacOS/$APP_NAME"
cp "$HERE/launcher.sh" "$C/MacOS/$APP_NAME-setup"
chmod +x "$C/MacOS/$APP_NAME" "$C/MacOS/$APP_NAME-setup"
# The loader wants ntdll.so beside itself; the rest of the tree resolves from
# ntdll.so's real location. lib/share for data files (fonts, nls).
ln -sfn ../Resources/wine/lib/wine/aarch64-unix/ntdll.so "$C/MacOS/ntdll.so"
ln -sfn Resources/wine/lib "$C/lib"
ln -sfn Resources/wine/share "$C/share"

echo "==> Bundling dylib closure (freetype + gnutls)"
# Prefer the prepared universal (arm64+x86_64) closure -- Rosetta processes
# in the hybrid slice need the x86_64 halves, and homebrew only ships arm64.
if [[ -d "$HERE/libs-universal" ]]; then
    cp -a "$HERE/libs-universal/." "$C/Resources/libs/"
    echo "    using prepared universal closure ($(ls "$HERE/libs-universal" | wc -l | tr -d ' ') dylibs)"
else
python3 - "$C/Resources/libs" <<'EOF'
import subprocess, os, sys, shutil
dest = sys.argv[1]
roots = ['/opt/homebrew/opt/freetype/lib/libfreetype.6.dylib',
         '/opt/homebrew/opt/gnutls/lib/libgnutls.30.dylib']
seen = {}
def walk(p):
    p = os.path.realpath(p)
    if p in seen: return
    seen[p] = True
    for line in subprocess.run(['otool','-L',p],capture_output=True,text=True).stdout.splitlines()[1:]:
        d = line.strip().split(' (')[0]
        if d.startswith('/opt/homebrew'): walk(d)
for r in roots: walk(r)
mapping = {}   # original install path fragment -> basename
for p in seen:
    out = os.path.join(dest, os.path.basename(p))
    shutil.copy2(p, out)
    os.chmod(out, 0o755)
    mapping[os.path.basename(p)] = out
for name, out in mapping.items():
    subprocess.run(['install_name_tool','-id', f'@loader_path/{name}', out], check=True)
    for line in subprocess.run(['otool','-L',out],capture_output=True,text=True).stdout.splitlines()[1:]:
        d = line.strip().split(' (')[0]
        if d.startswith('/opt/homebrew'):
            base = os.path.basename(os.path.realpath(d))
            subprocess.run(['install_name_tool','-change', d, f'@loader_path/{base}', out], check=True)
print(f'bundled {len(mapping)} dylibs')
EOF
fi

echo "==> Build id (launcher refreshes the prefix DLL copies when it changes)"
BUILD_ID="$VERSION+$(git -C "$ARM_PORT/wine-src" rev-parse --short HEAD 2>/dev/null || echo nogit).$(date +%Y%m%d%H%M)"
print -r -- "$BUILD_ID" > "$C/Resources/build-id"
echo "    $BUILD_ID"

echo "==> Extractor, seeds, licenses"
# Prefer the standalone 7zz; fall back to p7zip's 7z for local testing.
if [[ -x /opt/homebrew/bin/7zz ]]; then cp /opt/homebrew/bin/7zz "$C/Resources/extractor/7zz"
else cp /opt/homebrew/bin/7z "$C/Resources/extractor/7zz"; fi
cp "$HERE/prefix-seed.reg" "$C/Resources/seed/prefix.reg"
cp "$HERE/AppIcon.icns" "$C/Resources/AppIcon.icns"
# Full third-party licence texts + component manifest (licenses-dist/ is
# assembled from the exact kegs/sources the bundle is built against --
# regenerate it if any bundled component version changes).
cp "$HERE/licenses-dist/"* "$C/Resources/licenses/"
cat > "$C/Resources/licenses/SOURCE-OFFER.txt" <<TXT
This application contains Wine, modified for native ARM64 macOS.
Wine is free software under the GNU LGPL 2.1 or later.
Complete corresponding source of the modified Wine:
  https://github.com/citi94/wine-macos-arm64  (branch macos-arm64-port)
For every other open-source component (7-Zip, FreeType, GnuTLS and its
dependencies, libusb), see THIRD-PARTY-LICENSES.txt in this folder; the
exact source tarballs are attached to each release at
  https://github.com/citi94/diagbridge/releases
This application contains NO Ross-Tech software. VCDS is a product of
Ross-Tech LLC and must be obtained from them by the user.
TXT

echo "==> Info.plist"
cat > "$C/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>$APP_NAME</string>
    <key>CFBundleDisplayName</key><string>$APP_NAME</string>
    <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleExecutable</key><string>$APP_NAME-setup</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSArchitecturePriority</key><array><string>arm64</string></array>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSHumanReadableCopyright</key><string>Wine is © the Wine project (LGPL). This app ships no Ross-Tech software.</string>
</dict>
</plist>
PLIST

echo "==> Signing (identity: $IDENTITY)"
# Inside-out: every Mach-O first, bundle last. PE files (.dll/.sys/.exe) are
# data to codesign and are left alone. Real identities get Apple secure
# timestamps (required for notarization); ad-hoc skips them (no network).
SIGN=( codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" )
[[ "$IDENTITY" != "-" ]] && SIGN+=( --timestamp )
find "$C/Resources/libs" "$C/Resources/wine" -type f \( -name '*.dylib' -o -name '*.so' -o -perm +111 \) | while read -r f; do
    file -b "$f" | grep -q Mach-O || continue
    "${SIGN[@]}" "$f" 2>/dev/null
done
"${SIGN[@]}" "$C/Resources/extractor/7zz"
"${SIGN[@]}" "$C/MacOS/$APP_NAME"

echo "==> APFS transparent compression (decmpfs, ~4:1 on Wine binaries)"
# Compression is invisible to codesign (logical content unchanged) and is
# preserved by Finder drag-install -- but only if every later copy uses
# ditto --hfsCompression; cp -a and plain ditto DECOMPRESS. Signed Mach-Os
# compress fine; the bundle seal is written after, so it is always valid.
COMP_TMP="$DIST/.compress-tmp"
rm -rf "$COMP_TMP"
ditto --hfsCompression "$APP" "$COMP_TMP"
rm -rf "$APP"
mv "$COMP_TMP" "$APP"
du -sh "$APP" | awk '{print "    app after compression: " $1}'

"${SIGN[@]}" "$APP"
codesign --verify --strict "$APP" && echo "    bundle seal verified"

rm -rf "$STAGING"

if [[ "${MAKE_DMG:-1}" == "1" ]]; then
    echo "==> DMG (LZMA -- the distribution download)"
    DMG="$DIST/$APP_NAME-$VERSION.dmg"
    DMG_STAGE="$DIST/dmg-stage"
    DMG_RW="$DIST/dmg-rw.dmg"
    rm -rf "$DMG_STAGE" "$DMG" "$DMG_RW"
    mkdir -p "$DMG_STAGE"
    # ditto --hfsCompression, NOT cp -a: cp decompresses, and the install
    # would balloon back to full size after the user drags it out.
    ditto --hfsCompression "$APP" "$DMG_STAGE/$APP_NAME.app"
    ln -s /Applications "$DMG_STAGE/Applications"
    cp "$HERE/AppIcon.icns" "$DMG_STAGE/.VolumeIcon.icns"
    # Build read-write first so Finder can lay the window out, then convert.
    hdiutil create -volname "$APP_NAME" -srcfolder "$DMG_STAGE" -format UDRW -fs APFS -o "$DMG_RW" -quiet
    MNT=$(hdiutil attach "$DMG_RW" -nobrowse | awk -F'\t' '/\/Volumes\//{print $NF}')
    if [[ -n "$MNT" ]]; then
        /usr/bin/SetFile -a C "$MNT" 2>/dev/null || true   # use .VolumeIcon.icns
        osascript >/dev/null 2>&1 <<EOF || true
tell application "Finder"
    tell disk "$APP_NAME"
        open
        set current view of container window to icon view
        set toolbar visible of container window to false
        set statusbar visible of container window to false
        set the bounds of container window to {200, 200, 760, 480}
        set opts to the icon view options of container window
        set icon size of opts to 104
        set arrangement of opts to not arranged
        set position of item "$APP_NAME.app" of container window to {150, 130}
        set position of item "Applications" of container window to {410, 130}
        close
    end tell
end tell
EOF
        sync
        hdiutil detach "$MNT" -quiet || hdiutil detach "$MNT" -force -quiet || true
    fi
    hdiutil convert "$DMG_RW" -format ULMO -o "$DMG" -quiet
    rm -rf "$DMG_STAGE" "$DMG_RW"
    # Sign the DMG itself (Gatekeeper assesses the container too).
    [[ "$IDENTITY" != "-" ]] && codesign --force --timestamp --sign "$IDENTITY" "$DMG"
    echo "    $(du -sh "$DMG" | awk '{print $1}')  $DMG"
fi

echo "==> Done: $APP ($(du -sh "$APP" | awk '{print $1}'))"
echo "    Notarize with: xcrun notarytool submit --wait + xcrun stapler staple (Developer ID builds)"
