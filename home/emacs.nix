# Emacs, built from emacs/config.org via emacsWithPackagesFromUsePackage.

{
  config,
  lib,
  pkgs,
  ...
}:

{
  options.local.emacs.guiToolkit = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Build emacs against the GTK toolkit. False for headless hosts.";
  };

  config = {
    programs.emacs = {
      enable = true;
      package = (
        pkgs.emacsWithPackagesFromUsePackage {
          package = if config.local.emacs.guiToolkit then pkgs.emacs-pgtk else pkgs.emacs-nox;
          config = ../emacs/config.org;
          defaultInitFile = true;
          alwaysEnsure = true;
  
          extraEmacsPackages =
            epkgs:
            let
              codeium = epkgs.trivialBuild {
                pname = "codeium";
                version = "unstable";
                src = pkgs.fetchFromGitHub {
                  owner = "Exafunction";
                  repo = "codeium.el";
                  rev = "main";
                  hash = "sha256-FcLuL68RChodolE8oUTWIbZLLF3UWIsy4sKgZdaovkg=";
                };
                packageRequires = with epkgs; [
                  request
                  s
                  dash
                  editorconfig
                ];
              };
              llm-tool-collection = epkgs.trivialBuild {
                pname = "llm-tool-collection";
                version = "0-unstable-2026-02-26";
                src = pkgs.fetchFromGitHub {
                  owner = "skissue";
                  repo = "llm-tool-collection";
                  rev = "b9fd45bedf3e0fb07d289730991199ae18785157";
                  hash = "sha256-40BSMoM25tdgXeH5+labLYqCPCK4SEuAWovOeJxnzNo=";
                };
              };
              # Drop this override once nixpkgs envrc includes async processing.
              envrc = epkgs.envrc.overrideAttrs (_old: {
                version = "0-unstable-2025-01-11";
                src = pkgs.fetchFromGitHub {
                  owner = "Grimpper";
                  repo = "envrc";
                  rev = "71f67971bc5eb2974ae2f738512c8f09f0822527";
                  hash = "sha256-Zfu+yWY+POMnrWbmP6HWOjgFsASNU3HcCowNo8BIzpk=";
                };
              });
              lean4-mode = epkgs.trivialBuild {
                pname = "lean4-mode";
                version = "unstable";
                src = pkgs.fetchFromGitHub {
                  owner = "leanprover-community";
                  repo = "lean4-mode";
                  rev = "1388f9d1429e38a39ab913c6daae55f6ce799479";
                  hash = "sha256-6XFcyqSTx1CwNWqQvIc25cuQMwh3YXnbgr5cDiOCxBk=";
                };
                packageRequires = with epkgs; [
                  compat
                  dash
                  magit-section
                  lsp-mode
                ];
              };
            in
            with epkgs;
            [
              treesit-grammars.with-all-grammars
              treesit-auto
              use-package
              polymode
              poly-org
              poly-markdown
              poly-noweb
              meow
              nixpkgs-fmt
              apheleia
              nix-ts-mode
              magit
              envrc
              auctex
              vertico
              orderless
              corfu
              cape
              xenops
              cdlatex
              org-fragtog
              eat
              embrace
              codeium
              gptel
              llm-tool-collection
              ellama
              clojure-ts-mode
              sly
              fsharp-mode
              haskell-mode
              idris2-mode
              tuareg
              dune
              ocamlformat
              scala-mode
              sweeprolog
              lean4-mode
              proof-general
              company-coq
              fstar-mode
              markdown-ts-mode
              jq-mode
              ligature
              dired-narrow
              yasnippet
              nov
              consult
              marginalia
              embark
              embark-consult
              wgrep
              company-auctex
              reason-mode
              org-roam
              consult-org-roam
              org-ql
              org-super-agenda
              git-auto-commit-mode
              org-wc
              org-transclusion
              citar
              citar-org-roam
              org-noter
              pdf-tools
              org-remark
              org-roam-ui
            ];
        }
      );
    };
  };
}
