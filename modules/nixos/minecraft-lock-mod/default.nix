# Server-only NeoForge mod holding one keep-running lock per online player.

{
  stdenv,
  fetchurl,
  jdk21_headless,
}:

let
  maven = "https://maven.neoforged.net/releases/net/neoforged";
  classpath = [
    (fetchurl {
      url = "${maven}/neoforge/21.1.265/neoforge-21.1.265-universal.jar";
      hash = "sha256-wSzxpssKp3krExdLBgiKT1TYvMkvajL8sDMQtFaTaEc=";
    })
    (fetchurl {
      url = "${maven}/bus/8.0.5/bus-8.0.5.jar";
      hash = "sha256-cF4k83dSgJSZpc0MfdMeqr89kzxdOyBgFo6U6e9iWTo=";
    })
    (fetchurl {
      url = "${maven}/fancymodloader/loader/4.0.45/loader-4.0.45.jar";
      hash = "sha256-g5A5jmffI+cthe2AloW+J1LI7FRbfLtq1LcP3IHk3NQ=";
    })
    (fetchurl {
      url = "https://repo1.maven.org/maven2/org/slf4j/slf4j-api/2.0.9/slf4j-api-2.0.9.jar";
      hash = "sha256-CBiTDcjX3rtAMgRhFpHaWOSdQsULb/z9zgLa23w8K2w=";
    })
  ];
in

stdenv.mkDerivation {
  pname = "keep-running-lock";
  version = "1.0.0";
  src = ./.;
  nativeBuildInputs = [ jdk21_headless ];

  buildPhase = ''
    javac --release 21 -d stub-classes stub/net/minecraft/server/MinecraftServer.java
    javac --release 21 -proc:none -cp ${builtins.concatStringsSep ":" classpath}:stub-classes \
      -d classes $(find src -name '*.java')
    cp -r resources/. classes/
    jar --create --file keep-running-lock.jar -C classes .
  '';

  installPhase = ''
    install -Dm644 keep-running-lock.jar $out/keep-running-lock-1.0.0.jar
  '';
}
