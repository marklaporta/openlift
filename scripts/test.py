#!/usr/bin/env python3
"""Incremental simulator checkpoints; no signing, personal stores or live delivery."""
import argparse
from concurrent.futures import ThreadPoolExecutor
import fcntl
import json
import os
from pathlib import Path
import subprocess
import time
import uuid

ROOT = Path(__file__).resolve().parents[1]
STATE = ROOT / ".build" / "tests"
# Measured long flows first. Shard 3 is the COMPLEMENT, not another allowlist:
# new/renamed UI classes automatically remain in the suite without editing this.
UI_GROUPS = (
    ("AdaptiveWorkoutFlowUITests", "FixedCycleWorkoutUITests"),
    ("ClusteredWorkoutUITests", "AdaptiveProposalUITests"),
)


def output(*command):
    return subprocess.check_output(command, text=True).strip()


def simulator(slot):
    marker = STATE / f"simulator-{slot}.json"
    devices = json.loads(output("xcrun", "simctl", "list", "devices", "available", "--json"))["devices"]
    if marker.exists():
        owned = json.loads(marker.read_text())
        for entries in devices.values():
            for device in entries:
                if device["udid"] == owned["id"]:
                    if device["name"] != owned["name"]:
                        raise SystemExit(f"Refusing renamed simulator; inspect {marker}.")
                    return owned["id"]
        # Replace only a deleted/unavailable owned simulator, never pick an
        # arbitrary existing iPhone which could contain a copied personal store.
    runtimes = json.loads(output("xcrun", "simctl", "list", "runtimes", "--json"))["runtimes"]
    ios = [r for r in runtimes if r["isAvailable"] and r["identifier"].startswith("com.apple.CoreSimulator.SimRuntime.iOS-")]
    if not ios:
        raise SystemExit("Install an iOS simulator runtime in Xcode first.")
    runtime = max(ios, key=lambda r: tuple(int(v) for v in r["version"].split(".")))
    name = f"OpenLift Tests {slot} " + str(uuid.uuid4())[:8]
    device_id = output("xcrun", "simctl", "create", name, "com.apple.CoreSimulator.SimDeviceType.iPhone-17", runtime["identifier"])
    marker.write_text(json.dumps({"name": name, "id": device_id}) + "\n")
    return device_id


