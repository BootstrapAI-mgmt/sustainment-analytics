"""Checkpointed, resumable stage runner.

Design rules, in the order they take precedence:

1. NEVER TRUST A CHECKPOINT YOU CANNOT VERIFY. Every checkpoint carries a
   checksum of its own payload, and every payload is proven to survive a
   JSON round trip BEFORE it is written. A truncated file is detected and
   the stage re-runs. The failure being defended against is a process
   killed mid-write, which leaves a file that is present, parseable, and
   wrong -- the worst of the three possible states.

   The round-trip proof is the half that was missing at first. Encoding
   with `default=str` meant a stage returning a tuple got a list back on
   resume, a set came back as a STRING, and a dict with integer keys came
   back with string keys -- and because the checksum was taken after the
   lossy encode on both write and read, every one of those verified as
   intact. A stage summing `{1: 1200, 7: 320}.get(p)` returned $6,020 on
   the first run and $0 on resume, with no error and a valid checksum. A
   checksum proves the file survived the disk. It says nothing about
   fidelity to what the stage returned, and those are different claims.

2. WRITE ATOMICALLY. Checkpoints are written to a temporary file in the
   same directory and then renamed. Rename within a filesystem is atomic,
   so a reader sees either the old checkpoint or the new one, never a
   partial one.

3. RETRY ONLY WHAT RETRY CAN FIX. See errors.py.

4. DEGRADE VISIBLY OR NOT AT ALL. When a stage falls back to a
   lower-fidelity path, the result is marked degraded and the mark
   PROPAGATES to every downstream result and into the final output. A
   fallback that produces an unmarked answer is worse than a failure,
   because the number looks exactly like the one that was asked for.

   Propagation has to survive the CACHE, which it did not at first.
   Degradation was absent from the stage key, and the cache-hit branch
   returned the cached flag without ever consulting the current upstream.
   A downstream stage warmed by a clean run was therefore served,
   unmarked, into a run whose upstream had fallen back -- and in the
   demo pipeline that produced a published narrative with no degradation
   banner, carrying figures that were not the data the run had used, and
   an exit code of zero. It is now closed twice over: degradation is part
   of the key (manifest.py), and a clean cached result is treated as a
   MISS when the current upstream is degraded.

5. REFUSE RATHER THAN EMIT. A GateFailure stops the run. There is no
   configuration flag to continue past a failed gate, because such flags
   are always eventually set.

6. A DEGRADED RESULT IS RECORDED BUT NOT REUSED. Found while exercising
   rule 4: a fallback result written under the primary key meant the next
   resume served the fallback and never retried the primary path, so a
   ten-minute outage became a permanently degraded pipeline. Degraded
   results now go to a separate sidecar file, so the audit trail survives
   and the recovery run cannot overwrite it. Pass reuse_degraded=True
   only to reproduce a specific historical run.
"""

from __future__ import annotations

import json
import os
import time
from dataclasses import dataclass, field
from typing import Any, Callable, Optional

from .errors import GateFailure, PermanentError, TransientError
from .manifest import digest, stage_key


@dataclass
class StageResult:
    value: Any
    key: str
    degraded: bool = False
    degraded_reason: str = ""
    attempts: int = 1
    from_cache: bool = False


@dataclass
class RunLog:
    events: list = field(default_factory=list)

    def add(self, **kw):
        self.events.append(kw)

    def of_type(self, kind: str):
        return [e for e in self.events if e.get("event") == kind]


