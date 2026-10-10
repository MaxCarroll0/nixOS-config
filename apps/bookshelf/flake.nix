{
  description = "Catalogue of books and sheet music";

  inputs.nixpkgs.url = "github:NixOS/nixpkgs/nixos-unstable";

  outputs =
    { self, nixpkgs }:
    let
      systems = [
        "x86_64-linux"
        "aarch64-linux"
      ];
      forAll = f: nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      packages = forAll (pkgs: {
        bookshelf = pkgs.callPackage ./package.nix { };
        default = self.packages.${pkgs.stdenv.hostPlatform.system}.bookshelf;
      });

      checks = forAll (pkgs: {
        inherit (self.packages.${pkgs.stdenv.hostPlatform.system}) bookshelf;

        mypy =
          pkgs.runCommand "bookshelf-mypy"
            {
              nativeBuildInputs = [
                (pkgs.python3.withPackages (
                  ps:
                  (self.packages.${pkgs.stdenv.hostPlatform.system}.bookshelf.dependencies or [ ])
                  ++ [
                    ps.mypy
                    ps.pytest
                  ]
                ))
              ];
            }
            ''
              cp -r ${pkgs.lib.cleanSource ./.}/. .
              chmod -R u+w .
              mypy --config-file pyproject.toml
              touch $out
            '';
      });

      devShells = forAll (pkgs: {
        default = pkgs.mkShell {
          packages = [
            (pkgs.python3.withPackages (
              ps:
              with ps;
              [
                starlette
                python-multipart
                uvicorn
                jinja2
                httpx
                pydantic
                isbnlib
                selectolax
                musicbrainzngs
                numpy
                statsmodels
                mypy
                pytest
              ]
              ++ [ (ps.callPackage ./nix/pymarc.nix { }) ]
            ))
            pkgs.sqlite
          ];
          shellHook = ''
            export PYTHONPATH=$PWD/src:$PYTHONPATH
            export BOOKSHELF_DATABASE=$PWD/.dev/bookshelf.db
            export BOOKSHELF_FAKE_IDENTITY=dev@localhost
            mkdir -p .dev
          '';
        };
      });
    };
}
