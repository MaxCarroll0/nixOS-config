"""Mint a NAS account: writes the Nix declaration, then prints the manual onboarding steps."""

import argparse
import re
import secrets
import sys
from pathlib import Path

UID_MIN = 3000
UID_MAX = 3999
NAME_RE = re.compile(r"^[a-z][a-z0-9-]{1,30}$")
NESTED_RE = re.compile(r"(\n(\s*)accounts = \{\n)(.*?)(\n\2\};)", re.S)
DOTTED_RE = re.compile(r"^([ \t]*)accounts\.([a-z][a-z0-9-]*) = \{", re.M)


def used_uids(text):
    return {int(m) for m in re.findall(r"uid = (\d+);", text)}


def existing_names(text):
    names = {m.group(2) for m in DOTTED_RE.finditer(text)}
    block = NESTED_RE.search(text)
    if block:
        names |= set(re.findall(r"^\s+([a-z][a-z0-9-]*) = \{", block.group(3), re.M))
    return names


def next_uid(taken):
    free = [u for u in range(UID_MIN, UID_MAX + 1) if u not in taken]
    return secrets.choice(free) if free else None


def insert_account(text, name, uid, full):
    body = f"  uid = {uid};\n" f'  description = "{full}";\n'

    block = NESTED_RE.search(text)
    if block:
        indent = block.group(2) + "  "
        entry = "\n" + indent + name + " = {\n"
        entry += "".join(f"{indent}{line}\n" for line in body.strip("\n").split("\n"))
        entry += indent + "};"
        return text[: block.end(3)] + entry + text[block.end(3) :]

    last = None
    for m in DOTTED_RE.finditer(text):
        last = m
    if last is None:
        return None
    indent = last.group(1)
    close = text.index(f"\n{indent}}};", last.end()) + len(f"\n{indent}}};")
    entry = f"\n{indent}accounts.{name} = {{\n"
    entry += "".join(f"{indent}{line}\n" for line in body.strip("\n").split("\n"))
    entry += f"{indent}}};"
    return text[:close] + entry + text[close:]


def main():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("name")
    ap.add_argument("--full-name")
    ap.add_argument("--uid", type=int)
    ap.add_argument("--host-file", default="hosts/pi/default.nix")
    ap.add_argument("--tailnet-email", help="Account to share the NAS with.")
    ap.add_argument("--dry-run", action="store_true", help="Show the change without writing.")
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
        print(f"error: account {args.name!r} already exists", file=sys.stderr)
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

    full = args.full_name or args.name
    updated = insert_account(text, args.name, uid, full)
    if updated is None:
        print("error: could not find a local.nas.accounts block to extend", file=sys.stderr)
        return 1

    if args.dry_run:
        print(updated[updated.index("accounts = {") : updated.index("accounts = {") + 600])
        return 0

    path.write_text(updated)
    print(f"Wrote account {args.name!r} (uid {uid}) to {path}.\n")
    print("The account is minted locked. You never set their password.\n")
    print(f"  1. Review and commit, then:  rebuild --host pi switch\n")
    print(f"  2. Issue a one-time enrolment token:")
    print(f"       sudo-request --host pi sudo nas-enroll-issue {args.name}\n")
    print(f"  3. Send them the token and the enrolment URL. They set both their login and")
    print(f"     file-sharing password themselves, at  http://enroll/  on the tailnet.")
    print(f"     The token works once and expires; nobody else ever learns the password.\n")
    if args.tailnet_email:
        print(f"  4. Share the NAS with {args.tailnet_email}:")
        print(f"       tailscale share pi --email {args.tailnet_email}")
    else:
        print("  4. Share the NAS to their own Tailscale account (not an invite, not a tag):")
        print("       tailscale share pi --email <their-account>")
    print("     Recipients reach only this machine, so the two-tier split is structural.\n")
    print(f"  5. Grafana, once authentication exists: create {args.name} with a Viewer role")
    print("     scoped to their own usage. Grafana currently runs anonymous-admin, so do NOT")
    print("     hand out its URL until that is fixed.\n")
    print(f"uid {uid} must be identical on every node, or replication loses ownership.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
