#!/usr/bin/env python3
"""Exercise public CLI boundaries without a hypervisor or network access."""

import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


binary = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="spore-cli-") as directory:
    root = Path(directory)
    runtime = root / "runtime"
    runtime.mkdir(mode=0o700)
    env = {
        "PATH": os.environ["PATH"],
        "HOME": directory,
        "SPOREVM_RUNTIME_DIR": str(runtime),
        "SPOREVM_ROOTFS_CACHE_DIR": str(root / "cache"),
    }

    # Status and classification must not depend on the output renderer.
    cases = [
        (["attach", "missing"], 2, "usage.invalid_argument", "checkpoint resume", False),
        (["checkpoint", "fanout"], 2, "usage.invalid_argument", "Usage:", True),
        (["checkpoint", "inspect", str(root / "missing")], 22, "object.not_found", "missing", False),
        (["vm", "logs", "missing"], 2, "usage.missing_argument", "--initial", False),
        (["vm", "copy-in"], 2, "usage.missing_argument", "Usage:", False),
        (["vm", "restore", "missing", "--name", "dev"], 2, "usage.invalid_argument", "--checkpoint", False),
        (["build", ".", "-t", "local/app:dev"], 2, "usage.invalid_argument", "--tag", False),
        (["image", "pack", "local/app:dev"], 2, "usage.missing_argument", "archive", False),
        (["image", "export-rootfs", "local/app:dev", "--output", str(root / "disk")], 22, "object.not_found", "local/app:dev", False),
        (["image", "pull", "local/missing:dev"], 22, "object.not_found", "local/missing:dev", False),
        (["image", "pull"], 2, "usage.missing_argument", "required", False),
        (["vm", "exec", "missing", "--workdir", "relative", "--", "pwd"], 2, "usage.invalid_argument", "absolute", True),
        (["vm", "exec", "missing", "echo hi"], 2, "usage.invalid_argument", "--shell", True),
        (["vm", "exec", "missing", "--env", "SPORE_TEST_UNSET", "--", "true"], 2, "usage.invalid_argument", "SPORE_TEST_UNSET", True),
        (["vm", "exec", "missing", "--shell", "echo hi", "--", "true"], 2, "usage.invalid_argument", "exclusive", True),
        (["run", "--shell", "echo hi", "--", "true"], 2, "usage.invalid_argument", "exclusive", True),
        (["vm", "exec", "missing", "--json", "--", "true"], 2, "usage.invalid_argument", "before", True),
        (["vm", "exec", "missing", "--workdir", "/one", "--workdir", "/two", "--", "pwd"], 2, "usage.invalid_argument", "once", True),
        (["run", "--timeout", "1s", "--timeout-ms", "2000", "--", "true"], 2, "usage.invalid_argument", "once", True),
        (["checkpoint", "pull", "s3://test-bucket/warm", "--output", str(root / "pulled")], 2, "usage.invalid_argument", "AWS_PROFILE", False),
        (["checkpoint", "pull", "gs://test-bucket/warm", "--output", str(root / "pulled")], 2, "usage.invalid_argument", "scheme", False),
    ]
    # A missing VM, not a parse failure, proves guest options weren't stolen.
    for options in (["missing", "--env", "MODE=test"], ["--env", "MODE=test", "missing"]):
        cases.append((["vm", "exec", *options, "--", "echo", "--json", "--help", "--out"], 22, "object.invalid", "missing", True))

    # Unsupported x86 operations reject before opening the missing resources.
    if sys.platform == "linux" and os.uname().machine == "x86_64":
        cases.extend([
            (["checkpoint", "resume", str(root / "missing")], 2, "usage.invalid_argument", "fresh execution only", True),
            (["checkpoint", "fork", str(root / "missing"), "--count", "1", "--output", str(root / "children")], 2, "usage.invalid_argument", "checkpoint fork is unavailable", False),
            (["vm", "copy-in", "missing", str(root / "input"), "/tmp/input"], 2, "usage.invalid_argument", "does not support copying files", False),
            (["vm", "copy-out", "missing", "/tmp/output", str(root / "output")], 2, "usage.invalid_argument", "does not support copying files", False),
        ])

    for args, status, code, message, stream in cases:
        for structured in (False, True):
            argv = [binary, *(["--json"] if structured else []), *args]
            result = subprocess.run(argv, env=env, capture_output=True, text=True, timeout=10)
            assert result.returncode == status, (argv, result.returncode, result.stdout, result.stderr)
            if structured:
                if stream:
                    events = [json.loads(line) for line in result.stdout.splitlines()]
                    completions = [event for event in events if event["event"] == "completion"]
                    assert len(completions) == 1, (argv, events)
                    failure = completions[0]["error"]
                    assert not result.stderr, (argv, result.stderr)
                else:
                    assert not result.stdout, (argv, result.stdout)
                    failure = json.loads(result.stderr)["error"]
                assert failure["code"] == code, (argv, failure)
                assert message.lower() in failure["message"].lower(), (argv, failure)
            else:
                assert not result.stdout, (argv, result.stdout)
                assert message.lower() in result.stderr.lower(), (argv, result.stderr)
                assert f"[{code}]" in result.stderr, (argv, result.stderr)
                if args == ["vm", "copy-in"]:
                    assert result.stderr.splitlines()[0] == f"Usage: [{code}]", (argv, result.stderr)
                    assert result.stderr.splitlines()[1] == "  spore vm copy-in NAME HOST_PATH GUEST_PATH", (argv, result.stderr)
                if args[:2] == ["checkpoint", "resume"]:
                    assert result.stderr.startswith("spore checkpoint resume:"), (argv, result.stderr)

print(f"CLI contracts: {len(cases)} cases passed in human and JSON modes")
