# Validation

What was checked, what the numbers were, and — the part that is usually missing — what broke and what it cost to find out.

Reproduce with:

```bash
cd matlab && octave-cli tests/run_all_tests.m     # ~6 min, 6 suites
cd python && python3 -m pytest tests/ -q          # ~1 s, 40 tests
```

CI re-runs all of it on every push, including the demo and the three fault paths.

Committed output: [`results/verification_output.txt`](../results/verification_output.txt).

---

## 1. Numerical primitives

Every toolbox function this repository avoids had to be rewritten, and a rewritten primitive is a place for a silent error to live. Each is checked against a property known in closed form.

| Check | Observed | Expected |
|---|---|---|
| `pctile` median of 1:100 | 50.5000 | 50.5 |
| `pctile` clamps at sample extremes | pass | — |
| Poisson(4.5) mean / variance | 4.499 / 4.494 | 4.5 / 4.5 |
| Poisson P(X=0) | 0.01107 | 0.01111 |
| Weibull mean, `lambda*Gamma(1+1/k)` | 1329.4 | 1328.4 |
| Fraction failed by horizon | 0.100 | 0.103 |
| **Dropping survivors biases the scale low** | **325** | vs 2042 correctly censored |

That last row is the one to read twice. It is not a unit test so much as a demonstration of the single most expensive mistake available in reliability work: a 6× error in characteristic life, produced by an analysis that runs cleanly and reports nothing unusual.

---

## 2. Ingest hardening under fault injection

The generator corrupts records and labels what it corrupted, so detection is **scored**, not eyeballed.

Detection is credited under *any* reason code rather than the injected name. Corrupting one field often makes a record violate a different rule first, and catching it for the wrong stated reason is still catching it.

| Injected fault | Count | Caught |
|---|---|---|
| `blank_serial` | 5 | 100% |
| `duplicate` | 7 | 100% |
| `future_stamp` | 4 | 100% |
| `missing_install` | 7 | 100% |
| `negative_repair` | 5 | 100% |
| `negative_tow` | 5 | 100% |
| `orphan_repair` | 5 | 100% |
| `unit_mismatch` | 4 | 100% |

Plus: **0.0% false positives** on clean records (cap 5%); reconciliation asserted (325 + 42 = 367); identical input yields an identical quarantine set; and above the quarantine threshold the ingest **refuses to return a fleet at all**.

### What the hardening is worth

| | Failures counted | Error |
|---|---|---|
| Ground truth | 50 | — |
| Hardened ingest | 43 | −14% |
| Naive ingest | 156 | **+212%** |

The hardened path's −14% is the honest cost of quarantine: some quarantined records were real failures. That cost is *reported*. The naive path's +212% comes from treating every removal as a failure — and those removal records are entirely valid, so no schema check would ever flag them.

**Schema validation catches malformed data. Only domain knowledge catches well-formed wrong data.**

### Two bugs this test found

**The generator was injecting impossible faults.** `negative_tow` and `negative_repair` were being applied to still-installed units — records with no removal at all. The result was a perfectly valid record, and detection sat at 60%, which read as an ingest miss when it was a generator error. Fault injection now declares eligibility per fault class.

**A real check was missing.** Chasing the above surfaced a case the contract did not cover: a repair timestamp on a unit that was never removed. The two fields contradict each other and one of them is wrong. `Q_ORPHAN_REPAIR` exists because the fault harness went looking.

### The one check that needed a second pass

`unit_mismatch` — a duration recorded in days where hours belonged — initially slipped through completely. It is not malformed. It is a small positive number where a large positive number belonged, and no amount of schema validation will ever see it.

Catching it requires a reference distribution, so the fence is applied in a **second pass** against the median time-on-wing of records that passed pass one. The fence ratio is a *policy input*, because it encodes an engineering judgement about the fleet rather than a fact about the file.

