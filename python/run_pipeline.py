#!/usr/bin/env python3
"""End-to-end run: MATLAB numerics under Python orchestration.

    python3 run_pipeline.py                 normal run
    python3 run_pipeline.py --resume        reuse completed stages
    python3 run_pipeline.py --fail-fit      inject a fit-stage failure
    python3 run_pipeline.py --break-gate    force the convergence gate to trip

The numerics live in MATLAB because that is where reliability and
control-adjacent work belongs and where it can be read by the people who
own it. The orchestration lives in Python because crossing a process
boundary is exactly where pipelines lose data, and the crossing needs
checkpointing, retry classification, and gates regardless of what is on
the far side.

The interesting part is the CROSSING ITSELF. A subprocess hands back an
exit code and two text streams, and every one of those is ambiguous: a
non-zero exit could be a licence server that will be free in ten seconds
or a syntax error that will never succeed. Treating the two the same is
how a pipeline either gives up on recoverable work or retries a bug for
an hour. classify() below is where that judgement is made explicit, in
one place, where it can be reviewed.
"""

from __future__ import annotations

import argparse
import json
import re
import os
import shutil
import subprocess
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

from explain.narrate import narrate                       # noqa: E402
from pipeline import (GateFailure, PermanentError, RunLog, Runner,
                      TransientError)  # noqa: E402

ROOT = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(ROOT)
MATLAB_DIR = os.path.join(REPO, "matlab")
RESULTS = os.path.join(REPO, "results")
CKPT = os.path.join(REPO, ".checkpoints")

RHAT_THRESHOLD = 1.05

# Patterns that mean "this could work if we try again". Everything not
# listed here is permanent by default, because an unclassified failure is
# an unknown failure and retrying an unknown failure is how a crash
# becomes a hang.
#
# PERMANENT WINS OVER TRANSIENT, and the ordering is not cosmetic. A naive
# substring match classified `parse error: syntax error near line 40 of
# /opt/matlab/licenses/check.m` as transient, because the FILE PATH
# contained "licenses" -- so a syntax error that could never succeed was
# retried three times with backoff and then degraded to stale data. That
# is the exact failure errors.py opens by describing. Word boundaries and
# a permanent list that takes precedence close it.
PERMANENT_RE = re.compile(
    r"\b(parse error|syntax error|undefined|unrecognized|out of memory"
    r"|no such file|not found)\b", re.I)

TRANSIENT_RE = re.compile(
    r"\b(licen[sc]e (server|checkout|manager)|connection reset"
    r"|temporarily unavailable|resource busy|timed out|try again)\b", re.I)


def classify(returncode: int, stderr: str) -> None:
    """Raise the right error type for a failed subprocess, or return.

    Classification reads the FIRST few lines only. A long MATLAB stack
    trace mentions many files, and any of those paths can contain a word
    from either list; the diagnosis belongs to the error itself, not to
    the directory it happened in.
    """
    if returncode == 0:
        return
    head = "\n".join(stderr.strip().splitlines()[:3])

    if PERMANENT_RE.search(head):
        raise PermanentError(f"MATLAB stage failed permanently: {head[:400]}")
    if TRANSIENT_RE.search(head):
        raise TransientError(f"MATLAB stage failed transiently: {head[:200]}")
    raise PermanentError(f"MATLAB stage failed: {head[:400]}")


def matlab_interpreter() -> list:
    for exe, args in (("octave-cli", []), ("matlab", ["-batch"])):
        path = shutil.which(exe)
        if path:
            return [path] + args
    raise RuntimeError("neither octave-cli nor matlab found on PATH")


def run_matlab(script: str) -> str:
    cmd = matlab_interpreter()
    if cmd[0].endswith("matlab"):
        cmd = cmd + [f"run('{os.path.join(MATLAB_DIR, script)}')"]
    else:
        cmd = cmd + [os.path.join(MATLAB_DIR, script)]
    proc = subprocess.run(cmd, capture_output=True, text=True, cwd=MATLAB_DIR)
    classify(proc.returncode, proc.stderr)
    return proc.stdout


def stage_analysis(fail: bool = False):
    if fail:
        raise TransientError("simulated: solver host unreachable")
    run_matlab("demo_pipeline.m")
    with open(os.path.join(RESULTS, "analysis_result.json")) as fh:
        return json.load(fh)


def gate_convergence(result: dict, force_fail: bool = False):
    """Refuse to publish numbers from a sampler that has not converged.

    This is the numeric equivalent of the provenance check on the prose.
    A chain that has not mixed still produces a mean, an interval, and a
    buy list -- all correctly formatted, all meaningless. Nothing
    downstream can tell that apart from a good run, so the check has to
    happen here or not at all.
    """
    rhat = 2.0 if force_fail else result["model"]["rhat_max"]
    if rhat >= RHAT_THRESHOLD:
        raise GateFailure("convergence",
                          f"max R-hat {rhat} is at or above {RHAT_THRESHOLD}",
                          observed=rhat)
    return result


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--resume", action="store_true")
    ap.add_argument("--fail-fit", action="store_true")
    ap.add_argument("--break-gate", action="store_true")
    args = ap.parse_args()

    if not args.resume and os.path.isdir(CKPT):
        shutil.rmtree(CKPT)

    log = RunLog()
    runner = Runner(CKPT, log=log)

    last_good = os.path.join(RESULTS, "last_good.json")

    def fallback():
        with open(last_good) as fh:
            return json.load(fh)

    analysis = runner.run(
        "reliability_analysis",
        lambda: stage_analysis(args.fail_fit),
        code_version="3",
        # The injected fault is part of the stage's IDENTITY, not a hidden
        # switch inside it. Without this, `--resume --fail-fit` was a
        # no-op: the warm cache was served before the fault function ever
        # ran, so the flag that exists to demonstrate the recovery path
        # demonstrated nothing. A fault-injected invocation IS a different
        # invocation and its key should say so.
        params={"rhat_threshold": RHAT_THRESHOLD,
                "inject_fault": bool(args.fail_fit)},
        fallback=fallback if os.path.exists(last_good) else None,
        fallback_reason="solver unreachable; reused the last good analysis",
    )

    gated = runner.run(
        "convergence_gate",
        lambda: gate_convergence(analysis.value, args.break_gate),
        code_version="1",
        params={"force_fail": bool(args.break_gate)},
        upstream=[analysis],
    )

    result = dict(gated.value)
    result["degraded"] = gated.degraded
    result["degraded_reason"] = gated.degraded_reason

    text = runner.run("narrative", lambda: narrate(result),
                      code_version="1", upstream=[gated])

    if not gated.degraded:
        with open(last_good, "w") as fh:
            json.dump(gated.value, fh)

    print("\n" + "=" * 68)
    print("PIPELINE NARRATIVE  (every figure below traced to a solver field)")
    print("=" * 68 + "\n")
    print(text.value)
    print("\n" + "-" * 68)
    print("run log:")
    for e in log.events:
        print("  " + json.dumps(e, default=str))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except GateFailure as exc:
        # The designed refusal. Distinct exit code so a scheduler can tell
        # "declined to publish" apart from "fell over", which are very
        # different pages at 3am.
        print(f"\nREFUSED TO PUBLISH: {exc}", file=sys.stderr)
        sys.exit(3)
