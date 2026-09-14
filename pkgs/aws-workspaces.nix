# Amazon WorkSpaces DCV client, repackaged from AWS's Ubuntu 22.04 .deb.

{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
  makeBinaryWrapper,
  buildFHSEnv,
  glib-networking,
  alsa-lib,
  at-spi2-atk,
  at-spi2-core,
  atk,
  brotli,
  cairo,
  cups,
  dbus,
  elfutils,
  gdk-pixbuf,
  gst_all_1,
  gtk3,
  jbigkit,
  libdeflate,
  libdrm,
  libgbm,
  libgudev,
  libpng,
  libpulseaudio,
  libselinux,
  libthai,
  libunwind,
  libva,
  libvdpau,
  libxml2,
  nspr,
  nss,
  openssl,
  pango,
  pcsclite,
  protobufc,
  sqlite,
  systemd,
  webkitgtk_4_1,
  xz,
}:

let
  version = "2026.0.5676-1";

  workspacesclient = stdenvNoCC.mkDerivation {
    pname = "workspacesclient";
    inherit version;

    # AWS keeps only the current build in the pool and 403s every older one, so
    # this pin has to be refreshed from dists/jammy/main/binary-amd64/Packages.
    src = fetchurl {
      url = "https://d3nt0h4h6pmmc4.cloudfront.net/ubuntu/dists/jammy/main/binary-amd64/workspacesclient_${version}_amd64.ubuntu2204.deb";
      hash = "sha256-SQiXi4uqeU8TqzESw65y98tg1PLvOWQA1j4F4yI1Tl4=";
    };

    nativeBuildInputs = [
      dpkg
      makeBinaryWrapper
    ];

    dontStrip = true;
    dontPatchELF = true;

    installPhase = ''
      runHook preInstall

      mkdir -p $out
      cp -R usr/* $out/

      runHook postInstall
    '';

    postFixup = ''
      wrapProgram $out/bin/workspacesclient \
        --set GIO_EXTRA_MODULES ${glib-networking}/lib/gio/modules
    '';

    meta = {
      description = "Client for Amazon WorkSpaces, a managed Desktop-as-a-Service solution";
      homepage = "https://clients.amazonworkspaces.com";
      license = lib.licenses.unfree;
      sourceProvenance = with lib.sourceTypes; [ binaryNativeCode ];
      mainProgram = "workspacesclient";
      platforms = [ "x86_64-linux" ];
    };
  };
in

buildFHSEnv {
  pname = "aws-workspaces";
  inherit version;

  runScript = lib.getExe workspacesclient;

  includeClosures = true;

  targetPkgs = _: [
    workspacesclient
    alsa-lib
    at-spi2-atk
    at-spi2-core
    atk
    brotli
    cairo
    cups
    dbus
    elfutils
    gdk-pixbuf
    gst_all_1.gst-plugins-base
    gtk3
    jbigkit
    libdeflate
    libdrm
    libgbm
    libgudev
    libpng
    libpulseaudio
    libselinux
    libthai
    libunwind
    libva
    libvdpau
    libxml2
    nspr
    nss
    openssl
    pango
    pcsclite
    protobufc
    sqlite
    systemd
    webkitgtk_4_1
    xz
  ];

  extraBwrapArgs = [
    "--symlink /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem"
  ];

  extraInstallCommands = ''
    mv $out/bin/aws-workspaces $out/bin/${workspacesclient.meta.mainProgram}

    ln -s ${workspacesclient}/share $out/
  '';

  meta = workspacesclient.meta;
}
