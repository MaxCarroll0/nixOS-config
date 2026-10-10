# pymarc, absent from nixpkgs: the MARC21 parser the DNB resolver reads records with.

{
  buildPythonPackage,
  fetchPypi,
  hatchling,
}:

buildPythonPackage rec {
  pname = "pymarc";
  version = "5.4.0";
  pyproject = true;

  src = fetchPypi {
    inherit pname version;
    hash = "sha256-sgFrFnTRlWY2yZub+VsxhAxcuPImRWcqZg5mMmNxsvM=";
  };

  build-system = [ hatchling ];

  pythonImportsCheck = [ "pymarc" ];

  meta = {
    description = "Read, write and modify MARC bibliographic records";
    homepage = "https://gitlab.com/pymarc/pymarc";
  };
}
