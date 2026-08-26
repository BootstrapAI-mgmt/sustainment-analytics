# Method

## 1. The estimation problem

A family of `N` interchangeable part numbers is installed across a fleet. For part `i`, unit `j`:

```
t_ij       ~ Weibull(shape = k, scale = lambda_i)
log lambda_i ~ Normal(mu, sigma)
```

Units still operating at the observation cutoff are **right censored**: they contribute `log S(t) = -(t/lambda)^k` rather than a failure density.

Three modelling choices carry the weight.

**Censored units are kept.** In the demo fleet 93% of installed units have not failed. Fitting only the failures — the default behaviour of any naive pipeline — biases the scale catastrophically low. `test_samplers.m` measures it directly: dropping survivors moves the fitted scale from 2042 hours to 325.

**The shape `k` is shared across the family.** The engineering claim is that interchangeable parts in a commodity family wear out the same *way* even though they wear out at different *rates*. This buys a great deal of statistical strength — every failure in the family informs `k` — and it is an assumption, not a fact. It is falsifiable by fitting `k` per part where data allows and checking whether the intervals overlap.

**The scales are partially pooled.** With several part numbers showing zero failures, no per-part estimate exists at all. Pooling is not a refinement here; it is the only estimator that returns a number for every part.

## 2. Inference

Metropolis-within-Gibbs, hand-rolled in `fit_hierarchical_weibull.m` — no toolbox, identical code path on MATLAB and Octave.

| Parameter | Update | Why |
|---|---|---|
| `lambda_1..N` | Vectorised block random-walk Metropolis | Given `(k, mu, sigma)` the part scales are **conditionally independent**, so all `N` proposals are drawn and accepted or rejected in one pass. No loop over parts. |
| `mu` | Exact Gibbs draw | Normal likelihood on `log lambda` with a Normal prior is conjugate. Spending a Metropolis rejection on a parameter you can sample exactly is wasted work. |
| `k` | Scalar random-walk Metropolis | Enters every part's likelihood; no conjugate form. |
| `sigma` | Scalar random-walk Metropolis on `log sigma` | Sampled on the log scale with the Jacobian carried explicitly. |

Proposal scales adapt toward 0.35 acceptance during burn-in (Roberts & Rosenthal 2001) and are then **frozen**, so the retained draws come from a time-homogeneous chain and remain a valid posterior sample. Four chains start overdispersed, which is what makes split R-hat a real test of mixing rather than four chains agreeing because they began together.

### Priors

| Parameter | Prior | Reasoning |
|---|---|---|
| `log k` | `Normal(log 1.5, 0.5)` | Centres on mild wear-out; admits `k < 1` if the data insists. |
| `mu` | `Normal(log 2000, 1.0)` | An order-of-magnitude statement about characteristic life. |
| `sigma` | `HalfNormal(0.75)` | Part-to-part scatter within roughly a factor of 4.5. Weakly informative — and see the identification limit in [VALIDATION.md](VALIDATION.md). |

## 3. Evidence attribution

The explanation a sustainment analyst needs is not a feature-importance score. It is: *how much of this number came from this part, and how much was borrowed?* That determines whether the estimate will move when the next failure is reported.

The borrowed fraction is the precision-weighted shrinkage factor, with the part's precision taken as the **observed Fisher information about `log λ_i` under right censoring**, evaluated at the posterior scale:

```
tau_data_i = k^2 * sum_j (t_ij / lambda_post_i)^k     (every unit j, survivors included)
tau_family = 1 / sigma^2
w_i        = tau_family / (tau_family + tau_data_i)
```

