#!/usr/bin/env python3
"""Test the observer's early builder wake: nix-observer-wake.py [MODULE_DIR]."""

from importlib.machinery import SourceFileLoader
import os
from pathlib import Path
import sys
import tempfile

MODULE = Path(sys.argv[1] if len(sys.argv) > 1 else "modules/nixos").resolve()
observer = SourceFileLoader("observer", str(MODULE / "nix-observer.py")).load_module()


def drv(tmp, name, local):
    path = tmp / ("%032x-%s.drv" % (0, name))
    path = tmp / (("a" * 32) + "-" + name + ".drv")
    body = 'Derive([("out","/nix/store/x-%s","","")]' % name
    if local:
        body += ',[("preferLocalBuild","1")]'
    path.write_text(body + ")")
    return str(path)


def observe(tmp, lines, builders=("desktopnew",)):
    listing = tmp / "offload-builders"
    listing.write_text("".join(h + "\n" for h in builders))
    observer.OFFLOAD_BUILDERS = str(listing)

    woken = []
    observer.subprocess.Popen = lambda argv, **kw: woken.append(argv) or None

    watcher = observer.Observer.__new__(observer.Observer)
    watcher.reading_plan = False
    watcher.wake_settled = False
    for line in lines:
        watcher.consider_wake(line)
    return woken


def check(name, got, want):
    if got == want:
        print("ok   %s" % name)
        return 0
    print("FAIL %s\n  got  %r\n  want %r" % (name, got, want))
    return 1


def main():
    failures = 0
    with tempfile.TemporaryDirectory() as raw:
        tmp = Path(raw)
        remote = drv(tmp, "curl-8.0", local=False)
        local = drv(tmp, "nuke-refs", local=True)

        woken = observe(tmp, ["these 2 derivations will be built:", "  " + local])
        failures += check("a plan of only preferLocalBuild never wakes", woken, [])

        woken = observe(tmp, ["these 2 derivations will be built:", "  " + remote])
        failures += check(
            "a hook-eligible derivation wakes the builder",
            woken,
            [["builder-wake", "--async", "desktopnew"]],
        )

        woken = observe(
            tmp,
            ["these 2 derivations will be built:", "  " + local, "  " + remote],
        )
        failures += check(
            "a local path before a remote one still wakes",
            woken,
            [["builder-wake", "--async", "desktopnew"]],
        )

        woken = observe(
            tmp,
            [
                '@nix {"action":"msg","level":3,"msg":"these 2 derivations will be built:"}',
                '@nix {"action":"msg","level":3,"msg":"  %s"}' % remote,
            ],
        )
        failures += check(
            "the json stream form wakes too",
            woken,
            [["builder-wake", "--async", "desktopnew"]],
        )

        woken = observe(tmp, ["  " + remote, "building '%s'" % remote])
        failures += check("a drv outside a plan block never wakes", woken, [])

        woken = observe(
            tmp,
            ["these 2 derivations will be built:", "  " + remote, "  " + remote],
        )
        failures += check("the wake fires at most once", len(woken), 1)

        woken = observe(
            tmp,
            ["these 2 derivations will be built:", "  " + remote],
            builders=("desktopnew", "pi"),
        )
        failures += check("every configured builder is woken", len(woken), 2)

        woken = observe(tmp, ["these 2 derivations will be built:", "unrelated line", "  " + remote])
        failures += check("the plan block ends at the first non-drv line", woken, [])

    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
