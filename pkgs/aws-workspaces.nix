# Amazon WorkSpaces DCV client, repackaged from AWS's Ubuntu 22.04 .deb.

{
  lib,
  stdenvNoCC,
  fetchurl,
  dpkg,
  makeBinaryWrapper,
  buildFHSEnv,
  runCommand,
  glib,
  glibc,
  glib-networking,
  libxml2_13,
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
  xorg,
  xz,
}:

let
  version = "2026.0.5676-1";

  runtimeLibs = [
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
    xorg.libX11
    xorg.libXext
    xorg.libXrender
    xorg.libxcb
  ];

  # The bundle wants Ubuntu 22.04 sonames: nixpkgs' libxml2 is 2.15 (libxml2.so.16),
  # and its jbigkit sonames the same code libjbig.so.2.1, so ldconfig never indexes
  # it as libjbig.so.0. LD_LIBRARY_PATH resolves by filename, unlike the cache.
  compatLibs = runCommand "workspacesclient-compat-libs" { } ''
    mkdir -p $out/lib
    test -e ${lib.getLib libxml2_13}/lib/libxml2.so.2
    test -e ${lib.getLib jbigkit}/lib/libjbig.so.2.1
    ln -s ${lib.getLib libxml2_13}/lib/libxml2.so.2 $out/lib/libxml2.so.2
    ln -s ${lib.getLib jbigkit}/lib/libjbig.so.2.1 $out/lib/libjbig.so.0
  '';

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

    # The .deb ships schemas uncompiled and leaves glib-compile-schemas to its
    # postinst, which nothing runs here; GSettings aborts fatally without it.
    # The .deb leaves both of these to its postinst, which nothing runs here.
    # GSettings and GTK's texture loader each call g_error when their generated
    # file is absent, so a missing one aborts the viewer rather than degrading.
    # query-loaders is an Ubuntu binary, hence the explicit interpreter.
    postFixup = ''
      ${lib.getDev glib}/bin/glib-compile-schemas $out/share/workspacesclient/schemas

      pixbuf=$out/lib/x86_64-linux-gnu/workspacesclient/gdk-pixbuf-2.0/2.10.0
      chmod u+w "$pixbuf"
      GDK_PIXBUF_MODULEDIR="$pixbuf/loaders" ${glibc}/lib/ld-linux-x86-64.so.2 \
        --library-path "$out/lib/x86_64-linux-gnu/workspacesclient:${compatLibs}/lib:${lib.makeLibraryPath runtimeLibs}" \
        $out/lib/x86_64-linux-gnu/workspacesclient/gdk-pixbuf-query-loaders \
        > "$pixbuf/loaders.cache"

      # query-loaders skips a module it cannot dlopen and still exits 0, which
      # ships a cache that is silently missing an image format.
      want=$(find "$pixbuf/loaders" -name '*.so' | wc -l)
      got=$(grep -c '\.so"$' "$pixbuf/loaders.cache")
      if [ "$want" != "$got" ]; then
        echo "pixbuf cache registered $got of $want loaders" >&2
        exit 1
      fi

      wrapProgram $out/bin/workspacesclient \
        --set GIO_EXTRA_MODULES ${glib-networking}/lib/gio/modules \
        --suffix LD_LIBRARY_PATH : ${compatLibs}/lib
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

  targetPkgs = _: [ workspacesclient ] ++ runtimeLibs;

  extraBwrapArgs = [
    "--symlink /etc/ssl/certs/ca-certificates.crt /etc/ssl/cert.pem"
  ];

  extraInstallCommands = ''
    mv $out/bin/aws-workspaces $out/bin/${workspacesclient.meta.mainProgram}

    ln -s ${workspacesclient}/share $out/
  '';

  meta = workspacesclient.meta;
}
