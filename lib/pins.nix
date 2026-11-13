# Host-local input pins from hosts/<host>/pins.nix as nix --override-input argv.

{
  root,
  host,
}:

let
  file = root + "/hosts/${host}/pins.nix";
  pins = if builtins.pathExists file then import file else { };
in
{
  argv = builtins.concatMap (name: [
    "--override-input"
    name
    pins.${name}
  ]) (builtins.attrNames pins);
}
