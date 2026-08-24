function r = test_interval_coverage(n_rep)
%TEST_INTERVAL_COVERAGE  Are the credible intervals actually calibrated?
%
%   This is the test that separates a model which reports uncertainty
%   from a model whose reported uncertainty means something.
%
%   Recovering the truth once (test_parameter_recovery) says very little:
%   a badly calibrated model with absurdly wide intervals passes that
%   test every time. Calibration is a FREQUENCY property, so it can only
%   be measured by repetition -- draw many independent synthetic fleets,
%   fit each, and count how often the 90% interval contains the value
%   used to generate the data.
%
%   Correct answer: 90%, within Monte Carlo error. Materially above 90%
%   means the model is overstating its own uncertainty and spares will be
%   over-bought; materially below means it is understating it, and a
%   confident number will be wrong more often than the decision-maker was
%   told to expect. The second failure mode is the dangerous one.

    if nargin < 1 || isempty(n_rep), n_rep = 60; end

    r = struct('name', 'credible interval coverage', 'pass', true, 'lines', {{}});

    hit_lam = 0; tot_lam = 0;
    hit_k = 0; hit_mu = 0; hit_sig = 0;
    per_rep = zeros(n_rep, 1);   % coverage within each replicate fleet

    for rep = 1:n_rep
        cfg = struct('n_parts', 15, 'units_per_part', 16, 'k_true', 1.7, ...
                     'mu_true', log(2800), 'sigma_true', 0.45, ...
                     'horizon', 800, 'seed', 5000 + rep);
        fleet = generate_synthetic_fleet(cfg);
        fit = fit_hierarchical_weibull(fleet, struct('n_burn', 1200, 'n_keep', 1200, ...
                                                     'n_chains', 2, 'seed', 900 + rep));

        rep_hits = 0;
        for i = 1:fleet.n_parts
            lo = pctile(fit.pooled.lambda(:, i), 0.05);
            hi = pctile(fit.pooled.lambda(:, i), 0.95);
            rep_hits = rep_hits + (fleet.truth.lambda(i) >= lo && fleet.truth.lambda(i) <= hi);
        end
        per_rep(rep) = rep_hits / fleet.n_parts;
        hit_lam = hit_lam + rep_hits;
        tot_lam = tot_lam + fleet.n_parts;

        hit_k   = hit_k   + inside(fit.pooled.k,     fleet.truth.k);
        hit_mu  = hit_mu  + inside(fit.pooled.mu,    fleet.truth.mu);
        hit_sig = hit_sig + inside(fit.pooled.sigma, fleet.truth.sigma);
    end

    % Monte Carlo band. Parts within one replicate share the same
    % hyperparameter draws and are therefore correlated, so treating the
    % 900 part-level checks as independent would give a band far too
    % tight and a test that fails at random. Rather than assume a
    % correlation, the standard error is estimated from the observed
    % between-replicate spread of coverage -- a clustered SE, with the
    % replicate as the cluster. That is both tighter than assuming total
    % dependence and defensible, because it is measured rather than
    % asserted.
    se_clustered  = std(per_rep) / sqrt(n_rep);
    se_naive      = sqrt(0.9 * 0.1 / tot_lam);
    se            = max(se_clustered, se_naive);
    band          = [0.9 - 3 * se, 0.9 + 3 * se];

    cov_lam = hit_lam / tot_lam;
    ok = cov_lam >= band(1) && cov_lam <= band(2);
    r.pass = r.pass && ok;

    r.lines{end+1} = sprintf('  %d replicate fleets, %d part-level intervals', n_rep, tot_lam);
    r.lines{end+1} = sprintf('  clustered SE %.4f (naive SE would be %.4f -- %.1fx optimistic)', ...
        se_clustered, se_naive, se_clustered / se_naive);
    r.lines{end+1} = sprintf('  nominal 90%% band, +/- 3 SE: [%.3f, %.3f]', band(1), band(2));
    r.lines{end+1} = sprintf('  lambda_i coverage  %.3f   %s', cov_lam, tf(ok));
    r.lines{end+1} = sprintf('  k coverage         %.3f', hit_k / n_rep);
    r.lines{end+1} = sprintf('  mu coverage        %.3f', hit_mu / n_rep);
    r.lines{end+1} = sprintf('  sigma coverage     %.3f   (see docs/VALIDATION.md)', hit_sig / n_rep);
end

function b = inside(draws, truth)
    b = truth >= pctile(draws, 0.05) && truth <= pctile(draws, 0.95);
end

function s = tf(b)
    if b, s = 'PASS'; else, s = 'FAIL'; end
end
