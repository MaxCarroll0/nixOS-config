# nilfs2 rebuilt out of tree with the checkpoint root lifetime fixes.

{
  lib,
  stdenv,
  kernel,
  bc,
  bison,
  elfutils,
  flex,
  kmod,
  openssl,
  perl,
  python3,
  xz,
  zlib,
}:

let
  modDir = "lib/modules/${kernel.modDirVersion}";
  stockModule = "${kernel.modules}/${modDir}/kernel/fs/nilfs2/nilfs2.ko.xz";
  makeFlags = lib.escapeShellArgs kernel.commonMakeFlags;
in
stdenv.mkDerivation {
  pname = "nilfs2-root-lifetime";
  inherit (kernel) version src;

  patches = [
    ./nilfs2-root-lifetime.patch
    ./nilfs2-inode-root-ref.patch
  ];

  nativeBuildInputs = kernel.moduleBuildDependencies ++ [
    bc
    bison
    elfutils
    flex
    kmod
    openssl
    perl
    python3
    xz
    zlib
  ];

  postPatch = ''
    patchShebangs scripts
  '';

  configurePhase = ''
    runHook preConfigure
    install -m644 ${kernel.configfile} .config
    sed -i 's/^CONFIG_LOCALVERSION=.*/CONFIG_LOCALVERSION=""/' .config
    make ${makeFlags} -j$NIX_BUILD_CORES olddefconfig modules_prepare
    xz -dc ${stockModule} > stock-nilfs2.ko
    modprobe --dump-modversions stock-nilfs2.ko 2>/dev/null \
      | awk '{ printf "%s\t%s\tvmlinux\tEXPORT_SYMBOL\t\n", $1, $2 }' > Module.symvers || true
    if [ ! -s Module.symvers ]; then
      export KBUILD_MODPOST_WARN=1
    fi
    runHook postConfigure
  '';

  buildPhase = ''
    runHook preBuild
    make ${makeFlags} -j$NIX_BUILD_CORES M=fs/nilfs2 CONFIG_NILFS2_FS=m modules
    runHook postBuild
  '';

  doCheck = true;
  checkPhase = ''
    runHook preCheck
    modinfo -F vermagic stock-nilfs2.ko > want
    modinfo -F vermagic fs/nilfs2/nilfs2.ko > got
    diff want got
    { modprobe --dump-modversions fs/nilfs2/nilfs2.ko 2>/dev/null || true; } | sort > got-crcs
    { modprobe --dump-modversions stock-nilfs2.ko 2>/dev/null || true; } | sort > stock-crcs
    comm -23 got-crcs stock-crcs > unmatched
    if [ -s unmatched ]; then cat unmatched; exit 1; fi
    runHook postCheck
  '';

  installPhase = ''
    runHook preInstall
    install -Dm444 fs/nilfs2/nilfs2.ko $out/${modDir}/updates/nilfs2.ko
    runHook postInstall
  '';
}
