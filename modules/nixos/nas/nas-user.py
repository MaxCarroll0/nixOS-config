"""Propose a NAS account: prints the Nix and sops edits for review, applies nothing."""

import argparse
import re
import sys
from pathlib import Path

UID_MIN = 3000
UID_MAX = 3999
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,30}$")


def used_uids(text):
    return {int(m) for m in re.findall(r"uid\s*=\s*(\d+)\s*;", text)}


def existing_names(text):
    block = re.search(r"accounts\s*=\s*\{(.*?)\n    \};", text, re.S)
    if not block:
        return set()
    return set(re.findall(r"^\s{6}([a-z][a-z0-9-]*)\s*=\s*\{", block.group(1), re.M))


def next_uid(taken):
    for candidate in range(UID_MIN, UID_MAX + 1):
        if candidate not in taken:
            return candidate
    return None


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("name")
    ap.add_argument("--full-name", default=None)
    ap.add_argument("--uid", type=int, default=None)
    ap.add_argument(
        "--host-file",
        default="hosts/pi/default.nix",
        help="Host configuration the accounts live in.",
    )
    args = ap.parse_args()

    if not NAME_RE.match(args.name):
        print(f"error: {args.name!r} must be lowercase alphanumeric with dashes", file=sys.stderr)
        return 2

    path = Path(args.host_file)
    if not path.is_file():
        print(f"error: {path} not found; run from the flake root", file=sys.stderr)
        return 2
    text = path.read_text()

    if args.name in existing_names(text):
        print(f"error: account {args.name!r} already exists in {path}", file=sys.stderr)
        return 1

    taken = used_uids(text)
    uid = args.uid if args.uid is not None else next_uid(taken)
    if uid is None:
        print(f"error: no free uid in {UID_MIN}-{UID_MAX}", file=sys.stderr)
        return 1
    if not UID_MIN <= uid <= UID_MAX:
        print(f"error: uid {uid} outside {UID_MIN}-{UID_MAX}", file=sys.stderr)
        return 2
    if uid in taken:
        print(f"error: uid {uid} already in use", file=sys.stderr)
        return 1

    secret = f"nas-password-{args.name}"
    full = args.full_name or args.name

    print(f"Proposed account {args.name!r} (uid {uid}). Nothing has been changed.\n")
    print(f"1. Add to local.nas.accounts in {path}:\n")
    print(f"""      {args.name} = {{
        uid = {uid};
        description = "{full}";
        hashedPasswordFile = config.sops.secrets."{secret}".path;
      }};""")
    print(f"\n2. Create the hashed password secret:\n")
    print(f"      mkpasswd -m yescrypt | sops set secrets/secrets.yaml '[\"{secret}\"]' --")
    print(f"\n3. Declare it alongside the other sops secrets:\n")
    print(f'      sops.secrets."{secret}" = {{ }};')
    print(f"\n4. Review, commit, then:  rebuild --host pi switch")
    print(f"\n5. Share the pi to their Tailscale account, then add their SMB password:\n")
    print(f"      sudo-request --host pi sudo smbpasswd -a {args.name}")
    print(f"\nuid {uid} must be identical on every node, or replication loses ownership.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
