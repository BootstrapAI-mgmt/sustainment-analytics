# sustainment-analytics

[![verification](https://github.com/BootstrapAI-mgmt/sustainment-analytics/actions/workflows/ci.yml/badge.svg)](https://github.com/BootstrapAI-mgmt/sustainment-analytics/actions/workflows/ci.yml)

**A hardened analytics pipeline for fleet sustainment: from dirty maintenance records to an auditable spares buy list, with every number traceable and every failure path tested.**

The organising idea, and the reason the tests look the way they do:

> A hardened pipeline is not one that never stops.
> It is one that never silently emits a wrong number.

Crashes are cheap — someone gets paged and the run is repeated. The expensive failure is the run that completes, looks exactly like every other run, and is wrong: a survivor dropped by a bad join, a cached stage built on inputs that have since changed, a fallback that quietly replaced the answer that was asked for. Every design decision here is aimed at that second class.

Everything is synthetic and self-contained. No proprietary, employer, or government data is used anywhere in this repository, and the ground truth is generated so that estimator accuracy can be *scored* rather than asserted.

**This code was then attacked on purpose.** An adversarial review of the first working version found defects in both halves — most of them producing a plausible answer rather than an error, and two of them inverting the repository's own thesis. They are fixed, each has a named regression test, and [VALIDATION.md §9](docs/VALIDATION.md) documents every one with the input that demonstrates it. That section is the most useful thing here.

---

## The problem

A fleet of aircraft. A family of replaceable parts. The question the supply chain has to answer is *how many spares of each, and why that many* — from maintenance records that are sparse, censored, and dirty:

- **Sparse.** Reliable parts rarely fail. Several part numbers have never failed at all, so no standalone estimate of their failure rate exists.
- **Censored.** Most installed units are still running. They have not failed *yet*, and discarding them biases every estimate low — badly. Dropping survivors moves the fitted scale from 2042 hours to 325.
- **Dirty.** Missing install dates, repairs closed before the removal that caused them, durations recorded in days where hours belonged, duplicated work orders, and — the expensive one — removals that were never failures at all.

---

## Results

Measured on the runs committed in `results/`, reproduced by CI on every push.

### Ingest hardening, under deliberate fault injection

The generator corrupts records and labels what it corrupted, so detection is scored rather than eyeballed.

| | |
|---|---|
| Fault classes detected | **8 of 8, at 100%** |
| False positives on clean records | **0.0%** (cap 5%) |
| Record reconciliation | accepted + quarantined = input, **asserted every run** |
| Behaviour above the quarantine threshold | **refuses to emit a fleet** |
| Behaviour on an empty file | **refuses** — 0/0 is NaN, and a NaN must fail closed |

And the number that shows why it matters. The same records, through a naive ingest that treats every removal as a failure:

| | failures | error vs truth |
|---|---|---|
| Ground truth | 50 | — |
| **Hardened ingest** | 43 | **−14%** |
| Naive ingest | 156 | **+212%** |

The naive path is not reading corrupted data. Those removal records are perfectly valid — no schema check would ever flag them — and the resulting demand forecast is wrong by a factor of three. **Schema validation catches malformed data; only domain knowledge catches well-formed wrong data.**

### Statistical validity

| Check | Result |
|---|---|
| Credible interval coverage (60 replicate fleets, 900 intervals) | **0.887** against a nominal 0.90, band [0.856, 0.944] |
| Sampler convergence | split R-hat < 1.03 across 4 overdispersed chains |
| Parameter recovery | truth inside the 90% interval for every hyperparameter |
| Partial vs complete pooling (25 paired replicates) | partial wins, **t = +2.30 / +3.19** |
| Partial vs no pooling | better in direction, **not significant when sparsest** — reported, not asserted |
| Closed-form expected backorders | matches a 100,000-sample Monte Carlo to **0.0013** |

Coverage is the one that matters. Recovering the truth once proves very little: a badly calibrated model with absurdly wide intervals passes that test every time. Calibration is a frequency property, so it is measured by repetition — and a 90% interval that contains the truth 88.7% of the time means the uncertainty attached to a spares recommendation can be taken at face value.

### Decision output

From the committed demo run: **fleet availability 0.135 → 0.821 for $199,860** of a $200,000 budget, as a ranked buy list where each purchase records the expected backorders it removed and the availability after it. Because the greedy order *is* the efficient frontier, the same pass answers the question a programme office actually asks: **90% availability would cost $283,960.**

In that run the ingest accepted 391 of 441 records and quarantined 50 (11.3%), and the naive path's failure count came out **+450%** against truth — a worse margin than the test fleet above, because this fleet has fewer real failures relative to non-failure removals. The sparser the failures, the more the naive assumption costs.

---

## Quick start

No toolboxes, no licences, no external packages. Runs on GNU Octave or MATLAB, and on a bare Python 3 install.

```bash
# numerics + verification suite  (~6 minutes, 6 suites)
cd matlab
octave-cli demo_pipeline.m
octave-cli tests/run_all_tests.m

# orchestration + narrative
cd ../python
python3 -m pytest tests/ -q            # 40 tests
python3 run_pipeline.py                # full cross-language run

# the failure paths, on demand
python3 run_pipeline.py --resume       # completed stages served from cache
python3 run_pipeline.py --fail-fit     # retry, degrade, and say so
python3 run_pipeline.py --break-gate   # refuse to publish, exit 3
```

---

## How it fits together

```
raw maintenance records
        |
        |  ingest_maintenance_records.m     quarantine, never silently drop
        v                                   refuse above the quarantine threshold
   clean fleet + quarantine report
        |
        |  fit_hierarchical_weibull.m       partial pooling across part numbers
        v                                   hand-rolled Metropolis-within-Gibbs
   posterior draws  --> convergence_report.m  GATE: every R-hat finite and < 1.05,
        |                                     acceptance in range
        +---> attribute_evidence.m          how much of each estimate is borrowed
        |
        |  predict_demand.m                 conditional on how old the fleet is;
        v                                   aleatory and epistemic kept separate
   predictive demand
        |
        |  marginal_spares_allocation.m     METRIC-style greedy; the buy ORDER
        v                                   is the explanation
   buy list + availability frontier
        |
        |  explain/narrate.py               prose from the structured result
        v  explain/provenance.py            GATE: no untraceable number,
   auditable narrative                      no omitted warning

  all stages wrapped by pipeline/runner.py:
  content-addressed keys (including upstream HEALTH), atomic checkpoints
  proven to round-trip, transient-vs-permanent retry, propagating
  degradation, hard gates
```

| Path | What lives there |
|---|---|
| `matlab/` | Numerics: ingest, hierarchical fit, attribution, demand, allocation |
| `matlab/tests/` | 6 suites — fault injection, guards, recovery, coverage, estimator comparison |
| `python/pipeline/` | Orchestration: manifest, runner, error taxonomy, fault harness |
| `python/explain/` | Result contract, narration, numeric provenance validator |
| `python/tests/` | 40 tests — 26 hardening, 14 provenance |
| `docs/` | [METHOD.md](docs/METHOD.md) — the model. [VALIDATION.md](docs/VALIDATION.md) — what was checked, and what broke |

---

## Seven rules, and what each one costs to break

**1. No record disappears without a reason.** Every input row leaves ingest accepted or quarantined under a named reason code, and the two counts are asserted to reconcile. A pipeline that drops rows on a failed comparison keeps running and keeps producing numbers.

**2. A repair is a decision and is logged as one.** Reclassifying a no-fault-found removal as censored is a modelling judgement, not data cleaning. It is applied by policy, counted, and reported, so a reviewer can find it and disagree with it.

**3. Too much quarantine means stop.** Past a threshold the surviving records are no longer a sample of the fleet — they are a sample of the records that happened to be well formed, which is a different and unknown population. Written so that a NaN rate fails *closed*.

**4. Never trust a checkpoint you cannot verify.** Every checkpoint is checksummed, written atomically via rename, and proven to survive a JSON round trip *before* it is written. A checksum proves the file survived the disk; the round-trip proof is what makes it faithful to what the stage returned.

**5. Retry only what a retry can fix.** Errors are classified by remedy, not by cause, with permanent patterns taking precedence. Anything unrecognised is treated as permanent, because retrying an unknown failure mode is how a crash becomes a hang.

**6. Degrade visibly or not at all.** A fallback marks its result, the mark propagates downstream *through the cache*, and the narrative layer refuses to publish a degraded result without saying so.

**7. A degraded result is recorded but not reused.** It goes to a sidecar file, so a recovery run cannot overwrite the record of the outage, and a resume never mistakes the fallback for the answer.

The same idea runs through both gates. The convergence gate refuses to publish numbers from a chain that has not mixed; the provenance gate refuses to publish prose containing a figure no solver produced. In both cases the output would have looked entirely normal.

---

## On "hallucination-free"

A model is permitted to choose words. It is never permitted to originate a number.

`explain/narrate.py` is deterministic and needs no model — most of what a sustainment brief has to say is the same nine sentences with different numbers in them. Where a model genuinely earns its place (open-ended questions, comparisons across reporting periods), the architecture does not change: it receives the structured result and nothing else, its output passes through `provenance.enforce()`, and a failed check falls back to the template rather than being re-prompted.

The validator derives its tolerance from how each number was *written*, so prose may round for readability but cannot invent precision: `0.887` may be written as `0.89`, and writing `0.8874` fabricates a fourth digit and is caught. It rejects magnitude notation outright, because `1e5` decomposes into digits that are individually innocent. And it enforces the mirror-image failure — a narrative that omits a degradation warning is rejected even though every number in it is correct, and a *denial* ("this run is not degraded") does not satisfy the requirement.

Hallucination-freedom is not a property of a model, and no amount of prompting makes it one. It is a property of a pipeline that refuses to pass an unverifiable number through, whatever produced it.

---

## Known limits

Stated here rather than left to be discovered. [VALIDATION.md](docs/VALIDATION.md) has the evidence for each.

- **σ is weakly identified with few part numbers.** At 12 groups the posterior for part-to-part spread is pulled toward its prior; recovery is clean by 40 groups. σ coverage is 0.833, below nominal, and it is the one parameter whose interval should not be taken at face value.
- **Partial pooling's advantage over a well-implemented no-pooling baseline is not statistically established in the sparsest regime.** Better in direction at every horizon tested; at 25 paired replicates the margin is within noise. An earlier version of this repository asserted more than the evidence supported.
- **Demand approximates expected renewals by the cumulative hazard.** Verified by Monte Carlo to be *conservative* for a wearing-out population — it over-states renewals by 3% at short horizons and more at long ones.
- **The budget-constrained allocation is a greedy heuristic**, not the knapsack optimum. It recovers roughly two-thirds of the gap to an exact dynamic program.
- **Availability uses the single-indenture METRIC form**, which assumes backorders are independent across part numbers.
- **The time-on-wing fence is a policy input, not a derived quantity.** It is the one check that cannot be decided from a record alone.

---

## References

- Sherbrooke, C.C. (1968). METRIC: A Multi-Echelon Technique for Recoverable Item Control. *Operations Research* 16(1).
- Muckstadt, J.A. (2005). *Analysis and Algorithms for Service Parts Supply Chains.* Springer.
- Gelman, A. et al. (2013). *Bayesian Data Analysis*, 3rd ed. — hierarchical models, shrinkage, split R-hat.
- Meeker, W.Q. & Escobar, L.A. (1998). *Statistical Methods for Reliability Data.* — Weibull inference under censoring.
- Roberts, G.O. & Rosenthal, J.S. (2001). Optimal scaling for various Metropolis-Hastings algorithms. *Statistical Science* 16(4).

## License

MIT — see [LICENSE](LICENSE).

---

## Companion repositories

One of three, each mirroring a different product in the same domain. They share a design stance -- synthetic data with hidden truth, estimates scored against that truth rather than asserted, and a `failures.md` recording what went wrong and why -- but no code, so each stands alone.

| repo | mirrors | what it does | stack |
|---|---|---|---|
| **sustainment-analytics** (this one) | | sparse censored failure records to an auditable spares buy list | MATLAB + Python |
| [fleet-reliability-twin](https://github.com/BootstrapAI-mgmt/fleet-reliability-twin) | | gamma-process degradation, sensor-fault isolation, remaining useful life | MATLAB + Python |
| [depot-flow-twin](https://github.com/BootstrapAI-mgmt/depot-flow-twin) | | Java discrete-event depot simulation, turnaround estimation and forecasting | Java 21 + Python |
