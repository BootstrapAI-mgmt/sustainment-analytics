function r = test_parameter_recovery()
%TEST_PARAMETER_RECOVERY  Does the sampler find parameters it was given?
%
%   The most basic model-based check there is: simulate from the model
%   with KNOWN parameters, fit, and ask whether the truth comes back
%   inside the interval the fit claims. A model that cannot recover its
%   own generating parameters has no business being pointed at real data.

    r = struct('name', 'parameter recovery', 'pass', true, 'lines', {{}});

    cfg = struct('n_parts', 30, 'units_per_part', 20, 'k_true', 1.8, ...
                 'mu_true', log(3000), 'sigma_true', 0.45, ...
                 'horizon', 900, 'seed', 202);
    fleet = generate_synthetic_fleet(cfg);
    fit = fit_hierarchical_weibull(fleet, struct('n_burn', 2500, 'n_keep', 2500, ...
                                                 'n_chains', 3, 'seed', 5));

    checks = { 'k',     fleet.truth.k,     fit.pooled.k
               'mu',    fleet.truth.mu,    fit.pooled.mu
               'sigma', fleet.truth.sigma, fit.pooled.sigma };

    for i = 1:size(checks, 1)
        nm = checks{i,1}; truth = checks{i,2}; draws = checks{i,3};
        lo = pctile(draws, 0.05); hi = pctile(draws, 0.95);
        inside = truth >= lo && truth <= hi;
        r.pass = r.pass && inside;
        r.lines{end+1} = sprintf('  %-6s truth %7.3f  post %7.3f  90%% CI [%7.3f %7.3f]  %s', ...
            nm, truth, mean(draws), lo, hi, tf(inside));
    end

    % Per-part scales: allow the nominal 10% miss rate plus Monte Carlo slack.
    N = fleet.n_parts;
    inside = false(N, 1);
    for i = 1:N
        lo = pctile(fit.pooled.lambda(:, i), 0.05);
        hi = pctile(fit.pooled.lambda(:, i), 0.95);
        inside(i) = fleet.truth.lambda(i) >= lo && fleet.truth.lambda(i) <= hi;
    end
    frac = mean(inside);
    ok = frac >= 0.75;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  lambda_i: %d of %d truths inside their 90%% CI (%.0f%%)  %s', ...
        sum(inside), N, 100 * frac, tf(ok));
end

function s = tf(b)
    if b, s = 'PASS'; else, s = 'FAIL'; end
end