The first version of the fence produced ~11 false positives per run — early non-failure removals, generated uniformly from zero. That was a defect in the synthetic data, not the fence: scheduled and convenience removals do not happen at five flight hours. With realistic removal timing the false-positive rate is 0.0%, and the residual risk (a genuine infant-mortality failure quarantined as a recording error) is measured rather than assumed away.

---

## 3. Sampler correctness

| Parameter | Truth | Posterior mean | 90% interval | Contains truth |
|---|---|---|---|---|
| `k` | 1.800 | 1.596 | [1.352, 1.854] | yes |
| `mu` | 8.006 | 8.152 | [7.860, 8.486] | yes |
| `sigma` | 0.450 | 0.583 | [0.390, 0.827] | yes |
| `lambda_i` | — | — | — | 27 of 30 (90%) |

Convergence, quoted from the artifacts rather than from memory: the recovery table above is `test_parameter_recovery`'s output (3 chains; committed in `results/verification_output.txt`), and the committed 4-chain demo reports split R-hat max **1.011** against the 1.05 gate with acceptance in range (`results/analysis_result.json`, `model`). An earlier version of this paragraph quoted per-parameter R-hats that appeared in no committed output and attributed the 3-chain test's table to "4 overdispersed chains" — an unprovenanced number in the document about provenance.

---

## 4. Credible interval calibration

**The single most important result in this document.**

Recovering the truth once proves very little — a badly calibrated model with absurdly wide intervals passes that test every time. Calibration is a *frequency* property, so it is measured by repetition: 60 independent synthetic fleets, fit each, count how often the 90% interval contains the value that generated the data.

| | |
|---|---|
| Replicates / intervals | 60 fleets, 900 part-level intervals |
| Clustered SE | 0.0147 (a naive SE would be 0.0100 — **1.5× optimistic**) |
| Band, ±3 SE | [0.856, 0.944] |
| **`lambda_i` coverage** | **0.887** |
| `k` coverage | 0.967 |
| `mu` coverage | 0.933 |
| `sigma` coverage | 0.833 |

Parts within one replicate share hyperparameter draws and are therefore correlated. Treating all 900 checks as independent would give a band far too tight and a test that fails at random. The standard error is *estimated from the observed between-replicate spread* rather than assumed — measured, not asserted.

**Interpretation.** `lambda_i` coverage of 0.887 against a nominal 0.90 means the uncertainty attached to a spares recommendation can be taken at face value. `sigma` coverage of 0.833 means it cannot — see below.

---

## 5. Known limit: σ is weakly identified with few groups

Measured by `test_sigma_identification.m`, which fits **8 replicate fleets per size** and regenerates this table on every run (truth σ = 0.45):

| Part numbers | mean `sigma`-hat ± SE (8 replicates) | mean 90% CI width |
|---|---|---|
| 12 | 0.520 ± 0.101 | 0.737 |
| 40 | 0.433 ± 0.050 | 0.335 |

