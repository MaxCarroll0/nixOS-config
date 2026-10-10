# The catalogue application: web service, resolvers, and the valuation refresh job.

{
  lib,
  python3Packages,
  withModel ? true,
}:

let
  pymarc = python3Packages.callPackage ./nix/pymarc.nix { };
in

python3Packages.buildPythonApplication {
  pname = "bookshelf";
  version = "0.1.0";
  pyproject = true;

  src = lib.cleanSource ./.;

  build-system = [ python3Packages.setuptools ];

  dependencies =
    (with python3Packages; [
      starlette
      python-multipart
      uvicorn
      jinja2
      httpx
      pydantic
      isbnlib
      selectolax
      musicbrainzngs
    ])
    ++ [ pymarc ]
    # Only the refresh job imports these; a host that never revalues can drop them
    # and save scipy's closure.
    ++ lib.optionals withModel (with python3Packages; [
      numpy
      statsmodels
    ]);

  nativeCheckInputs = [ python3Packages.pytestCheckHook ];

  pythonImportsCheck = [ "bookshelf.app" ];

  meta = {
    description = "Catalogue of books and sheet music, with edition identification and valuation";
    mainProgram = "bookshelf";
  };
}
