"""Real-backend reporting gate; host RSS and guest work time are separate metrics."""
import base64
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import statistics
import subprocess
import sys
import threading
import time

spore, backend, output = sys.argv[1:]
root = Path(output)
cycles = int(os.environ.get("SPORE_REPORTING_CYCLES", "2"))
hold = int(os.environ.get("SPORE_REPORTING_HOLD", "4"))
benchmark = os.environ.get("SPORE_REPORTING_BENCHMARK") == "1"
results = []


def run(label, args, capture=None, events=False, expected_source=None):
    samples, phases, work = [], [], []
    restore_source = None
    capture_timer = None
    transcript = ""
    sample_until = float("inf")
    with (root / (label + ".stderr")).open("w") as err:
        process = subprocess.Popen([spore, *args], stdout=subprocess.PIPE,
                                   stderr=err, text=True, bufsize=1)
        watchdog = threading.Timer(180, process.kill)
        watchdog.start()

        def sample():
            while process.poll() is None:
                rss = subprocess.run(["ps", "-o", "rss=", "-p", str(process.pid)],
                                     capture_output=True, text=True).stdout.strip()
                if rss.isdigit():
                    samples.append((time.monotonic(), int(rss)))
                time.sleep(0.1)

        sampler = threading.Thread(target=sample)
        sampler.start()
        pending = ""
        try:
            for raw in process.stdout:
                if events:
                    event = json.loads(raw)
                    if event.get("memory_restore_source") is not None:
                        restore_source = event["memory_restore_source"]
                    text = base64.b64decode(event.get("data_base64", "")).decode() if event.get("event") == "stdout" else ""
                else:
                    text = raw
                transcript += text
                pending += text
                while "\n" in pending:
                    line, pending = pending.split("\n", 1)
                    print(label + ": " + line, flush=True)
                    if "memreport verified" in line:
                        sample_until = min(sample_until, time.monotonic())
                    match = re.search(r"memreport (allocated|freed) cycle=(\d+)", line)
                    if match:
                        phases.append((time.monotonic(), match[1], int(match[2])))
                        if capture == match[1] and match[2] == "0":
                            sample_until = time.monotonic() + (hold * 0.75 if capture == "freed" else 0)
                            # Let Linux's delayed reporting worker return free
                            # pages before capturing the post-free checkpoint.
                            if capture == "freed":
                                capture_timer = threading.Timer(hold * 0.75, os.kill,
                                                                (process.pid, signal.SIGUSR1))
                                capture_timer.start()
                            else:
                                os.kill(process.pid, signal.SIGUSR1)
                    timing = re.search(r"work_ns=(\d+)", line)
                    if timing:
                        work.append(int(timing[1]))
            rc = process.wait()
        finally:
            if capture_timer is not None:
                capture_timer.cancel()
            if process.poll() is None:
                process.kill()
                process.wait()
            watchdog.cancel()
            sampler.join()
    (root / (label + ".stdout")).write_text(transcript)
    assert rc == 0, (label, rc, (root / (label + ".stderr")).read_text())
    assert capture or "memreport verified" in transcript, (label, transcript)
    if expected_source is not None:
        assert restore_source == expected_source, (label, restore_source, expected_source)
    allocated, freed = [], []
    for i, (start, phase, _) in enumerate(phases):
        # Never count the VMM releasing RAM after workload completion/save.
        end = min(phases[i + 1][0] if i + 1 < len(phases) else float("inf"), sample_until)
        values = [rss for when, rss in samples if start + 0.5 < when < end]
        if values:
            (allocated if phase == "allocated" else freed).append(min(values))
    result = dict(label=label, allocated_rss_kib=max(allocated, default=0),
                  freed_rss_kib=min(freed, default=0), work_ns=work)
    if restore_source is not None:
        result["memory_restore_source"] = restore_source
    if work:
        result["allocation_mib_per_s"] = 256e9 / statistics.median(work)
    results.append(result)
    (root / "measurements.json").write_text(json.dumps(results, indent=2) + "\n")
    return result


def command(args):
    subprocess.run([spore, *args], check=True, stdout=subprocess.PIPE)


def hashes(directory):
    return {str(p.relative_to(directory)): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in directory.rglob("*") if p.is_file()}


guest = ["--", "/bin/memreport", "256", str(cycles), str(hold)]
for vcpus in (1, 2):
    for enabled in ((False, True) if benchmark else (True,)):
        label = f"vcpu{vcpus}-reporting{int(enabled)}"
        args = ["run", "--backend", backend, "--memory", "512mb", "--vcpus", str(vcpus), "--exec-timeout", "150s"]
        if enabled:
            args += ["--free-page-reporting"]
        result = run(label, args + guest)
        if enabled:
            assert result["allocated_rss_kib"] - result["freed_rss_kib"] > 128 * 1024, result

# Compare authoritative nonzero memory, not compression or sparse-file size.
nonzero = []
for enabled in (False, True):
    checkpoint = root / f"freed-{int(enabled)}"
    args = ["run", "--backend", backend, "--memory", "512mb",
            "--save-checkpoint", str(checkpoint), "--save-on", "USR1", "--exec-timeout", "150s"]
    if enabled:
        args += ["--free-page-reporting"]
    result = run(f"save-freed-{int(enabled)}", args + guest, capture="freed")
    memory = json.loads((checkpoint / "manifest.json").read_text())["memory"]
    count = sum(len(r["digests"]) // 64 for r in memory["chunk_ranges"])
    nonzero.append(count * memory["chunk_size"])
    result["checkpoint_nonzero_bytes"] = nonzero[-1]
assert nonzero[0] - nonzero[1] > 128 * 1024 * 1024, nonzero

# Capture with live patterned pages, then let each child free and reuse them.
parent = root / "parent"
run("save", ["run", "--backend", backend, "--free-page-reporting", "--memory", "512mb",
             "--save-checkpoint", str(parent), "--save-on", "USR1", "--exec-timeout", "150s"] + guest,
    capture="allocated")
manifest = json.loads((parent / "manifest.json").read_text())
assert manifest["devices"][-1]["device_id"] == 5
assert len(manifest["devices"][-1]["queues"]) == 3
before = hashes(parent)
children = root / "children"
command(["checkpoint", "fork", str(parent), "--count", "2", "--output", str(children)])
forks = sorted(p for p in children.iterdir() if (p / "manifest.json").exists())
assert len(forks) == 2, forks
for index, child in enumerate(forks):
    if index == 1:
        # A foreign runtime key forces verified chunk restore without
        # removing, rewriting or punching holes in any shared parent file.
        other_runtime = root / "foreign-runtime"
        other_runtime.mkdir(mode=0o700)
        os.environ["SPOREVM_RUNTIME_DIR"] = str(other_runtime)
    result = run(f"restore{index}", ["--json", "checkpoint", "resume", "--backend", backend, str(child)],
                 events=True, expected_source="local_backing" if index == 0 else "chunks")
    assert result["allocated_rss_kib"] - result["freed_rss_kib"] > 128 * 1024, result
assert before == hashes(parent), "shared parent changed"
(root / "measurements.json").write_text(json.dumps(results, indent=2) + "\n")
print(json.dumps(results, indent=2))
print("free-page reporting allocate/free/retouch/save/restore/fork gate passed")
