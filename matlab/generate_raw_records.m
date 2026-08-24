function [raw, truth] = generate_raw_records(cfg)
%GENERATE_RAW_RECORDS  Maintenance records with deliberately injected faults.
%
%   Produces the kind of table a sustainment pipeline is actually handed:
%   one row per installed unit, with removal and repair timings, and with
%   the specific pathologies that real maintenance data carries. Each
%   injected fault is LABELLED in the returned truth struct, so the
%   ingest stage can be scored on detection rather than inspected by eye.
%
%   Injected fault classes:
%     missing_install   install date never recorded
%     negative_tow      removal timestamped before install (clock skew)
%     duplicate         the same work order entered twice
%     negative_repair   repair closed before the removal that caused it
%     unit_mismatch     hours field actually holding days (~24x error)
%     orphan_repair     repair logged against a unit never removed
%     future_stamp      event dated past the reporting cutoff
%     blank_serial      serial number missing
%
%   Not a fault, and the most expensive trap in the set: removal codes
%   other than 1 are NOT failures. A no-fault-found removal is a unit
%   that was pulled, tested serviceable, and returned to stock. Counting
%   those as failures is the single most common way a sustainment model
%   silently over-predicts demand -- the records are perfectly valid, so
%   no data quality check will ever flag them.

    cfg = defaults(cfg);
    set_seed(cfg.seed);

    fleet = generate_synthetic_fleet(cfg);
    n = numel(fleet.t);

    install_hr = zeros(n, 1);           % all units installed at t = 0
    removal_hr = NaN(n, 1);
    code       = NaN(n, 1);
    repair_hr  = NaN(n, 1);

    failed = ~fleet.censored;
    removal_hr(failed) = fleet.t(failed);
    code(failed) = 1;

    % A share of the still-running units were removed for reasons that are
    % not failures. These are real, valid records.
    running = find(fleet.censored);
    n_nff = round(cfg.nff_rate * numel(running));
    pick  = running(randperm(numel(running), n_nff));
    % Non-failure removals happen well into a unit's life, not at random
    % from zero: a unit is pulled for a scheduled interval or taken for
    % another aircraft after it has been flying, not on day one.
    removal_hr(pick) = (0.45 + 0.55 * rand(n_nff, 1)) .* fleet.t(pick);
    code(pick) = 2 + floor(3 * rand(n_nff, 1));      % 2 NFF, 3 scheduled, 4 collateral

    has_rem = ~isnan(removal_hr);
    repair_hr(has_rem) = removal_hr(has_rem) + 20 + 200 * rand(sum(has_rem), 1);

    raw = struct();
    raw.work_order   = (1:n)';
    raw.part_number  = fleet.part_id;
    raw.serial       = (1000 + (1:n))';
    raw.install_hr   = install_hr;
    raw.removal_hr   = removal_hr;
    raw.removal_code = code;
    raw.repair_hr    = repair_hr;
    raw.cutoff_hr    = fleet.horizon;
    raw.n_parts      = fleet.n_parts;

    labels = repmat({''}, n, 1);
    avail  = randperm(n);
    ptr    = 1;
    any_rec = true(n, 1);
    % Some faults are only physically possible on a record that HAS a
    % removal: you cannot time-travel a removal that never happened.
    % Injecting them onto still-installed units produces a record that is
    % perfectly valid, which then reads as an ingest miss when it is
    % really a generator error. Eligibility is stated per fault class.
    has_removal = ~isnan(raw.removal_hr);

    [raw, labels, ptr] = inject(raw, labels, avail, ptr, cfg.rate_missing_install, ...
        any_rec, 'missing_install', @(r, i) setfield_(r, 'install_hr', i, NaN));

    [raw, labels, ptr] = inject(raw, labels, avail, ptr, cfg.rate_negative_tow, ...
        has_removal, 'negative_tow', @(r, i) setfield_(r, 'install_hr', i, ...
            r.removal_hr(i) + 50));

    [raw, labels, ptr] = inject(raw, labels, avail, ptr, cfg.rate_negative_repair, ...
        has_removal, 'negative_repair', @(r, i) setfield_(r, 'repair_hr', i, ...
            r.removal_hr(i) - 30));

    [raw, labels, ptr] = inject(raw, labels, avail, ptr, cfg.rate_unit_mismatch, ...
        has_removal, 'unit_mismatch', @(r, i) setfield_(r, 'removal_hr', i, ...
            r.removal_hr(i) / 24));

    [raw, labels, ptr] = inject(raw, labels, avail, ptr, cfg.rate_orphan_repair, ...
        ~has_removal, 'orphan_repair', @(r, i) setfield_(r, 'repair_hr', i, 120));

    [raw, labels, ptr] = inject(raw, labels, avail, ptr, cfg.rate_future_stamp, ...
        any_rec, 'future_stamp', @(r, i) setfield_(r, 'removal_hr', i, r.cutoff_hr * 1.5));

    [raw, labels, ptr] = inject(raw, labels, avail, ptr, cfg.rate_blank_serial, ...
        any_rec, 'blank_serial', @(r, i) setfield_(r, 'serial', i, 0));

    % Duplicates are appended rather than overwritten, so the corrupted
    % table is longer than the clean one -- as it would be in practice.
    n_dup = round(cfg.rate_duplicate * n);
    dup_src = avail(ptr:min(ptr + n_dup - 1, numel(avail)))';
    f = {'work_order', 'part_number', 'serial', 'install_hr', 'removal_hr', ...
         'removal_code', 'repair_hr'};
    for j = 1:numel(f)
        raw.(f{j}) = [raw.(f{j}); raw.(f{j})(dup_src)];
    end
    labels = [labels; repmat({'duplicate'}, numel(dup_src), 1)];

    truth = struct();
    truth.labels      = labels;
    truth.fleet       = fleet;
    truth.n_clean     = sum(strcmp(labels, ''));
    truth.n_corrupt   = sum(~strcmp(labels, ''));
    truth.classes     = unique(labels(~strcmp(labels, '')));
end

% ---------------------------------------------------------------------

function [raw, labels, ptr] = inject(raw, labels, avail, ptr, rate, eligible, name, fn)
%INJECT  Corrupt the next `rate` share of eligible, not-yet-corrupted rows.
    n_base = numel(labels);
    k = round(rate * n_base);
    if k <= 0, return; end

    taken = 0;
    while taken < k && ptr <= numel(avail)
        i = avail(ptr);
        ptr = ptr + 1;
        if ~eligible(i) || ~isempty(labels{i}), continue; end
        raw = fn(raw, i);
        labels{i} = name;
        taken = taken + 1;
    end
end

function r = setfield_(r, f, i, v)
    r.(f)(i) = v;
end

function cfg = defaults(cfg)
    d = struct('n_parts', 15, 'units_per_part', 24, 'k_true', 1.7, ...
               'mu_true', log(2800), 'sigma_true', 0.45, 'horizon', 800, ...
               'seed', 1, 'nff_rate', 0.35, ...
               'rate_missing_install', 0.02, 'rate_negative_tow', 0.015, ...
               'rate_negative_repair', 0.015, 'rate_unit_mismatch', 0.01, ...
               'rate_future_stamp', 0.01, 'rate_blank_serial', 0.015, ...
               'rate_orphan_repair', 0.015, ...
               'rate_duplicate', 0.02);
    f = fieldnames(d);
    for i = 1:numel(f)
        if ~isfield(cfg, f{i}), cfg.(f{i}) = d.(f{i}); end
    end
end
