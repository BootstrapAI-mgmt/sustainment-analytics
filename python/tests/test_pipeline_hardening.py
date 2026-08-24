"""Fault injection against the runner.

Every test here is a way a pipeline breaks in the field. The bar is not
"does it survive" -- it is "does it either survive correctly or fail
loudly", because the outcome being designed against is not a crash. It is
a run that keeps going and emits a number assembled from a state that
never existed.
"""

import json
import os
import sys

import pytest

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

from pipeline import GateFailure, PermanentError, RunLog, Runner  # noqa: E402
from pipeline.faults import (  # noqa: E402
    always_broken, checkpoint_files, corrupt_checkpoint, flaky,
)


def make(tmp_path, **kw):
    log = RunLog()
    delays = []
    runner = Runner(str(tmp_path), log=log, sleep=delays.append, **kw)
    return runner, log, delays


# ---- retry semantics -------------------------------------------------

def test_transient_failure_is_absorbed(tmp_path):
    r, log, _ = make(tmp_path)
    res = r.run("s", flaky(3, {"v": 1}))
    assert res.value == {"v": 1}
    assert res.attempts == 3
    assert len(log.of_type("retry")) == 2


def test_backoff_actually_grows(tmp_path):
    r, _, delays = make(tmp_path, base_delay=0.1)
    r.run("s", flaky(3, 1))
    assert delays == [0.1, 0.2]


def test_permanent_failure_is_not_retried(tmp_path):
    # Retrying a permanent error wastes the budget and, worse, converts a
    # clear failure into a timeout that reads like an infra problem.
    r, log, _ = make(tmp_path)
    with pytest.raises(PermanentError):
        r.run("s", always_broken())
    assert log.of_type("retry") == []


def test_unrecognised_exception_is_treated_as_permanent(tmp_path):
    r, log, _ = make(tmp_path)

    def boom():
        raise ValueError("something nobody classified")

    with pytest.raises(PermanentError):
        r.run("s", boom)
    assert log.of_type("retry") == []


# ---- checkpoint integrity -------------------------------------------

def test_resume_skips_completed_work(tmp_path):
    calls = {"a": 0, "b": 0}

    def run_pipeline(runner):
        a = runner.run("a", lambda: (calls.__setitem__("a", calls["a"] + 1), 1)[1])
        return runner.run("b", lambda: (calls.__setitem__("b", calls["b"] + 1), 2)[1],
                          upstream=[a])

    r1, _, _ = make(tmp_path)
    run_pipeline(r1)
    assert calls == {"a": 1, "b": 1}

    r2, log2, _ = make(tmp_path)          # fresh process, same checkpoint dir
    run_pipeline(r2)
    assert calls == {"a": 1, "b": 1}      # nothing recomputed
    assert len(log2.of_type("cache_hit")) == 2


def test_truncated_checkpoint_is_rerun_not_trusted(tmp_path):
    r, _, _ = make(tmp_path)
    r.run("s", lambda: {"v": 7})
    corrupt_checkpoint(checkpoint_files(str(tmp_path))[0], "truncate")

    r2, log2, _ = make(tmp_path)
    res = r2.run("s", lambda: {"v": 7})
    assert res.value == {"v": 7}
    assert log2.of_type("checkpoint_corrupt")
    assert not res.from_cache


def test_tampered_checkpoint_is_caught_by_checksum(tmp_path):
    # The one that matters. The file is present, parses cleanly, and is
    # wrong. Nothing but a checksum notices, and without one the pipeline
    # would return "silently substituted" as a computed result.
    r, _, _ = make(tmp_path)
    r.run("s", lambda: {"v": 7})
    corrupt_checkpoint(checkpoint_files(str(tmp_path))[0], "tamper")

    r2, log2, _ = make(tmp_path)
    res = r2.run("s", lambda: {"v": 7})
    assert res.value == {"v": 7}
    assert log2.of_type("checkpoint_corrupt")


def test_no_partial_files_survive(tmp_path):
    r, _, _ = make(tmp_path)
    r.run("s", lambda: {"v": 1})
    assert not [f for f in os.listdir(str(tmp_path)) if f.endswith(".tmp")]


# ---- cache invalidation ---------------------------------------------

def test_changed_params_invalidate_the_stage(tmp_path):
    r, _, _ = make(tmp_path)
    a1 = r.run("a", lambda: 1, params={"horizon": 400})
    a2 = r.run("a", lambda: 2, params={"horizon": 800})
    assert a1.key != a2.key and a2.value == 2


