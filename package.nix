{
  lib,
  stdenv,
  fetchurl,
  p7zip,
  asar,
  nodejs_20,
  python3,
  makeWrapper,
  electron_40,
  gnumake,
  pkg-config,
}: let
  betterSqlite3Version = "12.5.0";
  nodePtyVersion = "1.1.0";

  betterSqlite3Src = fetchurl {
    url = "https://registry.npmjs.org/better-sqlite3/-/better-sqlite3-${betterSqlite3Version}.tgz";
    hash = "sha256-CjzQVUsGPDGFuZEu9wWbhEVaLkEdY3+qAWb++f76BMI=";
  };

  nodePtySrc = fetchurl {
    url = "https://registry.npmjs.org/node-pty/-/node-pty-${nodePtyVersion}.tgz";
    hash = "sha256-x1F/GQg93LBfJ2kEaA6ysRprXsq3eLjk5WhabWRbP2A=";
  };
in
  stdenv.mkDerivation {
    pname = "codex-desktop";
    version = "0-unstable-2026-03-19";

    src = fetchurl {
      url = "https://persistent.oaistatic.com/codex-app-prod/Codex.dmg";
      hash = "sha256-69+E08+EjcTFwUKlpqZBw2PgzeltZeMTFG7ruD7ITHI=";
    };

    nativeBuildInputs = [
      p7zip
      asar
      nodejs_20
      python3
      makeWrapper
      electron_40
      gnumake
      pkg-config
    ];

    buildInputs = [
      nodejs_20
      python3
    ];

    unpackPhase = ''
      # src is the Codex.dmg file - extract it
      mkdir -p dmg-extract
      echo "Extracting DMG from: $src"
      echo "Source file size: $(du -h "$src" | cut -f1)"

      # Try to extract DMG
      rc=0
      7z x -y "$src" -o"dmg-extract" 2>&1 || rc=$?
      if [ $rc -le 2 ]; then
        # rc=1: warnings; rc=2: HFS+ header errors — both are non-fatal when the
        # .app bundle is present (verified below).
        echo "7z exited with rc=$rc (non-fatal), continuing"
      elif [ $rc -gt 2 ]; then
        echo "7z fatal error (exit code $rc)"
        exit 1
      fi

      # Find the .app bundle (it's usually in Codex Installer/)
      APP_PATH=$(find dmg-extract -name "Codex.app" -type d | head -1)

      if [ -z "$APP_PATH" ]; then
        echo "Error: Could not find .app bundle in DMG"
        echo "All directories in dmg-extract:"
        find dmg-extract -type d
        exit 1
      fi

      echo "Found app at: $APP_PATH"

      # Copy app to current directory for processing
      cp -r "$APP_PATH" ./Codex.app
      rm -rf dmg-extract
    '';

    patchPhase = ''
      # Extract app.asar from the Resources directory
      RESOURCES_DIR="./Codex.app/Contents/Resources"

      if [ ! -f "$RESOURCES_DIR/app.asar" ]; then
        echo "Error: app.asar not found at $RESOURCES_DIR/app.asar"
        exit 1
      fi

      # Extract asar
      ${asar}/bin/asar extract "$RESOURCES_DIR/app.asar" app-extracted

      # Copy any unpacked resources
      if [ -d "$RESOURCES_DIR/app.asar.unpacked" ]; then
        cp -r "$RESOURCES_DIR/app.asar.unpacked/"* app-extracted/ 2>/dev/null || true
      fi

      # Remove macOS-only modules
      echo "Removing macOS-only modules..."
      rm -rf app-extracted/node_modules/sparkle-darwin 2>/dev/null || true
      find app-extracted -name "sparkle.node" -delete 2>/dev/null || true

      # Ensure pinned rebuild module versions still match the bundled app.
      appBetterSqlite3Version="$(${nodejs_20}/bin/node -p "require('./app-extracted/node_modules/better-sqlite3/package.json').version")"
      appNodePtyVersion="$(${nodejs_20}/bin/node -p "require('./app-extracted/node_modules/node-pty/package.json').version")"
      if [ "$appBetterSqlite3Version" != "${betterSqlite3Version}" ]; then
        echo "Error: better-sqlite3 version mismatch. App has $appBetterSqlite3Version, package expects ${betterSqlite3Version}."
        exit 1
      fi
      if [ "$appNodePtyVersion" != "${nodePtyVersion}" ]; then
        echo "Error: node-pty version mismatch. App has $appNodePtyVersion, package expects ${nodePtyVersion}."
        exit 1
      fi

      # Remove pre-compiled macOS native .node files (will be rebuilt for Linux)
      echo "Removing pre-compiled macOS native modules..."
      find app-extracted -name "*.node" -delete 2>/dev/null || true
    '';

    configurePhase = ''
      echo "Preparing for native module compilation..."
      export HOME=$TMPDIR
    '';

    buildPhase = ''
      cd app-extracted

      # Configure npm for Electron-specific native module compilation
      export npm_config_target=${electron_40.version}
      export npm_config_runtime=electron
      export npm_config_nodedir=${electron_40.headers}
      export HOME=$TMPDIR

      build_native_module() {
        local module_name="$1"
        local module_tarball="$2"

        echo "Building $module_name for Electron..."
        rm -rf "node_modules/$module_name"
        mkdir -p "node_modules/$module_name"
        tar -xzf "$module_tarball" --strip-components=1 -C "node_modules/$module_name"
        cd "node_modules/$module_name"
        ${nodejs_20}/bin/node ${nodejs_20}/lib/node_modules/npm/node_modules/node-gyp/bin/node-gyp.js rebuild --release
        cd ../..
      }

      build_native_module better-sqlite3 ${betterSqlite3Src}
      build_native_module node-pty ${nodePtySrc}

      cd ..

      # Repack app.asar with rebuilt native modules
      echo "Repacking app.asar with native modules..."
      ${asar}/bin/asar pack \
        app-extracted \
        repacked.asar \
        --unpack "**/*.{node,so,dylib}"

      echo "Build complete"
    '';

    installPhase = ''
      mkdir -p $out/lib/codex-desktop
      mkdir -p $out/bin
      mkdir -p $out/share/applications

      # Copy Electron binary and resources from electron_40
      echo "Setting up Electron 40..."
      cp ${electron_40}/libexec/electron/electron $out/lib/codex-desktop/

      # Copy all Electron resources and supporting files
      mkdir -p $out/lib/codex-desktop/resources

      # Copy pak files and other resources
      for f in ${electron_40}/libexec/electron/*.pak; do
        [ -e "$f" ] && cp "$f" $out/lib/codex-desktop/
      done

      # Copy data files
      for f in ${electron_40}/libexec/electron/*.dat; do
        [ -e "$f" ] && cp "$f" $out/lib/codex-desktop/
      done

      # Copy v8 snapshot
      for f in ${electron_40}/libexec/electron/v8_context_snapshot*.bin; do
        [ -e "$f" ] && cp "$f" $out/lib/codex-desktop/
      done
      for f in ${electron_40}/libexec/electron/snapshot_blob*.bin; do
        [ -e "$f" ] && cp "$f" $out/lib/codex-desktop/
      done

      # Copy locales required by Chromium runtime
      if [ -d "${electron_40}/libexec/electron/locales" ]; then
        cp -r "${electron_40}/libexec/electron/locales" $out/lib/codex-desktop/
      fi

      # Copy crashpad handler
      if [ -f "${electron_40}/libexec/electron/chrome_crashpad_handler" ]; then
        cp "${electron_40}/libexec/electron/chrome_crashpad_handler" $out/lib/codex-desktop/
      fi

      # Copy any other necessary binaries and shared libraries
      for bin in ${electron_40}/libexec/electron/chrome_*.so ${electron_40}/libexec/electron/libEGL*.so* ${electron_40}/libexec/electron/libGLES*.so* ${electron_40}/libexec/electron/libffmpeg*.so* ${electron_40}/libexec/electron/libvk_swiftshader*.so* ${electron_40}/libexec/electron/libvulkan*.so*; do
        [ -e "$bin" ] && cp "$bin" $out/lib/codex-desktop/ 2>/dev/null || true
      done

      # Copy patched app.asar
      if [ -f repacked.asar ]; then
        cp repacked.asar $out/lib/codex-desktop/resources/app.asar
        if [ -d repacked.asar.unpacked ]; then
          cp -r repacked.asar.unpacked $out/lib/codex-desktop/resources/app.asar.unpacked
        fi
        if [ -f app-extracted/node_modules/better-sqlite3/build/Release/better_sqlite3.node ]; then
          mkdir -p $out/lib/codex-desktop/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release
          cp app-extracted/node_modules/better-sqlite3/build/Release/better_sqlite3.node \
            $out/lib/codex-desktop/resources/app.asar.unpacked/node_modules/better-sqlite3/build/Release/
        fi
        if [ -d app-extracted/node_modules/node-pty/build/Release ]; then
          mkdir -p $out/lib/codex-desktop/resources/app.asar.unpacked/node_modules/node-pty/build/Release
          cp -r app-extracted/node_modules/node-pty/build/Release/* \
            $out/lib/codex-desktop/resources/app.asar.unpacked/node_modules/node-pty/build/Release/
        fi
      elif [ -f "Codex.app/Contents/Resources/app.asar" ]; then
        cp "Codex.app/Contents/Resources/app.asar" $out/lib/codex-desktop/resources/app.asar
      else
        echo "Error: No app.asar found"
        exit 1
      fi

      # Copy webview content
      if [ -d "app-extracted/webview" ]; then
        mkdir -p $out/lib/codex-desktop/content/webview
        cp -r app-extracted/webview/* $out/lib/codex-desktop/content/webview/
      fi

      # Create launcher script with proper library paths.
      # Nix string escaping note: ${electron_40} and ${python3} are Nix store-path
      # interpolations resolved at build time. Runtime bash variables use $VAR (no braces)
      # or ''${VAR} (Nix ''$ escape) to prevent Nix from treating them as interpolations.
      cat > $out/bin/codex-desktop << 'WRAPPER'
#!/bin/bash
# electron_40 and python3 references below are baked-in Nix store paths (build-time).
# Runtime bash variables use dollar-brace syntax; only Nix-known names are interpolated.
export LD_LIBRARY_PATH="${electron_40}/lib:${electron_40}/libexec/electron''${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export NIXOS_OZONE_WL=1
# auto-detect Wayland vs X11 rather than forcing one platform
export ELECTRON_OZONE_PLATFORM_HINT=auto
# Prevent shell auto-start hooks from attaching zellij in Codex terminals.
# Override by setting ZELLIJ=1 in your environment before launching.
export ZELLIJ=''${ZELLIJ:-0}

APPDIR="$(dirname "$(dirname "$(readlink -f "$0")")")"
WEBVIEW_DIR="$APPDIR/lib/codex-desktop/content/webview"

if [ -d "$WEBVIEW_DIR" ] && [ -n "$(ls -A "$WEBVIEW_DIR" 2>/dev/null)" ]; then
  cd "$WEBVIEW_DIR"
  # Verify port 5175 is free before binding. A pre-existing listener could be a
  # malicious process; silently connecting to it would serve untrusted webview content.
  if ${python3}/bin/python3 -c \
      "import socket; s=socket.socket(); s.setsockopt(socket.SOL_SOCKET,socket.SO_REUSEADDR,0); s.bind(('127.0.0.1',5175)); s.close()" \
      2>/dev/null; then
    ${python3}/bin/python3 -m http.server 5175 --bind 127.0.0.1 > /dev/null 2>&1 &
    HTTP_PID=$!
    trap "kill $HTTP_PID 2>/dev/null" EXIT
  else
    echo "Warning: Port 5175 already in use; webview HTTP server not started." >&2
  fi
fi

if [ -z "''${CODEX_CLI_PATH:-}" ]; then
  if command -v codex >/dev/null 2>&1; then
    export CODEX_CLI_PATH="$(command -v codex)"
  else
    echo "Warning: Codex CLI not found. Install with: npm i -g @openai/codex" >&2
  fi
fi

cd "$APPDIR/lib/codex-desktop"
# --no-sandbox: required on NixOS where no SUID sandbox helper is available.
# On distros where the helper exists, set CODEX_ENABLE_SANDBOX=1 to omit this flag.
# See https://github.com/electron/electron/issues/17972
if [ -z "''${CODEX_ENABLE_SANDBOX:-}" ]; then
  exec "$APPDIR/lib/codex-desktop/electron" \
    --no-sandbox \
    --enable-wayland-ime \
    resources/app.asar "$@"
else
  exec "$APPDIR/lib/codex-desktop/electron" \
    --enable-wayland-ime \
    resources/app.asar "$@"
fi
WRAPPER
      chmod +x $out/bin/codex-desktop

      # Create .desktop file
      desktopFile="$out/share/applications/codex-desktop.desktop"
      {
        echo "[Desktop Entry]"
        echo "Name=Codex Desktop"
        echo "Exec=$out/bin/codex-desktop"
        echo "Icon=text-editor"
        echo "Type=Application"
        echo "Categories=Development;IDE;"
        echo "StartupWMClass=Codex"
        echo "Comment=OpenAI Codex Desktop Application"
      } > "$desktopFile"
    '';

    dontStrip = true;
    dontPatchELF = true;

    meta = {
      description = "OpenAI Codex Desktop for Linux";
      homepage = "https://github.com/y0usaf/codex-desktop-flake";
      # MIT applies to this packaging flake only. Codex Desktop itself is proprietary OpenAI software.
      license = lib.licenses.mit;
      platforms = ["x86_64-linux" "aarch64-linux"];
      # Not in nixpkgs; maintained at https://github.com/y0usaf/codex-desktop-flake
      maintainers = with lib.maintainers; [];
    };
  }
