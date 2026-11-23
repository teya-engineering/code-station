#!/usr/bin/env python3
import argparse
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def select_tests(tests, shard, count):
    if count < 1 or not 0 <= shard < count:
        raise ValueError("The shard must be between zero and the shard count minus one.")
    tests = set(tests)
    # Keep nested suites together so their shared fixtures stay in one process.
    suites = sorted({".".join(test.split("/")[0].split(".")[:2]) for test in tests})
    selected = suites[shard::count]
    if not selected:
        raise ValueError("The shard contains no test suites.")
    pattern = "^(?:" + "|".join(re.escape(suite) for suite in selected) + r")(?:[./]|$)"
    return pattern, {test for test in tests if re.search(pattern, test)}


def check_results(path, expected):
    completed = set()
    ended = False
    issues = 0
    with path.open() as stream:
        for line in stream:
            record = json.loads(line)
            if record["version"] != 0:
                raise ValueError("The test report has an unsupported format.")
            if record["kind"] != "event":
                continue
            event = record["payload"]
            if event["kind"] == "runEnded":
                ended = True
            elif event["kind"] == "issueRecorded" and not event["issue"].get("isKnown", False):
                issues += 1
            elif event["kind"] in {"testEnded", "testSkipped"}:
                completed.add(event["testID"].rsplit("/", 1)[0])
    if issues:
        raise ValueError(f"The test run recorded {issues} unexpected issues.")
    if not ended:
        raise ValueError("The test process stopped before the suite finished.")
    missing = expected - completed
    if missing:
        raise ValueError("Tests did not finish: " + ", ".join(sorted(missing)))


def main():
    parser = argparse.ArgumentParser(description="Run one share of the Swift test suites serially.")
    parser.add_argument("shard", type=int)
    parser.add_argument("count", type=int)
    args = parser.parse_args()
    command = [
        "./Scripts/swiftpm.sh", "test", "--disable-sandbox", "--disable-index-store",
        "--force-resolved-versions", "--skip-build",
        "--cache-path", "/private/tmp/teya-swiftpm-cache",
        "--config-path", "/private/tmp/code-station-ci-configuration",
        "--security-path", "/private/tmp/code-station-ci-security",
    ]
    listing = subprocess.run(command + ["list"], check=True, capture_output=True, text=True)
    tests = {line.strip() for line in listing.stdout.splitlines() if line.startswith("MenuBarAppTests.")}
    pattern, expected = select_tests(tests, args.shard, args.count)
    print(f"Shard {args.shard + 1}/{args.count}: {len(expected)} of {len(tests)} tests", flush=True)
    with tempfile.TemporaryDirectory(prefix="code-station-ci-tests-", dir="/private/tmp") as scratch:
        report = Path(scratch) / "events.jsonl"
        subprocess.run(command + [
            "--no-parallel", "--filter", pattern,
            "--event-stream-output-path", str(report), "--event-stream-version", "0",
        ], check=True)
        # A process can exit successfully without letting Swift Testing finish its run.
        check_results(report, expected)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
