"""Fault injection harness.

A pipeline's recovery paths are the least-exercised code it contains and
the code most relied upon when something goes wrong. If they are only
ever run by real incidents, they are being tested in production by the
incident they were written to survive.

These helpers make the failures happen on demand, deterministically, so
every recovery path is exercised on every test run.
"""

from __future__ import annotations

import json
import os
from typing import Any, Callable

from .errors import PermanentError, TransientError


def flaky(succeed_on: int, value: Any,
          error: str = "object store throttled") -> Callable[[], Any]:
    """A stage that fails transiently until the given attempt, then works.

    Models the common real case: a dependency that is briefly unavailable
    and then is not. The runner should absorb this without operator
    involvement, and the run log should still show it happened.
    """
    state = {"n": 0}

    def fn():
        state["n"] += 1
        if state["n"] < succeed_on:
            raise TransientError(f"{error} (attempt {state['n']})")
        return value

    return fn


def always_broken(reason: str = "input schema does not match contract"):
    """A stage that can never succeed. Must NOT be retried."""

    def fn():
        raise PermanentError(reason)

    return fn


def corrupt_checkpoint(path: str, mode: str = "truncate") -> None:
    """Damage a checkpoint the way a real interruption would.

    'truncate' leaves an unparseable fragment, which is the easy case.
    'tamper' leaves a file that is complete, valid JSON, and WRONG --
    the case a parse-based check sails straight past and only a checksum
    catches.
    """
    if mode == "truncate":
        with open(path, "r+") as fh:
            data = fh.read()
            fh.seek(0)
            fh.write(data[: len(data) // 2])
            fh.truncate()
    elif mode == "tamper":
        with open(path) as fh:
            record = json.load(fh)
        record["payload"]["value"] = "silently substituted"
        with open(path, "w") as fh:
            json.dump(record, fh)
    else:
        raise ValueError(f"unknown corruption mode: {mode}")


def checkpoint_files(directory: str):
    return sorted(
        os.path.join(directory, f)
        for f in os.listdir(directory)
        if f.endswith(".json")
    )
