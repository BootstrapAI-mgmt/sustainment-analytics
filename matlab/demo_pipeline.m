%DEMO_PIPELINE  End-to-end run: censored fleet data -> auditable buy list.
%
%   Stage 1  sparse, right-censored failure records for a part family
%   Stage 2  hierarchical Bayesian reliability fit, with convergence checks
%   Stage 3  evidence attribution -- how much of each estimate is borrowed
%   Stage 4  posterior-predictive demand, aleatory and epistemic separated
%   Stage 5  marginal spares allocation against an availability target
%   Stage 6  structured result written to JSON for the narrative layer
%
%   Run from this directory:   octave-cli demo_pipeline.m
%                    MATLAB:   >> demo_pipeline

clear; close all;
here = fileparts(mfilename('fullpath'));
if isempty(here), here = pwd(); end
addpath(here);
outdir = fullfile(fileparts(here), 'results');
if ~exist(outdir, 'dir'), mkdir(outdir); end

fprintf('\n=== Stage 1: ingest ===\n');
Z   = 24;                                    % aircraft in the fleet
qty = [2 1 1 2 1 1 4 1 1 2 1 1]';            % units of each part per aircraft

% A 600-hour observation window against a ~3000-hour characteristic life
% is the regime that makes this problem hard and realistic: the large
% majority of installed units are still running, and several part numbers
% have not failed even once.
cfg = struct('n_parts', numel(qty), 'units_per_part', Z * qty, ...
             'k_true', 1.8, 'mu_true', log(3000), 'sigma_true', 0.50, ...
             'horizon', 600, 'seed', 42);

[raw, truth] = generate_raw_records(cfg);
fprintf('  %d raw maintenance records (%d carry injected faults)\n', ...
        numel(raw.work_order), truth.n_corrupt);

[fleet, ing] = ingest_maintenance_records(raw);
fprintf('  accepted %d, quarantined %d (%.1f%%, threshold %.0f%%)\n', ...
        ing.n_accepted, ing.n_quarantined, 100 * ing.quarantine_rate, ...
        100 * ing.threshold);
fprintf('  %d removals reclassified as censored (not failures); %d units still on wing\n', ...
        ing.n_reclassified, ing.n_censored_open);
rn = fieldnames(ing.reasons);
for i = 1:numel(rn)
    fprintf('    %-20s %d\n', rn{i}, ing.reasons.(rn{i}));
end

nv = ingest_naive(raw);
fprintf('  failures -- hardened %d | naive %d | truth %d\n', ...
        sum(~fleet.censored), sum(~nv.censored), sum(~truth.fleet.censored));
fprintf('  the naive path counts every removal as a failure: %+.0f%% error\n', ...
        100 * (sum(~nv.censored) / sum(~truth.fleet.censored) - 1));
% The naive-vs-hardened comparison goes into the structured result: the
% README used to quote the error percentage from this console line, which
% is committed nowhere -- an unprovenanced headline number in a repo whose
% thesis is that numbers trace to artifacts.
ing.hardened_failure_count = sum(~fleet.censored);
ing.naive_failure_count    = sum(~nv.censored);
ing.truth_failure_count    = sum(~truth.fleet.censored);
ing.hardened_error_pct     = round(100 * (ing.hardened_failure_count / ing.truth_failure_count - 1));
ing.naive_error_pct        = round(100 * (ing.naive_failure_count / ing.truth_failure_count - 1));

% The at-risk installed base comes from the ASSET REGISTER, not from
% however many maintenance records survived ingest. Conflating the two
% would let a data quality problem quietly shrink the fleet: quarantine a
% few records and the model believes there are fewer units at risk, so it
% forecasts less demand and buys fewer spares. The observation sample and
% the population are different quantities and are kept separate here.
fleet.units_per_part = Z * qty;

fprintf('  %d part numbers, %d installed units, %d flight-hour window\n', ...
        fleet.n_parts, sum(fleet.units_per_part), fleet.horizon);
fprintf('  %d part numbers have 0 or 1 failures -- no standalone estimate exists\n', ...
        sum(fleet.n_failures <= 1));

fprintf('\n=== Stage 2: hierarchical fit ===\n');
tic;
fit = fit_hierarchical_weibull(fleet, struct('n_burn', 4000, 'n_keep', 4000, ...
                                             'n_chains', 4, 'seed', 11));
fprintf('  %.1f s, 4 chains x 4000 draws\n', toc);
fprintf('  acceptance (retained draws)  lambda %.2f | k %.2f | sigma %.2f  (target 0.35)\n', ...
        fit.accept.lambda, fit.accept.k, fit.accept.sigma);
fprintf('  split R-hat k %.4f | mu %.4f | sigma %.4f | max lambda %.4f\n', ...
        fit.rhat.k, fit.rhat.mu, fit.rhat.sigma, fit.rhat.lambda_max);