The limitation at 12 groups is **width and prior sensitivity, not a large systematic bias**: the mean error (+0.07) is within one replicate SE of zero, while the interval is 2.2× wider than at 40 groups. Two earlier versions of this section were wrong in instructive ways. The first quoted a single-fleet table (0.742 at 12 groups) with no generating command and read its one draw as "over-estimation"; when the numbers were first regenerated with fresh seeds, the single-draw "bias" came out with the **opposite sign** — which is the difference between one draw and a bias, the same lesson §4 teaches about coverage. A bias is a property of repetition, so the test now replicates, and this document quotes only what the test prints. The practical consequence stands: with a dozen part numbers, `sigma` is the one parameter whose interval should not be taken at face value (its coverage in §4's study is 0.833 against a nominal 0.90), and any downstream quantity that leans on it inherits that.

---

## 6. Estimator comparison, and a retracted finding

Three estimators scored as RMSE in `log lambda` over **all** parts, paired across 25 replicates per horizon.

| Horizon | Failures | No-MLE parts | partial | none | complete |
|---|---|---|---|---|---|
| 400 | 11 | 190/375 | **0.5316** | 0.5864 | 0.6032 |
| 800 | 33 | 79/375 | **0.4088** | 0.4433 | 0.4899 |

| Horizon | paired t vs none | paired t vs complete |
|---|---|---|
| 400 | +1.12 | **+2.30** |
| 800 | +1.34 | **+3.19** |

**Supported:** partial pooling beats complete pooling decisively at both horizons. Part numbers genuinely differ, and complete pooling denies it.

**Not supported:** that partial pooling beats a well-implemented no-pooling baseline in the sparsest regime. It is better in direction everywhere, and at 25 replicates the margin is within noise.

### How this test was wrong twice

**v1 was biased in the baseline's favour.** It scored only the parts where the no-pooling MLE existed. That conditions on the parts with the *most* data and silently drops the ~47% of part numbers where the baseline has nothing to say — the exact cases pooling exists to handle. The apparent advantage of pooling shrank to 2%, not because pooling stopped helping but because the comparison had quietly excluded the cases it helps most.

**v2 was underpowered, and produced a finding that did not replicate.** With the selection bias fixed but only 5–6 replicates, one run showed partial pooling *losing badly* in the sparsest regime (0.6697 vs 0.5268). A mechanism was available and fitted perfectly: with few failures, `sigma` is weakly identified, is pulled up by a diffuse prior, the model shrinks too little, and per-part estimates scatter further than the family value would have. Section 5 above independently confirms that `sigma` really does behave that way.

The mechanism was real. The finding was noise. At a different replicate count the result reversed, and a follow-up at 25 paired replicates showed partial pooling ahead at every horizon under both priors. RMSE here is dominated by rare large errors, so a handful of replicates cannot rank estimators that sit this close together.

> **A mechanism that explains an observation is not evidence that the observation is real.** The tidy causal story was what made the wrong conclusion convincing. What caught it was re-running with different seeds and noticing the result move.

`test_pooling_benefit.m` is now paired, reports t-statistics, and asserts only the claim the evidence supports.

---

## 7. Pipeline hardening (40 Python tests)

| Group | What is asserted |
|---|---|
| Retry semantics | Transient failures absorbed; backoff grows `[0.1, 0.2]`; permanent failures **never** retried; unrecognised exceptions treated as permanent |
| Checkpoint integrity | Resume skips completed work; truncated checkpoints re-run; **tampered checkpoints caught by checksum**; no `.tmp` files survive |
| Cache invalidation | Changed params, changed code version, and **changed upstream results** all invalidate |
| Degradation | Fallback marks the result; the mark **propagates downstream**; degraded results are not served from cache; no fallback means the run stops |
| Gates | Gate failure is never retried and never falls back; leaves no checkpoint |

Three of these deserve naming.

**The tampered checkpoint.** The file is present, parses cleanly, and is wrong. Nothing but a checksum notices. Without one, the pipeline returns `"silently substituted"` as a computed result and reports success.

**Upstream invalidation.** Stage A re-runs with new inputs; stage B's own parameters are unchanged; B reuses a cache built on the *old* A. No crash, no warning, and a final number assembled from two different versions of the world. Chaining upstream keys into downstream keys makes that impossible to express.

**A degraded result must not be cached for reuse — found by running it.** The test originally asserted the opposite: that degraded status survives a resume. Exercising it against the real pipeline showed why that is wrong. The fallback lands under the same key as the primary computation, so every later resume served the fallback and the primary path was never retried. **A ten-minute outage became a permanently degraded pipeline**, with every subsequent run reporting degraded and nothing to indicate why. Degraded checkpoints are still written — the audit trail matters — but they are a miss for execution. `reuse_degraded=True` exists for deliberately replaying a historical run.

---

## 8. Provenance enforcement (14 tests)

Written as attacks: each is a way a fluent, confident narrative could carry a number nobody computed.

| Attack | Caught |
|---|---|
| Invented figure (`$412,000`) | yes |
| Plausible figure adjacent to a real one (`0.834` vs `0.823`) | yes |
| Invented precision (`1.0261` from a stored `1.026`) | yes |
| Arithmetic the pipeline did not do (`30/12 = 2.5`) | yes |
| A narrative that omits a degradation warning | yes |
| Booleans licensing stray digits (`True` is an `int` in Python) | yes |
| Legitimate rounding (`0.82` from `0.823`) | correctly allowed |
| A stored fraction written as a percentage (`82.3%`) | correctly allowed |

The final test narrates the **real** committed pipeline result and asserts every number in it traces.

Note the third and fourth rows. `2.5` is arithmetically true and derivable from two stored fields, and it is still refused: a derived figure is a new claim and belongs in a field, not in the model's discretion. `1.0261` is refused because rounding for readability is a formatting decision while adding a digit is a fabrication — the tolerance is derived from how the number was *written*, so the validator can tell them apart.

---

## 9. What an adversarial review found

The first working version of this repository passed every test it had. It was then read line by line against its own claims by two reviewers whose brief was to find defects, not to be reassuring — with the instruction to reproduce anything they suspected before reporting it.

They found defects in both halves. Almost all of them produced a *plausible answer* rather than an error, which is the exact category this project exists to defend against, and two of them inverted its central thesis: a hardening pipeline whose degradation mark and whose checkpoint verification both failed silently.

Everything below is fixed and carries a named regression test. The tests are deliberately named for the guarantee they protect rather than the function they call.

### The two that mattered most

**Degradation did not survive the cache.** `tests/test_pipeline_hardening.py::test_degradation_survives_a_warm_downstream_cache`

The stage key was built from name, code version, params, and upstream *keys* — but not from whether an upstream had degraded. The cache-hit branch then returned the cached flag without ever consulting the current upstream. So a downstream stage warmed by a healthy run was served, unmarked, into a run whose upstream had fallen back to stale data.

Reachable through the public API with no corruption at all:

```python
healthy = StageResult(value={"rows": 441}, key="feed@v1")
Runner(d).run("rollup", fn, upstream=[healthy])            # warms the cache

stale = StageResult(value={"rows": 441}, key="feed@v1",
                    degraded=True, degraded_reason="replica 6h behind")
Runner(d).run("rollup", fn, upstream=[stale])              # degraded=False
```

End to end in the demo it produced a published narrative with **no degradation banner**, still headed "every figure below traced to a solver field", carrying figures that were not the data the run had used — and an exit code of zero. It also let the degraded run overwrite `last_good.json`, corrupting the fallback reference itself.

Closed twice over: degradation is now part of the stage key, and a clean cached result is treated as a *miss* when the current upstream is degraded.

**A checkpoint could silently change the value, and the checksum could not detect it.** `test_a_checkpoint_cannot_silently_change_the_value`

Checkpoints were encoded with `json.dumps(..., default=str)`, and the digest was taken *after* that lossy encode on both write and read. The corruption therefore verified as intact.

| stage returned | came back from cache | checksum flagged |
|---|---|---|
| `(1, 2, 3)` | `[1, 2, 3]` | no |
| `{1, 2, 3}` | `'{1, 2, 3}'` — a **string** | no |
| `{1: 'a', 2: 'b'}` | `{'1': 'a', '2': 'b'}` | no |
| `Decimal('0.887')` | `'0.887'` | no |

A stage summing a cost table keyed by part number returned **$6,020 on a fresh run and $0 on resume**. No exception, no log event, valid checksum.

A checksum proves the file survived the disk. It says nothing about fidelity to what the stage returned, and those are different claims. Payloads are now proven to round-trip *before* they are written, and a non-round-trippable value is a loud `PermanentError` naming the stage.

### The rest, by class

**Silent NaN, and gates that could not see it** — `tests/test_guards.m`

| Defect | What it produced |
|---|---|
| `log(t)` evaluated for every record and zeroed with `(~censored) .*`, so a record at `t = 0` gave `0 × (−Inf) = NaN` | Every Metropolis comparison for that part evaluated false; the shared shape froze because its acceptance ratio was NaN too. Four flat chains still produced means, intervals, and a buy list. Acceptance for `k` was **0.000** and nothing looked at it. |
| An empty record set gave `quarantine_rate = 0/0 = NaN`, and `NaN > 0.15` is false | The refusal gate was silently inoperative on the one input where it mattered most. The pipeline fitted a model to nothing, passed convergence, and reported demand. |
| `max()` drops NaN, so `max([NaN 1.001])` is `1.001` | `split_rhat` returns NaN for a chain that never moved — so the most broken possible sampler state reported the healthiest possible number, right next to `converged: true`. |
| `poissrnd_basic` accepted any rate | A NaN rate returned **zero demand** — zero spares, a healthy-looking report. A negative rate made the running pmf alternate sign and returned arbitrary counts. |

The convergence gate now requires every R-hat to be **finite** before comparing any of them to a threshold, and additionally gates on acceptance rate, which was the loudest available signal and was being ignored.

**Wrong answers, quietly** — `test_guards.m`, and §4 of [METHOD.md](METHOD.md)

| Defect | Measured cost |
|---|---|
| The greedy allocation **stopped** at the first unaffordable item instead of ranking among affordable ones | Re-measured by `test_allocation_optimality.m` (which regenerates on every run): on its $40,000 configuration the stop rule strands **$1,750** and **0.31 expected backorders** (~half an availability point) against the masked rule; the masked greedy in turn sits **0.002 backorders** above the exact DP. The numbers this row used to quote ($3,870, 1.15 pts, 1.71 pts) came from a configuration and a DP that no longer existed anywhere in the repository — including, it turned out, the claim that greedy prefix-optimality "holds exactly": writing the DP disproved the *exactly* (unequal integer costs leave a ~2×10⁻³-backorder gap), which is precisely why the claim is now a measured bound with a named test. |
| Demand assumed every installed unit was **brand new** at the start of the lead time | The demo fleet is observed for 600 hours and then sized for a 400-hour lead time. Conditional hazard from age 600 is **3.13×** the hazard from age 0; at steady state, 5.6×. The model was under-buying spares, most for the oldest units. |
| Expected backorders were estimated by counting 4,000 Poisson samples | `EBO(s) − EBO(s+1)` is `P(D > s)`, with a sampling SE near 0.008 — comparable to the gap between adjacent candidates. Re-drawing the *same* posterior eight times moved the buy order from rank 8 onward. The docstring calls that order the explanation; an explanation that changes when nothing changed is not one. Now closed-form, validated against 100,000 samples to 0.0013. |
| The stated direction of the renewal approximation was **backwards** — and its first correction quoted an impossible number | The comment claimed the cumulative hazard was "slightly optimistic" for `k > 1`. Recomputation says it over-states renewals by 0.8% / 28% / 191% at `T/λ` = 0.13 / 1.0 / 4.0 — it is *conservative*. The original claim had been reasoned rather than measured; the measurement that replaced it then quoted a short-row `M(T)` of 0.0257 at `H = 0.0266` from an under-sized Monte Carlo, which the one-line bound `M(T) ≥ 1 − e^(−H) = 0.02625` rules out — an impossible value that sat in the docs as "verified". The table is now recomputed by the renewal-table guard in `test_guards.m` (convolution series for the short row, seeded MC for the rest). |

**The provenance gate had holes in both directions** — `tests/test_provenance.py`

| Attack | Result before |
|---|---|
| `"The sampler drew 1e5 posterior samples"` | **Passed.** The regex decomposed it into `1` and `5`, both of which existed in the result, so a fabricated 100,000 walked through a gate whose entire purpose is that a model may never originate a number. Same for `1.2e4`, `3x10^6`, `2^10`. |
| `"This run is not degraded in any way"` | **Passed** the omission check on a degraded result. So did "Nothing was degraded", "The estimate is undegraded", and a glossary entry. A denial contains the word. |
| The quarantine rule read `result["quarantine_rate_pct"]` | The field lives at `result["meta"]["quarantine_rate_pct"]`. A third of the omission check was **dead code that always reported success**. |
| `"records from 1998-2004 for tail number A-1042"` | **Failed** — wrongly. With no left boundary on the minus sign it yielded `1998`, `-2004`, `-1042`. In a sustainment brief the part number *is* the primary key, so every ISO date and MIL-STD designator broke the check on truthful prose. |
| A degradation reason containing a digit (`"solver returned HTTP 503"`) | **Crashed the run.** The banner interpolates the reason and then passes through `enforce()`, so the one line that must always print was the only line whose text was unconstrained. A visible degradation became a hard failure. |

Boolean facts now require a specific phrase that cannot be negated into existence; numeric facts require the **value** to appear, so boilerplate that mentions quarantine without stating a rate no longer satisfies the rule.

A second adversarial pass found the hyphen fix had over-corrected — everything after a *digit*-hyphen was invisible, so the right endpoint of every numeric range ("93-97.5% of target") was a free fabrication — and two more gaps besides: leading-dot decimals (".999") never matched, and magnitude *words* ("30 thousand", "1.5M") walked around the 1e5 rule with only the mantissa validated. All three are closed with attack tests in `tests/test_provenance.py`. The rule that resulted: a digit before the hyphen means a numeric range and **both endpoints are claims**; a letter before the hyphen means a designator (`A-1042`, `MIL-STD-1553`) and stays exempt. One consequence is deliberate: a date range like "1998-2004" now requires both years to trace to the result — the template never emits dates, so a model writing one is originating numbers, which is the thing this gate exists to refuse.

**Stage identity could collide** — `test_distinct_params_cannot_collide`, `test_upstream_order_is_part_of_the_identity`

`canonical()` used `default=str`, so parameters were hashed by their repr. `{"h": (1, 2)}` and `{"h": [1, 2]}` collided. Two distinct config *objects* collided whenever CPython reused an address — a run with `horizon=800` was served the `horizon=400` result from cache, unmarked. Upstream keys were also `sorted()`, so a stage computing `target − baseline` could be served the negation of its own answer.

A parameter the key function cannot serialise is one it cannot promise to distinguish, so it now raises rather than guessing.

**Retry classified by substring** — `tests/test_retry_classification.py`

`parse error: syntax error near line 40 of /opt/matlab/licenses/check.m` was classified **transient** because the *file path* contained "licenses", then retried three times with backoff and degraded to stale data. That is verbatim the failure `errors.py` opens by describing. Permanent patterns now take precedence, matching is word-bounded, and only the first few lines are read — a long stack trace mentions many files and the diagnosis belongs to the error, not to the directory it happened in.

**A degraded checkpoint was overwritten by the run that recovered from it** — `test_the_degraded_record_is_not_overwritten_by_recovery`

The docstring claimed degraded results were "kept for the audit trail". The recovery run wrote over them under the same key, so `reuse_degraded=True` — the documented replay mechanism — could no longer reach the run it exists to reproduce. Degraded results now go to a sidecar.

**And one flag that did nothing.** `--resume --fail-fit`, one of two documented fault-injection flags and the first thing a reviewer would type, was a complete no-op: all three stages hit a warm cache before the fault function ever ran. Fault injection is now part of the stage's identity, because a fault-injected invocation *is* a different invocation — and CI runs the exact combination against a warm cache and requires the degradation banner to appear.

### What this section is for

Every one of these passed the original test suite. Most of them would have passed a code review too, because the code looked right and the output looked right — which is the point. The failure mode this repository is about is not the one that announces itself.

Two things generalise beyond this codebase.

**A guarantee is only as strong as the attempt to break it.** The degradation-propagation rule was written down first, implemented carefully, and tested — and the test only exercised the path where the cache was cold. The rule held everywhere it was looked at.

**Verification code needs the same scrutiny as the code it verifies.** The provenance validator, the convergence gate, and the quarantine threshold were all *checks*, and all three had holes: one accepted fabricated magnitudes, one could not see a dead chain, and one was inoperative on an empty file. A check that fails open is worse than no check, because it is also a claim.
