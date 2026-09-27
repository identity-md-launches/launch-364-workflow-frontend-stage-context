#!/usr/bin/env python3
"""Export compiler ABI arrays from a preceding forge build; no network or packages."""

import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="fail if an export differs")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    for contract in ("LaunchToken", "CommitRevealCoinFlip"):
        artifact = root / "out" / f"{contract}.sol" / f"{contract}.json"
        if not artifact.is_file():
            raise SystemExit(f"Missing {artifact.name}: run forge build first")
        abi = json.loads(artifact.read_text())["abi"]
        rendered = json.dumps(abi, indent=2) + "\n"
        target = root / "docs" / "abi" / f"{contract}.json"
        if args.check:
            if not target.is_file() or target.read_text() != rendered:
                raise SystemExit(f"Stale or missing ABI: {target.relative_to(root)}")
            print(f"Verified {target.relative_to(root)}")
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(rendered)
            print(f"Exported {target.relative_to(root)}")


if __name__ == "__main__":
    main()