def test_upstream_change_invalidates_downstream(tmp_path):
    # The silent-corruption case this whole design exists to prevent:
    # stage A re-runs with new inputs, stage B's own params are unchanged,
    # and B reuses a cache built on the OLD A. No crash, no warning, and a
    # final number assembled from two different versions of the world.
    r, _, _ = make(tmp_path)
    a_old = r.run("a", lambda: 1, params={"horizon": 400})
    b_old = r.run("b", lambda: "derived", upstream=[a_old])

    a_new = r.run("a", lambda: 2, params={"horizon": 800})
    b_new = r.run("b", lambda: "derived", upstream=[a_new])

    assert b_old.key != b_new.key


def test_code_version_invalidates_the_stage(tmp_path):
    r, _, _ = make(tmp_path)
    v1 = r.run("a", lambda: 1, code_version="1")
    v2 = r.run("a", lambda: 2, code_version="2")
    assert v1.key != v2.key and v2.value == 2


# ---- degradation -----------------------------------------------------

def test_fallback_marks_the_result_degraded(tmp_path):
    r, log, _ = make(tmp_path)
    res = r.run("s", always_broken(), fallback=lambda: {"v": "cached"},
                fallback_reason="solver unavailable, used last good fit")
    assert res.degraded and "solver unavailable" in res.degraded_reason
    assert log.of_type("degraded")


def test_degradation_propagates_downstream(tmp_path):
    # A degraded input makes every result computed from it degraded. If
    # the mark stopped at the stage that fell back, the final report
    # would look exactly like a clean one.
    r, _, _ = make(tmp_path)
    a = r.run("a", always_broken(), fallback=lambda: 1,
              fallback_reason="primary feed down")
    b = r.run("b", lambda: 2, upstream=[a])
    c = r.run("c", lambda: 3, upstream=[b])
    assert b.degraded and c.degraded
    assert "primary feed down" in c.degraded_reason


def test_a_degraded_result_is_not_served_from_cache(tmp_path):
    # Written the other way round at first, asserting that degraded status
    # survives a resume. Exercising it against the real pipeline showed
    # why that is wrong: the fallback lands under the same key as the
    # primary computation, so every later resume served the fallback and
    # the primary path was never retried again. A ten-minute outage became
    # a permanently degraded pipeline. The checkpoint is still written --
    # the audit trail matters -- but it is a miss for execution.
    r, _, _ = make(tmp_path)
    r.run("a", always_broken(), fallback=lambda: 1, fallback_reason="feed down")

    r2, log2, _ = make(tmp_path)
    recovered = r2.run("a", lambda: 99, fallback=lambda: 1,
                       fallback_reason="feed down")
    assert not recovered.from_cache
    assert not recovered.degraded and recovered.value == 99
    assert log2.of_type("stale_degraded")


def test_a_degraded_result_can_be_replayed_deliberately(tmp_path):
    # Reproducing a specific historical run is a real need; it just must
    # not be the default.
    r, _, _ = make(tmp_path)
    r.run("a", always_broken(), fallback=lambda: 1, fallback_reason="feed down")

    r2, _, _ = make(tmp_path, reuse_degraded=True)
    replay = r2.run("a", lambda: 99, fallback=lambda: 1,
                    fallback_reason="feed down")
    assert replay.from_cache and replay.degraded and replay.value == 1


def test_no_fallback_means_the_run_stops(tmp_path):
    r, _, _ = make(tmp_path)
    with pytest.raises(PermanentError):
        r.run("s", always_broken())


# ---- gates -----------------------------------------------------------

def test_gate_failure_is_never_retried_or_fallen_back(tmp_path):
    # A gate refusal means the result must not be used. Retrying it or
    # substituting a fallback would defeat the only thing a gate does.
    r, log, _ = make(tmp_path)

    def gated():
        raise GateFailure("rhat", "1.21 exceeds 1.05", observed=1.21)

    with pytest.raises(GateFailure):
        r.run("s", gated, fallback=lambda: "substitute")
    assert log.of_type("retry") == []
    assert log.of_type("degraded") == []


def test_gate_failure_leaves_no_checkpoint(tmp_path):
    r, _, _ = make(tmp_path)
    with pytest.raises(GateFailure):
        r.run("s", lambda: (_ for _ in ()).throw(GateFailure("g", "no")))
    assert checkpoint_files(str(tmp_path)) == []


# ---- regressions from an adversarial review -------------------------
#
# Everything below was found by deliberately attacking the guarantees this
# package advertises. Each test is named for the guarantee it protects.

