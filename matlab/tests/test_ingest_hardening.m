function r = test_ingest_hardening()
%TEST_INGEST_HARDENING  Fault injection against the ingest contract.
%
%   The generator knows which records it corrupted and how, so detection
%   can be scored instead of eyeballed. Four properties are asserted:
%
%     detection      every injected fault class is caught. Scored by
%                    "caught under SOME reason code", not by matching the
%                    injected name -- corrupting one field often makes a
%                    record violate a different rule first, and catching
%                    it for the wrong stated reason is still catching it.
%     specificity    clean records are not quarantined at a material
%                    rate. A validator that rejects everything trivially
%                    detects everything, and is useless.
%     reconciliation accepted + quarantined = input, always.
%     refusal        past the quarantine threshold the ingest declines to
%                    return a fleet at all, rather than returning a
%                    confident estimate from a biased remnant.

    r = struct('name', 'ingest hardening under fault injection', ...
               'pass', true, 'lines', {{}});

    [raw, truth] = generate_raw_records(struct('seed', 5));
    [fleet, rep] = ingest_maintenance_records(raw);

    r.lines{end+1} = sprintf('  %d raw records: %d clean, %d corrupted', ...
        numel(raw.work_order), truth.n_clean, truth.n_corrupt);
    r.lines{end+1} = sprintf(['  accepted %d, quarantined %d (%.1f%%); ' ...
        '%d removals reclassified, %d still on wing'], ...
        rep.n_accepted, rep.n_quarantined, 100 * rep.quarantine_rate, ...
        rep.n_reclassified, rep.n_censored_open);

    % ---- reconciliation --------------------------------------------
    ok = (rep.n_accepted + rep.n_quarantined) == rep.n_in;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  reconciles: %d + %d = %d  %s', ...
        rep.n_accepted, rep.n_quarantined, rep.n_in, tf(ok));

    % ---- detection, per injected class ------------------------------
    caught = ~strcmp(rep.reason_per_record, '');
    r.lines{end+1} = '  detection by injected fault class:';
    all_detected = true;
    for i = 1:numel(truth.classes)
        cls = truth.classes{i};
        idx = strcmp(truth.labels, cls);
        rate = mean(caught(idx));
        good = rate >= 0.95;
        all_detected = all_detected && good;
        r.lines{end+1} = sprintf('    %-18s %3d injected, %3.0f%% caught  %s', ...
            cls, sum(idx), 100 * rate, tf(good));
    end
    r.pass = r.pass && all_detected;

    % ---- specificity -------------------------------------------------
    clean_idx = strcmp(truth.labels, '');
    fp = mean(caught(clean_idx));
    ok = fp <= 0.05;
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  false positives on clean records: %.1f%% (cap 5%%)  %s', ...
        100 * fp, tf(ok));
    r.lines{end+1} = '    residual FPs are early non-failure removals caught by the';
    r.lines{end+1} = '    time-on-wing fence. Measured, not engineered away.';

    % ---- determinism -------------------------------------------------
    [~, rep2] = ingest_maintenance_records(raw);
    ok = isequal(rep.reason_per_record, rep2.reason_per_record);
    r.pass = r.pass && ok;
    r.lines{end+1} = sprintf('  identical input gives an identical quarantine set  %s', tf(ok));

    % ---- refusal gate ------------------------------------------------
    bad_cfg = struct('seed', 9, 'rate_missing_install', 0.12, ...
                     'rate_blank_serial', 0.10, 'rate_negative_tow', 0.08);
    raw_bad = generate_raw_records(bad_cfg);
    threw = false;
    try
        ingest_maintenance_records(raw_bad);
    catch err
        threw = strcmp(err.identifier, 'ingest:quarantine_rate');
    end
    r.pass = r.pass && threw;
    r.lines{end+1} = sprintf('  refuses to emit a fleet above the quarantine threshold  %s', tf(threw));

    % ---- what the hardening is worth, in failures and dollars --------
    nv = ingest_naive(raw);
    true_fail = sum(~truth.fleet.censored);
    h_fail = sum(~fleet.censored);
    n_fail = sum(~nv.censored);

    r.lines{end+1} = sprintf('  failure count -- truth %d | hardened %d (%+.0f%%) | naive %d (%+.0f%%)', ...
        true_fail, h_fail, 100 * (h_fail / true_fail - 1), ...
        n_fail, 100 * (n_fail / true_fail - 1));
    r.lines{end+1} = '    the naive path treats every removal as a failure. Those';
    r.lines{end+1} = '    records are valid, so no schema check would ever flag them,';
    r.lines{end+1} = '    and the resulting demand forecast is wrong by that margin.';

    closer = abs(h_fail - true_fail) < abs(n_fail - true_fail);
    r.pass = r.pass && closer;
    r.lines{end+1} = sprintf('  hardened ingest is closer to truth than naive  %s', tf(closer));
end

function s = tf(b)
    if b, s = 'PASS'; else, s = 'FAIL'; end
end
