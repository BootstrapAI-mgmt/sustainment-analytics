function r = test_guards()
%TEST_GUARDS  Regressions for every defect an adversarial review found.
%
%   None of these were caught by the original suite, and every one of them
%   produced a plausible answer rather than an error -- which is the whole
%   category this project claims to defend against. Each test is named for
%   the failure it prevents.

    r = struct('name', 'guards: regressions from an adversarial review', ...
               'pass', true, 'lines', {{}});

    % --- 0 * (-Inf) = NaN froze the sampler silently -------------------
    % A record at t = 0 made one part's log-likelihood NaN. Every
    % Metropolis comparison for that part then evaluated false, the shared
    % shape froze because its acceptance ratio was NaN too, and four flat
    % chains still produced means, intervals, and a buy list.
    ok = raises(@() weibull_part_loglik([100; 0], logical([0; 1]), [1; 1], 1, 1.8, 500), ...
                'weibull:bad_time');
    r = add(r, ok, '  zero time on wing is rejected, not turned into NaN');

    v = weibull_part_loglik([100; 300], logical([0; 1]), [1; 1], 1, 1.8, 500);
    ok = isfinite(v);
    r = add(r, ok, '  a valid censored record still evaluates finitely');

    % --- a NaN Poisson rate returned zero demand ----------------------
    ok = raises(@() poissrnd_basic([NaN; 3]), 'poiss:bad_rate');
    r = add(r, ok, '  NaN demand rate raises instead of forecasting zero');
    ok = raises(@() poissrnd_basic([-5; 2]), 'poiss:bad_rate');
    r = add(r, ok, '  negative demand rate raises instead of returning noise');

    % --- an empty file passed the quarantine gate ---------------------
    % 0/0 = NaN, and NaN > threshold is false, so the gate was inoperative
    % on the one input where it mattered most.
    empty_raw = struct('work_order', [], 'part_number', [], 'serial', [], ...
                       'install_hr', [], 'removal_hr', [], 'removal_code', [], ...
                       'repair_hr', [], 'cutoff_hr', 600, 'n_parts', 3);
    ok = raises(@() ingest_maintenance_records(empty_raw), 'ingest:empty');
    r = add(r, ok, '  an empty record set stops the run rather than fitting nothing');

    % --- max() silently drops NaN, hiding a dead chain ----------------
    frozen = struct('rhat', struct('k', NaN, 'mu', 1.01, 'sigma', 1.02, ...
                                   'lambda_max', 1.03), ...
                    'accept', struct('lambda', 0.36, 'k', 0.0, 'sigma', 0.35));
    c = convergence_report(frozen);
    ok = ~c.pass;
    r = add(r, ok, sprintf('  a frozen chain fails the gate (was reporting R-hat %.3f)', c.rhat_max));

    stuck = struct('rhat', struct('k', 1.01, 'mu', 1.01, 'sigma', 1.01, ...
                                  'lambda_max', 1.02), ...
                   'accept', struct('lambda', 0.0, 'k', 0.30, 'sigma', 0.30));
    ok = ~convergence_report(stuck).pass;
    r = add(r, ok, '  zero acceptance fails the gate even when R-hat looks healthy');

    % --- degenerate quantities dropped a part from the product --------
    ok = raises(@() fleet_availability([1; 1], 24, [0; 1]), 'avail:bad_qty');
    r = add(r, ok, '  a zero installed quantity raises rather than raising availability');

    % --- sort() puts NaN last, inflating n ----------------------------
    m = pctile([1:9, NaN]', 0.5);
    ok = abs(m - 5) < 1e-9;
    r = add(r, ok, sprintf('  pctile ignores NaN (median %.1f, expect 5)', m));

    % --- the ninth reason code shipped with zero coverage -------------
    % The fault harness injects eight corruption classes and none of them
    % is a bad removal code, so Q_BAD_CODE was reachable only by data
    % nothing generated. One crafted record (code 9 among nine valid
    % failures, below the quarantine threshold) pins the path.
    wo = (1:10)'; pn = ones(10, 1); sn = (101:110)';
    ins = zeros(10, 1); rem10 = 300 * ones(10, 1); cod = ones(10, 1);
    reph = NaN(10, 1); cod(10) = 9;
    raw10 = struct('work_order', wo, 'part_number', pn, 'serial', sn, ...
                   'install_hr', ins, 'removal_hr', rem10, 'removal_code', cod, ...
                   'repair_hr', reph, 'cutoff_hr', 600, 'n_parts', 3);
    [~, rep10] = ingest_maintenance_records(raw10);
    ok = isfield(rep10.reasons, 'Q_BAD_CODE') && rep10.reasons.Q_BAD_CODE == 1 ...
         && rep10.n_quarantined == 1;
    r = add(r, ok, '  an unknown removal code is quarantined as Q_BAD_CODE, not accepted');

    % --- the renewal table must be recomputed, not remembered ---------
    % An earlier METHOD.md quoted M(T) = 0.0257 at H(T) = 0.0266 -- an
    % impossible number, since every renewal function satisfies
    % M(T) >= F(T) = 1 - exp(-H(T)) = 0.02625 -- and nothing recomputed
    % the table, so it sat in the docs as "verified by Monte Carlo".
    % The short row is checked here against the two-term convolution
    % series (the third term is ~4e-7); the longer rows by seeded MC.
    kk = 1.8; T1 = 0.0266 ^ (1 / kk); H1 = T1 ^ kk;
    u = linspace(0, T1, 20001);
    Fw = @(t) 1 - exp(-max(t, 0) .^ kk);
    fw = @(t) kk * max(t, eps) .^ (kk - 1) .* exp(-t .^ kk);
    F2 = trapz(u, Fw(T1 - u) .* fw(u));
    M1 = Fw(T1) + F2;
    ratio1 = H1 / M1;
    ok = M1 >= Fw(T1) && abs(ratio1 - 1.008) < 0.002;
    r = add(r, ok, sprintf(['  renewal table, short row: H/M = %.4f by convolution series ' ...
                            '(docs say 1.008; the old 1.034 required an impossible M)'], ratio1));

    set_seed(9);
    ok = true; msg = '';
    for spec = [struct('T', 1, 'cols', 12, 'want', 1.277, 'tol', 0.015), ...
                struct('T', 4, 'cols', 22, 'want', 2.913, 'tol', 0.02)]
        reps = 300000;
        x = (-log(1 - rand(reps, spec.cols))) .^ (1 / kk);
        t = cumsum(x, 2);
        ok = ok && all(t(:, end) > spec.T);    % enough columns to count every renewal
        M = mean(sum(t <= spec.T, 2));
        ratio = (spec.T ^ kk) / M;
        ok = ok && ratio >= 1 && abs(ratio - spec.want) < spec.tol;
        msg = sprintf('%s  T/lam=%g: %.3f', msg, spec.T, ratio);
    end
    r = add(r, ok, ['  renewal approximation is conservative and matches the table:' msg]);

    % --- the age term's documented ratios, likewise recomputed --------
    hr = @(a) ((a + 400) .^ kk - a .^ kk) / 400 ^ kk;
    ok = abs(hr(600) - 3.13) < 0.01 && abs(hr(2400) - 8.05) < 0.01 ...
         && hr(2400) > hr(600) && hr(600) > 1;
    r = add(r, ok, sprintf(['  age-conditional hazard ratios match METHOD.md ' ...
                            '(600h: %.2f, 2400h: %.2f)'], hr(600), hr(2400)));

    % --- the closed-form EBO must match what it replaced --------------
    % expected_backorders now computes E[(D-s)^+] analytically instead of
    % counting samples. That is only an improvement if it agrees with the
    % thing it replaced, in the limit where the old estimator was good.
    set_seed(4);
    L = [2.5 7.0; 3.0 6.0];                 % 2 draws x 2 parts
    tab = expected_backorders(L, 6);
    big = repmat(L, 100000, 1);
    mc = poissrnd_basic(big);
    err = 0;
    for s = 0:6
        mc_s = mean(max(mc - s, 0), 1);
        err = max(err, max(abs(mc_s - tab(s + 1, :))));
    end
    ok = err < 0.02;
    r = add(r, ok, sprintf('  closed-form EBO matches 100k-sample Monte Carlo (max err %.4f)', err));

    % --- the greedy stopped at the first unaffordable item ------------
    % It left budget unspent while cheaper items with positive return
    % remained. The mask must spend materially more of the budget.
    dem = struct('Lambda', [3 6 2; 3.5 5.5 2.5]);
    cost = [320; 4500; 890];
    a = marginal_spares_allocation(dem, cost, 10, [1;1;1], 10000, 20);
    ok = a.unspent < min(cost) && strcmp(a.stop_reason, 'budget');
    r = add(r, ok, sprintf(['  greedy spends down to under the cheapest item ' ...
        '($%d unspent, cheapest $%d, stop: %s)'], round(a.unspent), min(cost), a.stop_reason));

    ok = ~isempty(a.stop_reason);
    r = add(r, ok, '  the buy list records WHY it stopped');
end

% ---------------------------------------------------------------------

function ok = raises(fn, id)
    ok = false;
    try
        fn();
    catch err
        ok = strcmp(err.identifier, id);
    end
end

function r = add(r, ok, line)
    r.pass = r.pass && ok;
    if ok, tag = 'PASS'; else, tag = 'FAIL'; end
    r.lines{end+1} = sprintf('%s  %s', line, tag);
end
