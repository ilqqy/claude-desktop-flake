# Claude Desktop for NixOS, repackaged from Anthropic's official Linux .deb
# (beta, published in https://downloads.claude.ai/claude-desktop/apt/stable).
#
# Two layers:
#   unwrapped  the vendor tree (bundled Electron + app.asar) fixed up with
#              autoPatchelfHook. app.asar is shipped byte-for-byte unchanged.
#   (default)  a buildFHSEnv around it. The Code tab downloads its own
#              Claude Code CLI (glibc ELF, interpreter /lib64/ld-linux-*.so)
#              into ~/.config/Claude/claude-code/ at runtime, and the app
#              spawns /bin/bash, /usr/bin/pgrep, /usr/bin/secret-tool, ...
#              by absolute path. Neither works on plain NixOS; both do in FHS.
{
  lib,
  stdenv,
  fetchurl,
  dpkg,
  autoPatchelfHook,
  addDriverRunpath,
  makeWrapper,
  buildFHSEnv,
  runCommand,

  # DT_NEEDED of the bundled ELFs (objdump -p on 3.6556.2)
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  cairo,
  cups,
  dbus,
  expat,
  glib,
  gtk3,
  libcap_ng,
  libgbm,
  libseccomp,
  libx11,
  libxcb,
  libxcomposite,
  libxdamage,
  libxext,
  libxfixes,
  libxkbcommon,
  libxrandr,
  nspr,
  nss,
  pango,
  pipewire,
  systemd,

  # dlopen()ed at runtime, not in DT_NEEDED
  libGL,
  libayatana-appindicator,
  libnotify,
  libpulseaudio,
  libsecret,
  libuuid,
  libxtst,
  pciutils,
  wayland,

  # Tools the app (and the Claude Code sessions it starts) expect in the FHS
  bash,
  bubblewrap,
  coreutils,
  desktop-file-utils,
  git,
  gsettings-desktop-schemas,
  nodejs,
  openssh,
  procps,
  python3,
  socat,
  uv,
  xdg-utils,

  # Cowork (QEMU/KVM VM) — off by default, adds ~1.5 GB to the closure
  withCowork ? false,
  OVMF,
  qemu_kvm,
  virtiofsd,

  # Extra packages to put into the FHS env, e.g. `pkgs: [ pkgs.docker ]`
  extraPkgs ? pkgs: [ ],
}:

