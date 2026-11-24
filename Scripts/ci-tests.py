#!/usr/bin/env python3
import argparse
import json
import os
from pathlib import Path
import re
import shlex
import subprocess
import sys
import tempfile


class IncompleteTestRun(ValueError):
    pass


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
        raise IncompleteTestRun(f"The test process stopped before the suite finished. Last started: {last_started}")
    if issues:
        raise ValueError(f"The test run recorded {issues} unexpected issues.")
    missing = expected - completed
    if missing:
        raise ValueError("Tests did not finish: " + ", ".join(sorted(missing)))


def trace_exit(pattern):
    developer = Path(subprocess.check_output(["xcode-select", "-p"], text=True).strip())
    platform = developer / "Platforms/MacOSX.platform/Developer"
    helper = developer / "Toolchains/XcodeDefault.xctoolchain/usr/libexec/swift/pm/swiftpm-testing-helper"
    bundle = next(Path(".build").glob("**/MenuBarAppTests.xctest/Contents/MacOS/MenuBarAppTests"))
    environment = " ".join(shlex.quote(name + "=" + str(path)) for name, path in [
        ("DYLD_FRAMEWORK_PATH", platform / "Library/Frameworks"),
        ("DYLD_LIBRARY_PATH", platform / "usr/lib"),
    ])
    print("Tracing the interrupted batch under LLDB; its original failure still fails this job.", flush=True)
    subprocess.run([
        "xcrun", "lldb", "--batch",
        "-o", "settings set target.disable-aslr false",
        "-o", "settings set target.env-vars " + environment,
        "-o", "breakpoint set --shlib libsystem_c.dylib --name exit",
        "-o", "process launch --shell-expand-args false", "-o", "thread backtrace all", "-o", "continue",
        "--", str(helper), "--test-bundle-path", str(bundle),
        "--testing-library", "swift-testing", "--no-parallel", "--filter", pattern,
    ], timeout=300)


def main():
    parser = argparse.ArgumentParser(description="Run one share of the Swift test suites serially.")
    parser.add_argument("shard", type=int)
    parser.add_argument("count", type=int)
    parser.add_argument("--trace-batch", type=int)
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
    if args.trace_batch is not None:
        trace_exit(batches[args.trace_batch][0])
        return
    with tempfile.TemporaryDirectory(prefix="code-station-ci-tests-", dir="/private/tmp") as scratch:
        for index, (pattern, batch) in enumerate(batches):
            print(f"Batch {index + 1}/{len(batches)}: {len(batch)} tests", flush=True)
            report = Path(scratch) / f"events-{index}.jsonl"
            result = subprocess.run(command + [
                "--no-parallel", "--filter", pattern,
                "--event-stream-output-path", str(report), "--event-stream-version", "0",
            ])
            # A process can exit successfully without letting Swift Testing finish its run.
            try:
                check_results(report, batch)
            except IncompleteTestRun:
                if os.environ.get("CI") == "true":
                    trace_exit(pattern)
                raise
            result.check_returncode()
    print(f"Shard {args.shard + 1}/{args.count}: all {len(expected)} tests finished", flush=True)


if __name__ == "__main__":
    try:
        main()
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        sys.exit(str(error))
