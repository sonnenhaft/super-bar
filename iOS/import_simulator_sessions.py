#!/usr/bin/env python3
"""Check legacy session availability without reading or copying credentials.

Plaintext simulator staging has been removed. Connect accounts through the
simulator app's Settings; the app saves credentials directly in Keychain.
"""
import argparse
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SUPPORT = Path.home() / "Library/Application Support"
SOURCES = {
    "Deye": [SUPPORT / "Super Bar/Deye/session.json", ROOT / ".env.deye-session.json"],
    "Smart Life": [SUPPORT / "Super Bar/Tuya/session.json", ROOT / ".env.tuya-session.json"],
    "TCL": [SUPPORT / "TCLBar/.tcl-auth.json"],
    "LG": [SUPPORT / "LGBar/token.txt", ROOT / "token.txt"],
}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Report legacy file availability without reading credentials")
    args = parser.parse_args()
    if not args.check:
        parser.error("Plaintext session copying is disabled. Connect accounts in the simulator app's Settings to save directly in Keychain.")
    for label, paths in SOURCES.items():
        print(f"{label}: {'legacy file present' if any(path.is_file() for path in paths) else 'no legacy file'}")


if __name__ == "__main__":
    main()