let
  # BEGIN update.sh — this block is rewritten by ./update.sh, do not edit by hand
  version = "3.6556.2";
  srcs = {
    x86_64-linux = {
      arch = "amd64";
      hash = "sha256-D27R8oRcMEGbhUWoMgZ210ZKGfYl4F4CkZI4qml47LQ=";
    };
    aarch64-linux = {
      arch = "arm64";
      hash = "sha256-W3CutrszWz1GhO0QataMfaRP86pH/42y/v5VvegQwQs=";
    };
  };
  # END update.sh

  pool = "https://downloads.claude.ai/claude-desktop/apt/stable/pool/main/c/claude-desktop";
  srcFor =
    system:
    let
      s = srcs.${system} or (throw "claude-desktop: unsupported system ${system}");
    in
    fetchurl {
      url = "${pool}/claude-desktop_${version}_${s.arch}.deb";
      inherit (s) hash;
    };

  meta = {
    description = "Claude Desktop (Chat, Code, Cowork) — unofficial Nix repack of Anthropic's Linux beta .deb";
    homepage = "https://code.claude.com/docs/en/desktop-linux";
    downloadPage = "https://downloads.claude.ai/claude-desktop/apt/stable";
    license = lib.licenses.unfree;
    sourceProvenance = [ lib.sourceTypes.binaryNativeCode ];
    platforms = builtins.attrNames srcs;
    mainProgram = "claude-desktop";
  };

  # Wayland: Electron >= 38 already defaults to --ozone-platform=auto, and
  # the bundled Electron 44 no longer knows --ozone-platform-hint at all, so
  # NIXOS_OZONE_WL forces native Wayland explicitly and turns on IME.
  ozoneFlags = ''
    if [[ -n "''${NIXOS_OZONE_WL:-}" && -n "''${WAYLAND_DISPLAY:-}" ]]; then
      set -- --ozone-platform=wayland --enable-wayland-ime=true "$@"
    fi
  '';

  unwrapped = stdenv.mkDerivation {
    pname = "claude-desktop-unwrapped";
    inherit version;

    src = srcFor stdenv.hostPlatform.system;

    nativeBuildInputs = [
      dpkg
      autoPatchelfHook
      makeWrapper
    ];

    buildInputs = [
      alsa-lib
      at-spi2-atk
      at-spi2-core
      atk
      cairo
      cups
      dbus
      expat
      glib
      gtk3
      libcap_ng
      libgbm
      libseccomp
      libx11
      libxcb
      libxcomposite
      libxdamage
      libxext
      libxfixes
      libxkbcommon
      libxrandr
      nspr
      nss
      pango
      pipewire
      stdenv.cc.cc.lib # libstdc++ / libgcc_s (node-pty)
      systemd # libudev
    ];

    runtimeDependencies = map lib.getLib [
      libGL
      libayatana-appindicator
      libnotify
      libpulseaudio
      libsecret
      libuuid
      libxtst
      pciutils
      pipewire
      systemd
      wayland
    ];

    # Chromium's GL/Vulkan code dlopen()s libGL/libEGL from shared objects,
    # whose runpath autoPatchelf's runtimeDependencies does not touch.
    appendRunpaths = [
      "${lib.getLib libGL}/lib"
      "${addDriverRunpath.driverLink}/lib"
    ];

    # chrome-sandbox is SUID in data.tar; the store can't hold that, and tar
    # can't restore it in the sandbox. Chromium uses the userns sandbox.
    unpackPhase = ''
      runHook preUnpack
      dpkg-deb --fsys-tarfile "$src" | tar -x --no-same-owner --no-same-permissions
      runHook postUnpack
    '';

    dontConfigure = true;
    dontBuild = true;
    dontStrip = true;

    # The ELF must stay a real file next to resources/: Electron derives
    # process.resourcesPath from /proc/self/exe, and the app reads its
    # locale JSONs and helpers from there.
    installPhase = ''
      runHook preInstall

      mkdir -p $out/bin $out/share
      cp -a usr/lib $out/lib
      cp -a usr/share/applications usr/share/icons $out/share/
      install -Dm644 $out/lib/claude-desktop/resources/icon.png \
        $out/share/icons/hicolor/512x512/apps/claude-desktop.png

      # The bundled libvulkan.so.1 only searches FHS ICD dirs.
      makeWrapper $out/lib/claude-desktop/claude-desktop $out/bin/claude-desktop \
        --prefix VK_ADD_DRIVER_FILES : "${addDriverRunpath.driverLink}/share/vulkan/icd.d" \
        --run ${lib.escapeShellArg ozoneFlags}

      runHook postInstall
    '';

    preFixup = ''
      addAutoPatchelfSearchPath $out/lib/claude-desktop
    '';

    meta = meta // {
      description = "${meta.description} (without FHS env)";
    };
  };

  # Cowork probes these exact firmware paths and wants CODE+VARS side by side.
  ovmfCompat = runCommand "claude-desktop-ovmf-compat" { } (
    if stdenv.hostPlatform.isx86_64 then
      ''
        mkdir -p $out/share/OVMF
        for n in CODE VARS; do
          ln -s ${OVMF.fd}/FV/OVMF_$n.fd $out/share/OVMF/OVMF_$n.fd
          ln -s ${OVMF.fd}/FV/OVMF_$n.fd $out/share/OVMF/OVMF_''${n}_4M.fd
        done
      ''
    else
      ''
        mkdir -p $out/share/AAVMF
        for n in CODE VARS; do
          ln -s ${OVMF.fd}/FV/AAVMF_$n.fd $out/share/AAVMF/AAVMF_$n.fd
        done
      ''
  );
in
buildFHSEnv {
  pname = "claude-desktop";
  inherit version;

  targetPkgs =
    pkgs:
    [
      unwrapped
      bash
      bubblewrap
      coreutils
      desktop-file-utils
      git
      # GTK aborts in file dialogs without compiled GSettings schemas;
      # buildFHSEnv compiles /usr/share/glib-2.0/schemas from these
      gsettings-desktop-schemas
      gtk3
      libsecret
      nodejs
      openssh
      procps
      python3
      socat
      systemd
      uv
      xdg-utils
    ]
    ++ lib.optionals withCowork [
      ovmfCompat
      qemu_kvm
      virtiofsd
    ]
    ++ extraPkgs pkgs;

  runScript = "${unwrapped}/bin/claude-desktop";

  # Keep the upstream file name: the app looks for
  # /usr/share/applications/com.anthropic.Claude.desktop and checks
  # mimeapps.list for x-scheme-handler/claude against that id. Exec stays
  # PATH-relative (claude-desktop), which resolves to this FHS wrapper.
  extraInstallCommands = ''
    mkdir -p $out/share
    cp -r ${unwrapped}/share/applications ${unwrapped}/share/icons $out/share/
  '';

  passthru = { inherit unwrapped; };

  inherit meta;
}