def test_degradation_survives_a_warm_downstream_cache(tmp_path):
    """The one that matters most.

    A downstream stage cached during a healthy run must not be served,
    unmarked, into a run whose upstream has degraded. The first version
    did exactly that: degradation was absent from the stage key, and the
    cache-hit branch returned the cached flag without consulting the
    current upstream. In the demo pipeline it produced a published
    narrative with no degradation banner, carrying figures that were not
    the data the run had used, and an exit code of zero.
    """
    from pipeline import StageResult

    healthy = StageResult(value={"rows": 441}, key="feed@v1")
    Runner(str(tmp_path)).run("rollup", lambda: "441 rows rolled up",
                              upstream=[healthy])

    stale = StageResult(value={"rows": 441}, key="feed@v1", degraded=True,
                        degraded_reason="replica 6h behind primary")
    r2, log2, _ = make(tmp_path)
    out = r2.run("rollup", lambda: "441 rows rolled up", upstream=[stale])

    assert out.degraded, "a degraded upstream produced an unmarked result"
    assert "replica 6h behind primary" in out.degraded_reason
    assert not out.from_cache


def test_a_checkpoint_cannot_silently_change_the_value(tmp_path):
    """A checksum proves the file survived the disk, not that it is faithful.

    Encoding with default=str meant a tuple came back a list, a set came
    back a string, and a dict with integer keys came back with string
    keys -- all with a valid checksum, because the digest was taken after
    the lossy encode on both sides. A stage summing a cost table returned
    $6,020 fresh and $0 on resume.
    """
    r, _, _ = make(tmp_path)
    for bad in [lambda: (1, 2, 3), lambda: {1, 2, 3}, lambda: {1: 1200, 7: 320}]:
        with pytest.raises(PermanentError, match="not checkpointable"):
            r.run("s", bad)


def test_distinct_params_cannot_collide(tmp_path):
    from pipeline.manifest import NotHashable, stage_key

    assert stage_key("a", "1", {"h": (1, 2)}, []) != \
           stage_key("a", "1", {"h": [1, 2]}, [])

    # A param the key function cannot serialise is one it cannot promise
    # to distinguish. Hashing it by repr let two config objects collide
    # whenever CPython reused an address.
    class Cfg:
        pass

    with pytest.raises(NotHashable):
        stage_key("a", "1", {"cfg": Cfg()}, [])


def test_upstream_order_is_part_of_the_identity(tmp_path):
    from pipeline.manifest import stage_key

    a, b = ("a", False), ("b", False)
    assert stage_key("gain", "1", {}, [a, b]) != stage_key("gain", "1", {}, [b, a])


def test_the_degraded_record_is_not_overwritten_by_recovery(tmp_path):
    """'Kept for the audit trail' has to actually be true.

    The recovery run used to write over the degraded checkpoint under the
    same key, so reuse_degraded -- the documented replay mechanism -- could
    no longer reach the run it exists to reproduce.
    """
    r, _, _ = make(tmp_path)
    r.run("a", always_broken(), fallback=lambda: 1, fallback_reason="feed down")

    r2, log2, _ = make(tmp_path)
    recovered = r2.run("a", lambda: 99, fallback=lambda: 1,
                       fallback_reason="feed down")
    assert not recovered.from_cache and not recovered.degraded
    assert recovered.value == 99
    assert log2.of_type("stale_degraded")

    r3, _, _ = make(tmp_path, reuse_degraded=True)
    replay = r3.run("a", lambda: 99, fallback=lambda: 1,
                    fallback_reason="feed down")
    assert replay.from_cache and replay.degraded and replay.value == 1


def test_a_gate_failure_in_the_fallback_is_reported_as_a_refusal(tmp_path):
    r, log, _ = make(tmp_path)

    def refusing_fallback():
        raise GateFailure("sanity", "the cached fit is older than the data")

    with pytest.raises(GateFailure):
        r.run("s", always_broken(), fallback=refusing_fallback)
    assert log.of_type("gate_failed"), "the log claimed a degradation, not a refusal"


def test_a_cache_hit_reports_zero_attempts(tmp_path):
    r, _, _ = make(tmp_path)
    r.run("s", lambda: 1)
    r2, _, _ = make(tmp_path)
    assert r2.run("s", lambda: 1).attempts == 0


def test_max_attempts_is_validated(tmp_path):
    with pytest.raises(ValueError):
        Runner(str(tmp_path), max_attempts=0)
