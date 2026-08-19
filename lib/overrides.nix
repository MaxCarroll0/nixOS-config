# Eval-time warnings for overrides and pins that assume a particular upstream state.

{ lib }:

{
  againstVersion =
    name: expected: upstream:
    lib.warnIf (upstream != expected)
      "${name}: override was written against ${expected}, upstream now has ${upstream} - recheck whether it is still needed";

  againstRev =
    name: expected: actual:
    lib.warnIf (actual != expected)
      "${name}: pinned input moved to ${actual}, the code around it was written against ${expected} - recheck it";

  containing =
    name: marker: text:
    lib.warnIf (!lib.hasInfix marker text)
      "${name}: upstream expression no longer contains ${marker} - the override may now be a no-op"
      text;
}