def run_logged(command, path, environment):
    with path.open("w") as log:
        return subprocess.call(command, cwd=ROOT, env=environment, stdout=log, stderr=subprocess.STDOUT)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("lane", choices=("unit", "ui", "full"), nargs="?", default="unit")
    parser.add_argument("tests", nargs="*", help="ClassName[/testMethod] selectors within unit or ui; full always runs everything.")
    args = parser.parse_args()
    if args.lane == "full" and args.tests:
        parser.error("full does not accept filters; use unit or ui for a focused checkpoint")
    if any(not all(part.isidentifier() for part in selector.split("/")) or len(selector.split("/")) > 2 for selector in args.tests):
        parser.error("selectors must be ClassName or ClassName/testMethod, without xcodebuild options")
    STATE.mkdir(parents=True, exist_ok=True)
    with (STATE / "runner.lock").open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise SystemExit("Another checkpoint owns this checkout's test runner.")
        run = STATE / (time.strftime("%Y%m%d-%H%M%S") + "-" + args.lane + "-" + str(uuid.uuid4())[:8])
        run.mkdir()
        environment = os.environ.copy()
        for key in ("OPENLIFT_REAL_DEVICE_STORE_DIRECTORY", "SIMCTL_CHILD_OPENLIFT_REAL_DEVICE_STORE_DIRECTORY"):
            environment.pop(key, None)
        start = time.monotonic()
        sharded_ui = args.lane in ("ui", "full") and not args.tests
        devices = [simulator(str(i)) for i in range(1, 4 if sharded_ui else 2)]
        print(f"Running {args.lane}; logs and receipts: {run}", flush=True)
        # Warm each owned device directly, rather than cloning an uninitialized
        # base and letting Xcode stagger worker installation/launch for minutes.
        def boot(pair):
            i, device = pair
            return run_logged(["xcrun", "simctl", "bootstatus", device, "-b"], run / f"boot-{i}.log", environment)
        with ThreadPoolExecutor(max_workers=len(devices)) as pool:
            if any(pool.map(boot, enumerate(devices, 1))):
                raise SystemExit("Simulator boot failed; inspect boot logs.")
        derived = STATE / "DerivedData"
        build = ["xcodebuild", "build-for-testing", "-scheme", "OpenLift", "-destination", f"platform=iOS Simulator,id={devices[0]}",
                 "-derivedDataPath", str(derived), "CODE_SIGNING_ALLOWED=NO", "OPENLIFT_DIRECT_EXPORT_ENDPOINT=", "OPENLIFT_DIRECT_EXPORT_BEARER_TOKEN="]
        code = run_logged(build, run / "build.log", environment)
        if code:
            raise SystemExit(code)
        # Every invocation rebuild-checks first. test-without-building is only
        # used on these just-validated products, never as an unchecked cache mode.
        descriptors = list((derived / "Build" / "Products").glob("OpenLift_*.xctestrun"))
        if not descriptors:
            raise SystemExit("Build produced no test descriptor.")
        descriptor = max(descriptors, key=lambda p: p.stat().st_mtime_ns)
        jobs = []
        if args.lane in ("unit", "full"):
            selections = args.tests if args.lane == "unit" else []
            jobs.append(("unit", devices[0], ["-only-testing:OpenLiftTests" + ("/" + s if s else "") for s in (selections or [""])]))
        if args.lane in ("ui", "full"):
            if args.tests:
                jobs.append(("ui", devices[0], ["-only-testing:OpenLiftUITests/" + s for s in args.tests]))
            else:
                for i, group in enumerate(UI_GROUPS):
                    jobs.append((f"ui-{i + 1}", devices[i], ["-only-testing:OpenLiftUITests/" + name for name in group]))
                excluded = [name for group in UI_GROUPS for name in group]
                jobs.append(("ui-3", devices[2], ["-only-testing:OpenLiftUITests"] + ["-skip-testing:OpenLiftUITests/" + name for name in excluded]))

        def execute(job):
            name, device, selections = job
            result = run / f"{name}.xcresult"
            command = ["xcodebuild", "test-without-building", "-xctestrun", str(descriptor), "-destination", f"platform=iOS Simulator,id={device}",
                       "-parallel-testing-enabled", "NO", "-resultBundlePath", str(result)] + selections
            code = run_logged(command, run / f"{name}.log", environment)
            if not (result / "Info.plist").exists():
                return {"name": name, "exitCode": code or 1, "error": "No complete test receipt"}
            report = json.loads(output("xcrun", "xcresulttool", "get", "test-results", "summary", "--path", str(result)))
            (run / f"{name}-summary.json").write_text(json.dumps(report, indent=2) + "\n")
            if report.get("totalTestCount", 0) == 0 or report.get("failedTests", 0):
                code = code or 1
            return {"name": name, "exitCode": code, "total": report.get("totalTestCount", 0), "passed": report.get("passedTests", 0),
                    "failed": report.get("failedTests", 0), "skipped": report.get("skippedTests", 0)}

        # Unit tests and UI shard 1 share a device: finish unit tests first. The
        # three UI processes then read the same build products on distinct devices.
        reports = []
        if jobs and jobs[0][0] == "unit":
            reports.append(execute(jobs.pop(0)))
        with ThreadPoolExecutor(max_workers=3) as pool:
            reports.extend(pool.map(execute, jobs))
        summary = {key: sum(r.get(key, 0) for r in reports) for key in ("total", "passed", "failed", "skipped")}
        summary.update({"wallSeconds": time.monotonic() - start, "lane": args.lane, "parts": reports})
        (run / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
        print(f"Wall: {summary['wallSeconds']:.1f}s; passed: {summary['passed']}; failed: {summary['failed']}; skipped: {summary['skipped']}")
        raise SystemExit(1 if any(r["exitCode"] for r in reports) else 0)


if __name__ == "__main__":
    main()
