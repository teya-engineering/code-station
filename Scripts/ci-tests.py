#!/usr/bin/env python3
import argparse
import json
import os
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


def test_batches(tests):
    tests = set(tests)
    suite_count = len({".".join(test.split("/")[0].split(".")[:2]) for test in tests})
    # A fresh process releases AppKit and WebKit state between groups of suites.
    count = (suite_count + 24) // 25
    return [select_tests(tests, index, count) for index in range(count)]


def check_results(path, expected):
    completed = set()
    ended = False
    issues = 0
    last_started = None
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
            elif event["kind"] == "testStarted":
                last_started = event["testID"]
            elif event["kind"] == "issueRecorded" and not event["issue"].get("isKnown", False):
                issues += 1
            elif event["kind"] in {"testEnded", "testSkipped"}:
                completed.add(event["testID"].rsplit("/", 1)[0])
    if not ended:
        raise ValueError(f"The test process stopped before the suite finished. Last started: {last_started}")
    if issues:
        raise ValueError(f"The test run recorded {issues} unexpected issues.")
    missing = expected - completed
    if missing:
        raise ValueError("Tests did not finish: " + ", ".join(sorted(missing)))


def test_host(directory):
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    platform = developer / "Platforms/MacOSX.platform/Developer"
    frameworks = platform / "Library/Frameworks"
    host = directory / "code-station-test-host"
    subprocess.run([
        "xcrun", "swiftc", "-parse-as-library", "Scripts/TestMain.swift", "-o", str(host),
        "-module-cache-path", "/private/tmp/code-station-ci-host-module-cache",
        "-F", str(frameworks), "-Xlinker", "-rpath", "-Xlinker", str(frameworks),
    ], check=True)
    bundles = list(Path(".build").glob("**/MenuBarAppTests.xctest/Contents/MacOS/MenuBarAppTests"))
    if len(bundles) != 1:
        raise ValueError(f"Expected one compiled test bundle, found {len(bundles)}.")
    environment = os.environ.copy()
    environment["DYLD_FRAMEWORK_PATH"] = str(frameworks)
    environment["DYLD_LIBRARY_PATH"] = str(platform / "usr/lib")
    environment["CODE_STATION_TEST_HOST"] = "1"
    return [str(host), "--test-bundle-path", str(bundles[0])], environment


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
    _, expected = select_tests(tests, args.shard, args.count)
    print(f"Shard {args.shard + 1}/{args.count}: {len(expected)} of {len(tests)} tests", flush=True)
    batches = test_batches(expected)
    with tempfile.TemporaryDirectory(prefix="code-station-ci-tests-", dir="/private/tmp") as scratch:
        host, environment = test_host(Path(scratch))
        for index, (pattern, batch) in enumerate(batches):
            print(f"Batch {index + 1}/{len(batches)}: {len(batch)} tests", flush=True)
            report = Path(scratch) / f"events-{index}.jsonl"
            result = subprocess.run(host + [
                "--no-parallel", "--filter", pattern,
                "--event-stream-output-path", str(report), "--event-stream-version", "0",
            ], env=environment)
            # A process can exit successfully without letting Swift Testing finish its run.
            check_results(report, batch)
            result.check_returncode()
    print(f"Shard {args.shard + 1}/{args.count}: all {len(expected)} tests finished", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
