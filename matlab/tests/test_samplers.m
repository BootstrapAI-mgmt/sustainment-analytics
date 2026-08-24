function r = test_samplers()
%TEST_SAMPLERS  Unit checks on the hand-rolled numerical primitives.
%
%   Every toolbox function this repository avoids had to be rewritten,
%   and a rewritten primitive is a place for a silent error to live. Each
%   one is checked against a property known in closed form.

    r = struct('name', 'numerical primitives', 'pass', true, 'lines', {{}});

    % --- pctile against an exactly known case ------------------------
    x = (1:100)';
    med = pctile(x, 0.5);
    ok = abs(med - 50.5) < 1e-9;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  pctile median of 1:100 = %.4f (expect 50.5)  %s', med, tf(ok));

    ends = pctile(x, [0; 1]);
    ok = abs(ends(1) - 1) < 1e-9 && abs(ends(2) - 100) < 1e-9;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  pctile clamps at the sample extremes  %s', tf(ok));

    % --- Poisson sampler: mean and variance both equal lambda --------
    set_seed(99);
    lam = 4.5;
    d = poissrnd_basic(lam * ones(200000, 1));
    ok = abs(mean(d) - lam) < 0.03 && abs(var(d) - lam) < 0.06;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  Poisson(%.1f): mean %.3f, var %.3f (both expect %.1f)  %s', ...
        lam, mean(d), var(d), lam, tf(ok));

    % P(X = 0) = exp(-lambda) is the sharpest single check of the tail
    p0 = mean(d == 0);
    ok = abs(p0 - exp(-lam)) < 0.003;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  Poisson P(X=0) %.5f (expect %.5f)  %s', p0, exp(-lam), tf(ok));

    % --- Weibull generation: theoretical mean = lambda*Gamma(1+1/k) ---
    set_seed(7);
    cfg = struct('n_parts', 1, 'units_per_part', 200000, 'k_true', 2.2, ...
                 'mu_true', log(1500), 'sigma_true', 0, 'horizon', 1e9, 'seed', 7);
    f = generate_synthetic_fleet(cfg);
    expect = f.truth.lambda(1) * gamma(1 + 1 / cfg.k_true);
    ok = abs(mean(f.t) - expect) / expect < 0.01;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  Weibull mean %.1f (expect %.1f)  %s', mean(f.t), expect, tf(ok));

    % --- censoring must not be silently dropped ----------------------
    cfg2 = struct('n_parts', 1, 'units_per_part', 4000, 'k_true', 1.6, ...
                  'mu_true', log(2000), 'sigma_true', 0, 'horizon', 500, 'seed', 3);
    f2 = generate_synthetic_fleet(cfg2);
    frac_obs = mean(~f2.censored);
    expect_f = 1 - exp(-(500 / f2.truth.lambda(1)) ^ 1.6);
    ok = abs(frac_obs - expect_f) < 0.02;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  censoring: %.3f failed by horizon (expect %.3f)  %s', ...
        frac_obs, expect_f, tf(ok));

    % --- likelihood: censored units must move the estimate -----------
    % Fitting only the failures, and ignoring the survivors, must bias
    % the scale LOW. If it does not, censoring is not being handled.
    k = 1.6;
    lam_all = weibull_scale_mle(f2.t, f2.censored, f2.part_id, 1, k);
    fail_only_t = f2.t(~f2.censored);
    lam_naive = weibull_scale_mle(fail_only_t, false(size(fail_only_t)), ...
                                  ones(size(fail_only_t)), 1, k);
    ok = lam_naive < lam_all;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  dropping survivors biases scale low: %.0f vs %.0f  %s', ...
        lam_naive, lam_all, tf(ok));
end

function s = tf(b)
    if b, s = 'PASS'; else, s = 'FAIL'; end
end
