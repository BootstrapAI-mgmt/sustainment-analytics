function r = test_pooling_benefit()
%TEST_POOLING_BENEFIT  Paired estimator comparison against known truth.
%
%   Three estimators, scored as RMSE in log lambda over all parts:
%
%     partial   the hierarchical fit
%     none      per-part MLE, falling back to the family estimate for the
%               parts it cannot estimate at all (the most generous
%               fallback available, and what a practitioner would do)
%     complete  a single scale for the whole family
%
%   The comparison is PAIRED: every estimator sees the same simulated
%   fleets, per-replicate RMSE is recorded, and the estimators are
%   compared through the paired differences. That gives each claim a
%   standard error, which an aggregate RMSE cannot.
%
%   WHY THIS TEST WAS REWRITTEN, TWICE, AND WHAT IT COST TO GET RIGHT:
%
%   v1 scored only the parts where the no-pooling MLE existed. That
%   conditions on the parts with the most data and silently drops the
%   ~40% of part numbers where the baseline has nothing to say -- the
%   exact cases pooling exists to handle. Biased in the baseline's favour.
%
%   v2 fixed the selection bias but used 5-6 replicates. At that count
%   the result FLIPPED between seed sets: one run showed partial pooling
%   losing badly in the sparsest regime, and a plausible mechanism was
%   available to explain it (weakly identified sigma pulled up by a
%   diffuse prior, hence too little shrinkage). The mechanism was real,
%   the explanation was tidy, and the finding did not replicate. RMSE
%   here is dominated by rare large errors, so a handful of replicates
%   cannot rank estimators that sit this close together.
%
%   v3, below, uses 25 paired replicates and reports t-statistics. The
%   conclusion it supports is narrower than v2's confident story, and the
%   narrower version is the one that is true:
%
%     - partial pooling beats COMPLETE pooling decisively, everywhere.
%       Part numbers genuinely differ and complete pooling denies it.
%     - against a well-implemented NO-POOLING baseline, partial pooling
%       is better in direction at every horizon but the margin is NOT
%       distinguishable from zero when data is sparsest. It separates as
%       failures accumulate.
%
%   The general lesson is worth more than the specific result: a
%   mechanism that explains an observation is not evidence that the
%   observation is real.

    r = struct('name', 'partial pooling: paired estimator comparison', ...
               'pass', true, 'lines', {{}});

    horizons = [400 800];
    R = 25;

    r.lines{end+1} = sprintf('  %d paired replicates per horizon', R);
    r.lines{end+1} = sprintf('    %-8s %8s %8s %9s %9s %9s', ...
        'horizon', 'fails', 'no-MLE', 'partial', 'none', 'complete');

    beats_complete = true;
    dir_ok = true;
    t_vs_none = zeros(numel(horizons), 1);
    t_vs_comp = zeros(numel(horizons), 1);

    for h = 1:numel(horizons)
        rp = zeros(R, 1); rn = zeros(R, 1); rc = zeros(R, 1);
        n_fail = 0; n_nomle = 0;

        for rep = 1:R
            cfg = struct('n_parts', 15, 'units_per_part', 16, 'k_true', 1.7, ...
                         'mu_true', log(2800), 'sigma_true', 0.45, ...
                         'horizon', horizons(h), 'seed', 20000 + rep);
            fleet = generate_synthetic_fleet(cfg);
            fit = fit_hierarchical_weibull(fleet, struct('n_burn', 1200, ...
                'n_keep', 1200, 'n_chains', 2, 'seed', 31 + rep));

            N = fleet.n_parts; k = mean(fit.pooled.k);
            truth = log(fleet.truth.lambda);

            lam_p  = exp(mean(log(fit.pooled.lambda), 1))';
            lam_c1 = weibull_scale_mle(fleet.t, fleet.censored, ...
                                       ones(size(fleet.t)), 1, k);
            [lam_n, ok] = weibull_scale_mle(fleet.t, fleet.censored, ...
                                            fleet.part_id, N, k);
            lam_n(~ok) = lam_c1;

            rp(rep) = sqrt(mean((log(lam_p) - truth) .^ 2));
            rn(rep) = sqrt(mean((log(lam_n) - truth) .^ 2));
            rc(rep) = sqrt(mean((log(repmat(lam_c1, N, 1)) - truth) .^ 2));

            n_fail  = n_fail + sum(~fleet.censored) / R;
            n_nomle = n_nomle + sum(~ok);
        end

        dn = rn - rp; dc = rc - rp;          % positive = partial is better
        t_vs_none(h) = mean(dn) / (std(dn) / sqrt(R));
        t_vs_comp(h) = mean(dc) / (std(dc) / sqrt(R));

        dir_ok = dir_ok && mean(rp) <= mean(rn) && mean(rp) <= mean(rc);
        beats_complete = beats_complete && t_vs_comp(h) > 2;

        r.lines{end+1} = sprintf('    %-8d %8.0f %4d/%-3d %9.4f %9.4f %9.4f', ...
            horizons(h), n_fail, n_nomle, 15 * R, mean(rp), mean(rn), mean(rc));
    end

    for h = 1:numel(horizons)
        r.lines{end+1} = sprintf('    h=%-5d paired t vs none %+5.2f | vs complete %+5.2f', ...
            horizons(h), t_vs_none(h), t_vs_comp(h));
    end

    r.pass = dir_ok && beats_complete;
    r.lines{end+1} = sprintf('  partial pooling best in point estimate everywhere: %s', tf(dir_ok));
    r.lines{end+1} = sprintf('  advantage over complete pooling is significant (t>2): %s', tf(beats_complete));
    r.lines{end+1} = '  advantage over no-pooling is directional but NOT asserted as';
    r.lines{end+1} = '  significant in the sparse regime -- see the note in this file.';
end

function s = tf(b)
    if b, s = 'PASS'; else, s = 'FAIL'; end
end