Under censoring, exposure *is* evidence — that is the entire reason survivors are modelled rather than dropped — and `sum_j z_ij` is the model's expected failure count given that exposure. An earlier version plugged in the *observed* failure count `d_i`, which zeroes the survivors' contribution: a never-failed part with 24 units and hundreds of hours each reported "100% borrowed" while its own posterior sat visibly tighter than the family prior, contradicting the number on the same screen. (The two definitions coincide at the part's own MLE, where the censored score equation gives `sum_j z_ij = d_i`; they part company exactly where attribution matters most — the zero- and few-failure parts.) `w_i` falls as evidence — failures *or* exposure — grows, lies in `(0, 1]`, and reaches 1 only for a part with no exposure at all. On the committed demo the two never-failed parts now report 65% and 63% borrowed rather than 100%.

> **An earlier definition failed.** The first version measured how far the posterior sat between the part's own MLE and the family mean. Under 90%+ censoring the marginal posterior for a part's scale is strongly right-skewed, so its summary can fall *outside* the interval spanned by those two anchors. The weight had to be clipped, and the clipped weights were not monotone in the failure count — a part with 9 failures and a part with 1 could report the same borrowed fraction. The empirical anchors are still reported for transparency; they are no longer what the weight is computed from.

## 4. Demand

For posterior draw `d` and part `i`, with unit `j` currently at age `a_ij`:

```
h_ij^d     = H(a_ij + T) - H(a_ij),   H(t) = (t / lambda_i^d) ^ k^d
Lambda_i^d = m_i * mean_j( h_ij^d )
D_i^d      ~ Poisson( Lambda_i^d )
```

**The age term is the point, and it was missing.** An earlier version used `m_i * (T/lambda)^k` — the same expression with every unit assumed brand new at the start of the lead time. For a wearing-out population that is not a small simplification:

| age at the start of the window | expected failures over 400 h | ratio to age 0 |
|---|---|---|
| 0 | 0.0266 | 1.00× |
| 600 | 0.0832 | **3.13×** |
| 2400 | 0.2140 | 8.05× |
| steady state | 0.1499 | 5.63× |

The demo fleet is observed for 600 hours and then asked for a 400-hour lead time, so it sat squarely in the 3× band. A model that forgets how old the fleet already is under-buys spares, and does so most for the oldest and most failure-prone units. Ages now come from the maintenance records: a unit still installed carries its full time on wing, and a slot whose unit was removed carries the age of the replacement fitted at that removal.

Two approximations remain, stated rather than left to be discovered.

**Expected renewals are taken as the cumulative hazard.** Checked against a true renewal process at `k = 1.8` — the short row by convolution series (exact to ~4e-7), the longer rows by Monte Carlo (4M and 2M paths, ratio standard errors under 0.001):

| `T/lambda` | H(T) used here | true M(T) | ratio |
|---|---|---|---|
| 0.133 | 0.0266 | 0.0264 | 1.008 |
| 1.00 | 1.0000 | 0.7832 | 1.277 |
| 4.00 | 12.126 | 4.163 | 2.913 |

So the cumulative hazard **over**-states renewals for an increasing-failure-rate population: the approximation is *conservative*, and small in the short-lead-time regime it is used in. Two earlier versions of this table were wrong in two different ways: the first claimed the opposite *direction*, on intuition rather than measurement; the second quoted a short-row M(T) of 0.0257 from an under-sized Monte Carlo — an **impossible** value, since any renewal function satisfies `M(T) ≥ F(T) = 1 − exp(−H) = 0.02625`, and the one-line bound that falsifies it went unchecked. The table is now recomputed by a named regression test (`test_guards.m`, "renewal table"), which is the only reason to believe it will stay correct.

**Re-replacement within the window is ignored.** A unit that fails partway through the lead time and is replaced could in principle fail again before the window closes. Negligible while per-unit demand is well below 1, which it is here.

Drawing the Poisson **once per posterior draw**, rather than once at a fitted point estimate, is what makes the forecast carry both sources of uncertainty:

```
Var(D) = E[Var(D | Lambda)]  +  Var(E[D | Lambda])
       =    E[Lambda]        +      Var(Lambda)
         ----------------      ----------------
            aleatory              epistemic
```

In the demo fleet the epistemic share runs 47–66% (median 57%). Sizing spares off a plug-in point estimate silently discards that entire share — and it is largest for the parts with fewest recorded failures, which are exactly the parts that drive availability risk.

## 5. Allocation

Expected backorders, in closed form rather than by counting samples:

```
EBO_i(s) = E[ (D_i - s)^+ ] = L(1 - F(s-1; L)) - s(1 - F(s; L)),  averaged over draws
```

This replaced a sample-counting version, and the reason is not efficiency. The marginal difference `EBO(s) - EBO(s+1)` is exactly `P(D > s)`, which at 4,000 Poisson samples carries a standard error near 0.008 — comparable to the gap between adjacent candidates once the buy list is a few items deep. Re-drawing the same posterior eight times moved the buy **order** from rank 8 onward. Since the order is what this section calls the explanation, an explanation that changes when nothing changed is not one. The closed form removes the sampling noise and leaves only the posterior uncertainty, which is real and belongs there. It is validated against a 100,000-sample Monte Carlo to within 0.0013.

Availability follows Sherbrooke's single-indenture form:

```
A = prod_i ( 1 - EBO_i(s_i) / (Z * Q_i) ) ^ Q_i
```

for `Z` aircraft carrying `Q_i` units of part `i` each. It assumes backorders land independently across part numbers, which is what permits greedy optimisation rather than a joint solve.

`marginal_spares_allocation.m` repeatedly buys the single spare that removes the most expected backorders per dollar, **ranked among the candidates it can currently afford**. Because `EBO` is convex and decreasing in stock level, one pass yields the whole cost/EBO curve. How close that curve runs to optimal is *measured*: `tests/test_allocation_optimality.m` implements an exact budget-indexed dynamic program for the EBO objective and, on its fixed demo-scale configuration, finds every greedy prefix within **~2×10⁻³ expected backorders** (of totals near 20) of the DP at its own spend. An earlier version of this paragraph claimed the prefix optimality "holds exactly", citing a DP that existed nowhere in the repository; writing the DP is what *disproved* the "exactly" — with unequal integer costs the greedy can sit a hair above the optimum — and the claim is now the measured bound. Availability weights each part's backorders differently, so the availability-optimal allocation is a different, combinatorial problem that neither the greedy nor this DP solves.

Affordability is a **mask, not a stop**. An earlier version broke out of the loop the first time the best-ranked candidate exceeded the remaining budget — leaving money unspent while cheaper parts still had affordable units with positive return. Re-measured by the same named test: on its $40,000 configuration the stop rule strands $1,750 and 0.31 expected backorders (about half an availability point) against the masked rule. Earlier versions of this document quoted a different configuration's numbers from memory; only the test's regenerating output is quoted now.

The budget-constrained result is a greedy heuristic for what is formally a knapsack — measured at 0.002 expected backorders (under 0.01%) above the exact DP at the tested budget. `alloc.stop_reason` records why the list ended — `budget`, `stock_cap`, or `no_gain` — so those three are never confused for one another.

**Why greedy rather than an integer program.** Not speed. The *order* of the buy list is itself the explanation. "This part was bought 7th because at that point it returned 0.00184 backorders removed per dollar, against 0.00156 for the next candidate" is an audit trail a supply chain officer can challenge on its merits. A solver returning an optimal vector supports no such conversation — and in a setting where the recommendation has to be defended rather than merely computed, that difference is the whole point.

## 6. Where explainability actually lives

Three places, none of them a post-hoc attribution method:

1. **The model is interpretable by construction.** A Weibull scale per part with a shared shape is a statement an engineer can argue with.
2. **The estimate carries its provenance.** Every part reports what fraction of its number was borrowed rather than observed.
3. **The decision carries its reasoning.** The buy order records the marginal return that justified each purchase.

Post-hoc attribution applied to an opaque model would produce something that *looks* like all three and supports none of them.

## References

- Sherbrooke, C.C. (1968). METRIC: A Multi-Echelon Technique for Recoverable Item Control. *Operations Research* 16(1), 122–141.
- Muckstadt, J.A. (2005). *Analysis and Algorithms for Service Parts Supply Chains.* Springer.
- Gelman, A., Carlin, J.B., Stern, H.S., Dunson, D.B., Vehtari, A., Rubin, D.B. (2013). *Bayesian Data Analysis*, 3rd ed. CRC Press.
- Meeker, W.Q. & Escobar, L.A. (1998). *Statistical Methods for Reliability Data.* Wiley.
- Roberts, G.O. & Rosenthal, J.S. (2001). Optimal scaling for various Metropolis-Hastings algorithms. *Statistical Science* 16(4), 351–367.