conv = convergence_report(fit);
if ~conv.pass
    error('demo:convergence', ...
          'Refusing to report downstream numbers: %s', conv.reason);
end
fprintf('  GATE PASSED: every R-hat finite and < %.2f, acceptance in range\n', conv.threshold);

k_hat = mean(fit.pooled.k);
fprintf('  shape k = %.2f [%.2f, %.2f]  (>1 confirms wear-out, not random failure)\n', ...
        k_hat, pctile(fit.pooled.k, 0.05), pctile(fit.pooled.k, 0.95));

fprintf('\n=== Stage 3: where each estimate comes from ===\n');
attr = attribute_evidence(fleet, fit);
fprintf('  %-5s %6s %6s %10s %10s %9s %8s\n', 'part', 'units', 'fails', ...
        'own MLE', 'posterior', '90% width', 'borrowed');
for i = 1:fleet.n_parts
    if attr.has_own(i), own = sprintf('%10.0f', attr.lambda_own(i));
    else,               own = sprintf('%10s', 'none'); end
    fprintf('  %-5d %6d %6d %s %10.0f %8.1fx %7.0f%%\n', i, attr.n_units(i), ...
            attr.n_failures(i), own, attr.lambda_post(i), ...
            attr.interval_width_ratio(i), 100 * attr.family_weight(i));
end

% Spares are sized against demand during the RESUPPLY LEAD TIME, not
% against some arbitrary planning window: the stock on the shelf only has
% to cover the gap until replenishment arrives.
lead_time_hr = 400;
fprintf('\n=== Stage 4: demand during a %d flight-hour resupply lead time ===\n', lead_time_hr);
dem = predict_demand(fleet, fit, lead_time_hr, 4000);
fprintf('  fleet-wide expected demand %.1f units; 95th percentile %.0f\n', ...
        sum(dem.mean), sum(dem.p95));
fprintf('  epistemic share of demand variance: min %.0f%%, median %.0f%%, max %.0f%%\n', ...
        100 * min(dem.epistemic_share), 100 * median(dem.epistemic_share), ...
        100 * max(dem.epistemic_share));
fprintf('  (a point-estimate sizing would discard exactly that share)\n');

fprintf('\n=== Stage 5: spares allocation ===\n');
cost   = [1200 3400 890 15000 2100 640 320 8800 4500 1750 990 26000]';
budget = 200000;
alloc  = marginal_spares_allocation(dem, cost, Z, qty, budget, 60);

% The frontier is free once the greedy order exists, so the question a
% programme office actually asks -- what would the next availability point
% cost -- is answered here rather than left as an exercise.
front  = marginal_spares_allocation(dem, cost, Z, qty, 1e9, 90);
targets = [0.80 0.90];
tgt_cost = zeros(size(targets));
for ti = 1:numel(targets)
    idx = find(front.frontier_avail >= targets(ti), 1);
    if isempty(idx), tgt_cost(ti) = NaN; else, tgt_cost(ti) = front.frontier_cost(idx); end
end

fprintf('  budget $%s, spent $%s on %d units (unspent $%s, stopped: %s)\n', ...
        commas(budget), commas(alloc.total_cost), sum(alloc.stock), ...
        commas(alloc.unspent), alloc.stop_reason);
fprintf('  availability %.3f -> %.3f  (%d part numbers at the stock cap)\n', ...
        alloc.availability_zero, alloc.availability, alloc.at_stock_cap);
for ti = 1:numel(targets)
    if isnan(tgt_cost(ti))
        fprintf('  %.0f%% availability is unreachable at any stock level\n', 100 * targets(ti));
    else
        fprintf('  %.0f%% availability would cost $%s on the same frontier\n', ...
                100 * targets(ti), commas(tgt_cost(ti)));
    end
end
fprintf('  first 8 buys, in the order the marginal rule chose them:\n');
for s = 1:min(8, numel(alloc.trace))
    tr = alloc.trace(s);
    fprintf('    %d. part %-2d  $%-7s  removes %.3f backorders  (%.5f per $)  A=%.3f\n', ...
            tr.step, tr.part, commas(tr.unit_cost), tr.dEBO, ...
            tr.dEBO_per_dollar, tr.availability);
end

fprintf('\n=== Stage 6: structured result ===\n');
res = build_result(fleet, fit, attr, dem, alloc, Z, qty, cost, budget, ing, conv, targets, tgt_cost);
jf  = fullfile(outdir, 'analysis_result.json');
fid = fopen(jf, 'w');
fprintf(fid, '%s', jsonencode(res));
fclose(fid);
fprintf('  wrote %s\n', jf);
fprintf('  every number the narrative layer may state is a field in that file.\n\n');