class Runner:
    """Executes stages with checkpointing, retry, and degradation.

    sleep is injectable so the fault-injection tests can exercise the
    real backoff logic without spending real seconds on it. A test that
    has to skip the retry path to stay fast ends up not testing it.
    """

    def __init__(self, checkpoint_dir: str, log: Optional[RunLog] = None,
                 max_attempts: int = 3, base_delay: float = 0.25,
                 sleep: Callable[[float], None] = time.sleep,
                 reuse_degraded: bool = False):
        if max_attempts < 1:
            raise ValueError("max_attempts must be at least 1")
        self.dir = checkpoint_dir
        self.log = log if log is not None else RunLog()
        self.max_attempts = max_attempts
        self.base_delay = base_delay
        self.sleep = sleep
        self.reuse_degraded = reuse_degraded
        os.makedirs(self.dir, exist_ok=True)

    # ---- checkpoint I/O ------------------------------------------------

    def _path(self, key: str, degraded: bool = False) -> str:
        suffix = ".degraded.json" if degraded else ".json"
        return os.path.join(self.dir, key + suffix)

    def _write(self, key: str, payload: dict, degraded: bool) -> None:
        # No `default=`: a payload that cannot round-trip must fail here,
        # loudly, rather than come back as something else on resume.
        try:
            body = json.dumps(payload, sort_keys=True, allow_nan=False)
            if json.loads(body) != payload:
                raise TypeError(
                    "value does not survive a JSON round trip unchanged "
                    "(a tuple, set, or non-string dict key would come back "
                    "as a different object on resume)"
                )
        except (TypeError, ValueError) as exc:
            raise PermanentError(
                f"stage result is not checkpointable: {exc}. Stage values "
                f"must be JSON-native so a resumed run is identical to a "
                f"fresh one."
            ) from exc

        record = {"checksum": digest(body), "payload": payload}
        path = self._path(key, degraded)
        tmp = path + ".tmp"
        with open(tmp, "w") as fh:
            fh.write(json.dumps(record))
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, path)                 # atomic within a filesystem

    def _read(self, key: str, degraded: bool = False) -> Optional[dict]:
        path = self._path(key, degraded)
        if not os.path.exists(path):
            return None
        try:
            with open(path) as fh:
                record = json.load(fh)
            body = json.dumps(record["payload"], sort_keys=True, allow_nan=False)
            if digest(body) != record["checksum"]:
                self.log.add(event="checkpoint_corrupt", key=key,
                             reason="checksum mismatch")
                return None
            return record["payload"]
        except (json.JSONDecodeError, KeyError, OSError, ValueError) as exc:
            self.log.add(event="checkpoint_corrupt", key=key, reason=str(exc))
            return None

    # ---- stage execution -----------------------------------------------

    def run(self, name: str, fn: Callable[[], Any], *,
            code_version: str = "1",
            params: Optional[dict] = None,
            upstream: Optional[list] = None,
            fallback: Optional[Callable[[], Any]] = None,
            fallback_reason: str = "primary path unavailable") -> StageResult:
        params = params or {}
        ups = upstream or []
        up_degraded = [u for u in ups if u.degraded]

        key = stage_key(name, code_version, params,
                        [(u.key, u.degraded) for u in ups])

        degraded = bool(up_degraded)
        reason = ("upstream degraded: " + up_degraded[0].degraded_reason) \
            if up_degraded else ""

        # Degraded results live in a sidecar file, so a recovery run can
        # never overwrite the record of the outage it recovered from, and
        # a resume never picks the fallback up as if it were the answer.
        if self.reuse_degraded:
            cached = self._read(key, degraded=True)
            if cached is None:
                cached = self._read(key, degraded=False)
        else:
            cached = self._read(key, degraded=False)
            if cached is None:
                prior = self._read(key, degraded=True)
                if prior is not None:
                    self.log.add(event="stale_degraded", stage=name, key=key,
                                 reason=prior["degraded_reason"])

        if cached is not None:
            if up_degraded and not cached["degraded"]:
                # Belt and braces. The key already separates these, but a
                # clean cached result must never be served into a degraded
                # run even if some future change to the key material lets
                # them collide again.
                self.log.add(event="cache_miss_degraded_upstream", stage=name,
                             key=key)
            else:
                self.log.add(event="cache_hit", stage=name, key=key)
                return StageResult(value=cached["value"], key=key,
                                   degraded=cached["degraded"] or bool(up_degraded),
                                   degraded_reason=cached["degraded_reason"] or reason,
                                   attempts=0, from_cache=True)

        UNSET = object()
        value = UNSET
        last_exc = None
        attempt = 0

        for attempt in range(1, self.max_attempts + 1):
            try:
                value = fn()
                break
            except GateFailure:
                # A gate refusal is the designed outcome, not an incident.
                # It is never retried and never falls back: the whole point
                # of a gate is that this result must not be used.
                self.log.add(event="gate_failed", stage=name)
                raise
            except TransientError as exc:
                last_exc = exc
                self.log.add(event="retry", stage=name, attempt=attempt,
                             error=str(exc))
                if attempt < self.max_attempts:
                    self.sleep(self.base_delay * (2 ** (attempt - 1)))
            except Exception as exc:                       # noqa: BLE001
                # Permanent, or unrecognised and therefore treated as
                # permanent. Either way a retry cannot help, so stop now
                # and let the real diagnosis surface.
                last_exc = exc
                self.log.add(event="permanent_failure", stage=name,
                             error=str(exc), type=type(exc).__name__)
                break
        else:
            self.log.add(event="retries_exhausted", stage=name,
                         attempts=self.max_attempts)

        if value is UNSET:
            if fallback is None:
                raise PermanentError(
                    f"stage '{name}' failed with no fallback: {last_exc}"
                ) from last_exc
            self.log.add(event="degraded", stage=name, reason=fallback_reason)
            try:
                value = fallback()
            except GateFailure:
                # The fallback refused too. That is a refusal, not a
                # degradation, and the log must not claim otherwise.
                self.log.add(event="gate_failed", stage=name, source="fallback")
                raise
            degraded = True
            reason = fallback_reason

        payload = {"value": value, "degraded": degraded,
                   "degraded_reason": reason}
        self._write(key, payload, degraded)
        self.log.add(event="completed", stage=name, key=key,
                     degraded=degraded, attempts=attempt)

        return StageResult(value=value, key=key, degraded=degraded,
                           degraded_reason=reason, attempts=attempt)
