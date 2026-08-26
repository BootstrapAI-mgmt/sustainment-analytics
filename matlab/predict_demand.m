function dem = predict_demand(fleet, fit, horizon, n_draws)
%PREDICT_DEMAND  Posterior-predictive spare demand over a resupply lead time.
%
%   For posterior draw d and part i, with unit j currently at age a_ij:
%
%       h_ij^d     = H(a_ij + T) - H(a_ij),   H(t) = (t / lambda_i^d)^k^d
%       Lambda_i^d = m_i * mean_j( h_ij^d )                          (1)
%       D_i^d      ~ Poisson( Lambda_i^d )                           (2)
%
%   THE AGE TERM IS THE POINT, and it was missing. An earlier version
%   used m_i * (T/lambda)^k, which is the same expression with every unit
%   assumed brand new at the start of the lead time. For a wearing-out
%   population that is not a small simplification. On the demo fleet --
%   observed for 600 hours, then asked for a 400-hour lead time -- the
%   conditional hazard from age 600 is 3.1x the hazard from age 0, and at
%   steady state the gap is 5.6x. A model that forgets how old the fleet
%   already is under-buys spares, and does so most for the oldest and
%   most failure-prone units.
%
%   Ages come from the maintenance records: a unit still installed carries
%   its full time on wing, and a slot whose unit was removed carries the
%   age of the replacement fitted at that removal.
%
%   Two approximations remain, stated rather than left to be discovered:
%
%   - Expected renewals over the window are taken as the cumulative
%     hazard. Checked against a true renewal process at k = 1.8: the
%     cumulative hazard OVER-states renewals by 0.8% at T/lambda = 0.13,
%     28% at 1.0, and 191% at 4.0 (test_guards.m recomputes this table).
%     It is therefore CONSERVATIVE for a wearing-out population, and
%     small in the short-lead-time regime this is used in. Two earlier
%     versions of this comment were wrong in different ways -- one about
%     the direction, one quoting an under-sampled MC value (3%) that an
%     analytic lower bound rules out -- which is why the numbers are now
%     regression-tested rather than remembered.
%   - A unit that fails partway through the lead time and is replaced can
%     in principle fail again before the window closes. Negligible while
%     per-unit demand is well below 1, which it is here.
%
%   Drawing the Poisson ONCE PER POSTERIOR DRAW, rather than once at a
%   fitted point estimate, is what makes the forecast carry both sources
%   of uncertainty: how variable failures are (aleatory) and how little is
%   known about the failure rate (epistemic). Sizing spares off a plug-in
%   estimate silently discards the second, which is the larger of the two
%   for any part with few recorded failures -- exactly the parts that
%   drive availability risk.

    if nargin < 4, n_draws = 4000; end
    if ~isfield(fleet, 'age_at_cutoff')
        error('demand:no_age', ...
              ['Fleet has no age_at_cutoff. Demand cannot be forecast ' ...
               'without knowing how old the installed units are.']);
    end

    N   = fleet.n_parts;
    m   = fleet.units_per_part;
    tot = size(fit.pooled.lambda, 1);

    n_draws = min(n_draws, tot);
    sel = round(linspace(1, tot, n_draws))';   % thin evenly across chains

    k   = fit.pooled.k(sel);                   % [n_draws x 1]
    lam = fit.pooled.lambda(sel, :);           % [n_draws x N]

    Lambda = zeros(n_draws, N);
    for i = 1:N
        a = fleet.age_at_cutoff(fleet.part_id == i);
        a = a(:)';                             % [1 x n_i]
        if isempty(a)
            error('demand:no_units', ...
                  'Part %d has no accepted records; cannot age the fleet.', i);
        end
        li = lam(:, i);                        % [n_draws x 1]
        % (a + T)/lambda and a/lambda, broadcast over draws and units
        h = ((a + horizon) ./ li) .^ k - (a ./ li) .^ k;
        Lambda(:, i) = m(i) * mean(h, 2);
    end

    D = poissrnd_basic(Lambda);

    dem = struct();
    dem.draws        = D;
    dem.Lambda       = Lambda;
    dem.horizon      = horizon;
    dem.mean         = mean(D, 1)';
    dem.p95          = zeros(N, 1);
    for i = 1:N
        dem.p95(i) = pctile(D(:, i), 0.95);
    end

    % Var(D) = E[Var(D|L)] + Var(E[D|L]) = E[L] + Var(L). Both terms are
    % taken analytically so the two shares sum to exactly 1; mixing an
    % analytic numerator with a Monte Carlo estimate of Var(D) let the
    % shares drift a few percent either side of unity.
    dem.var_aleatory    = mean(Lambda, 1)';
    dem.var_epistemic   = var(Lambda, 0, 1)';
    dem.var_total       = dem.var_aleatory + dem.var_epistemic;
    dem.epistemic_share = dem.var_epistemic ./ max(dem.var_total, eps);
    dem.var_total_mc    = var(D, 0, 1)';       % reported for comparison only
end
