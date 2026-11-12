#!/usr/bin/env python3
"""Audit the committed Swift source pins against OSV. Created on 2026-11-12.

Only public package URLs, versions, and revisions leave the machine. This does
not inspect binary contents or establish that a package is free of malicious code.
"""

import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys
import urllib.request
from urllib.parse import urlparse


LOCKFILE = Path(__file__).resolve().parents[1] / (
    "SuperduperDictation.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved"
)


def query_batch(queries):
    request = urllib.request.Request(
        "https://api.osv.dev/v1/querybatch",
        data=json.dumps({"queries": queries}).encode(),
        headers={"Content-Type": "application/json"},
    )
    with urllib.request.urlopen(request, timeout=30) as response:
        return json.load(response)


def audit(lockfile, query=query_batch):
    pins = json.loads(lockfile.read_text())["pins"]
    if not isinstance(pins, list) or not pins:
        raise ValueError("The lockfile has no source pins to audit")
    queries, dependencies = [], []
    for pin in pins:
        state = pin["state"]
        location = urlparse(pin["location"])
        revision, version = state["revision"], state["version"]
        if (pin["kind"] != "remoteSourceControl" or location.scheme != "https"
                or not location.hostname or location.username or location.password
                or not re.fullmatch(r"[0-9a-f]{40}", revision) or not version):
            raise ValueError(f"Unsupported source pin: {pin['identity']}")
        package = (location.hostname + location.path.rstrip("/")).removesuffix(".git")
        queries.extend([
            {"commit": revision},
            {"package": {"ecosystem": "SwiftURL", "name": package}, "version": version},
        ])
        dependencies.append({
            "identity": pin["identity"], "location": pin["location"],
            "revision": revision, "version": version, "osvPackage": package,
            "advisories": [],
        })

    pending = list(enumerate(queries))
    seen_tokens = set()
    while pending:
        results = query([q for _, q in pending])["results"]
        if not isinstance(results, list) or len(results) != len(pending):
            raise ValueError("OSV returned an incomplete batch; audit is inconclusive")
        next_pending = []
        for (index, request), result in zip(pending, results):
            if not isinstance(result, dict) or set(result) - {"vulns", "next_page_token"}:
                raise ValueError("OSV returned an unexpected result; audit is inconclusive")
            advisories = result.get("vulns", [])
            if not isinstance(advisories, list) or any(
                not isinstance(v, dict) or not isinstance(v.get("id"), str) or not v["id"]
                for v in advisories
            ):
                raise ValueError("OSV returned malformed advisories")
            dependencies[index // 2]["advisories"].extend(v["id"] for v in advisories)
            token = result.get("next_page_token")
            if token:
                marker = (index, token)
                if marker in seen_tokens or len(seen_tokens) >= 1000:
                    raise ValueError("OSV pagination did not finish; audit is inconclusive")
                seen_tokens.add(marker)
                next_pending.append((index, {**request, "page_token": token}))
        pending = next_pending

    for dependency in dependencies:
        dependency["advisories"] = sorted(set(dependency["advisories"]))
    return {
        "checkedAt": datetime.now(timezone.utc).isoformat(),
        "method": "OSV commit and SwiftURL package/version querybatch",
        "dependencies": dependencies,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--lockfile", type=Path, default=LOCKFILE)
    parser.add_argument("--output", type=Path, help="Write the dated JSON inventory")
    args = parser.parse_args()
    try:
        inventory = audit(args.lockfile)
        if args.output:
            args.output.write_text(json.dumps(inventory, indent=2) + "\n")
        affected = [d for d in inventory["dependencies"] if d["advisories"]]
        for dependency in affected:
            print(f"{dependency['identity']} {dependency['version']}: "
                  + ", ".join(dependency["advisories"]))
        print(f"Audited {len(inventory['dependencies'])} source pins; "
              f"{len(affected)} with advisory matches.")
        return 1 if affected else 0
    except (OSError, ValueError, KeyError, TypeError) as error:
        print(f"Dependency audit failed (inconclusive): {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    sys.exit(main())
