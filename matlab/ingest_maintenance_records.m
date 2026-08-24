function [fleet, report] = ingest_maintenance_records(raw, policy)
%INGEST_MAINTENANCE_RECORDS  Hardened ingest: quarantine, never silently drop.
%
%   Three rules, in priority order, and the whole design follows from them:
%
%   1. NO RECORD DISAPPEARS WITHOUT A REASON. Every input row leaves this
%      function either ACCEPTED or QUARANTINED under a named reason code,
%      and those two counts are asserted to reconcile to the input count.
%      Accepted records may additionally carry a repair tag; a repair is a
%      property of an accepted record, not a third disposition. A pipeline that
%      drops rows on a failed comparison will keep running and will keep
%      producing numbers, which is worse than crashing.
%
%   2. A REPAIR IS A DECISION AND IS LOGGED AS ONE. Reclassifying a
%      no-fault-found removal as a censored observation is a modelling
%      judgement, not data cleaning. It is applied by policy, counted,
%      and reported, so a reviewer can find it and disagree with it.
%
%   3. TOO MUCH QUARANTINE MEANS STOP. Past a threshold the surviving
%      records are no longer a sample of the fleet -- they are a sample
%      of the records that happened to be well formed, which is a
%      different and unknown population. The function REFUSES rather
%      than returning a confident estimate from a biased remnant. This is
%      the load-bearing behaviour: the failure mode being defended
%      against is not a crash, it is a plausible wrong answer.
%
%   Quarantine reason codes:
%     Q_MISSING_INSTALL  no install time; time on wing is uncomputable
%     Q_NEGATIVE_TOW     removal at or before install
%     Q_FUTURE_STAMP     event after the reporting cutoff
%     Q_NEGATIVE_REPAIR  repair closed before the removal that caused it
%     Q_IMPLAUSIBLE_TOW  time on wing implausibly short for this fleet
%     Q_BLANK_SERIAL     unit not identifiable
%     Q_DUPLICATE        repeat of an already accepted (part, serial, install)
%     Q_BAD_CODE         removal code outside the known set
%     Q_ORPHAN_REPAIR    repair logged against a unit never removed
%
%   ONE OF THESE CHECKS IS NOT LIKE THE OTHERS. Every rule above except
%   Q_IMPLAUSIBLE_TOW is a schema or referential check: it can be decided
%   from the record alone, because the record is malformed. A duration
%   field recorded in days rather than hours is NOT malformed -- it is a
%   small positive number where a large positive number belonged, and no
%   amount of schema validation will ever see it.
%
%   Catching it needs a reference distribution, so the fence is applied
%   in a SECOND PASS, against the median time on wing of the records that
%   passed pass one. That is the general lesson worth carrying: schema
%   validation catches malformed data, and only domain knowledge catches
%   well-formed wrong data. The fence ratio is a policy input precisely
%   because it encodes an engineering judgement about the fleet rather
%   than a fact about the file.
%
%   Repair codes:
%     R_NONFAILURE_CENSOR  removal code 2/3/4 -> censored, not a failure
%     R_STILL_INSTALLED    no removal -> censored at the cutoff

    if nargin < 2, policy = struct(); end
    policy = defaults(policy);

    n = numel(raw.work_order);
    cutoff = raw.cutoff_hr;

    if n == 0
        error('ingest:empty', ...
              ['No records to ingest. An empty file must stop the run: ' ...
               'with zero records the quarantine rate is 0/0 = NaN, every ' ...
               'downstream comparison against a threshold is false, and ' ...
               'the pipeline would fit a model to nothing and report ' ...
               'converged.']);
    end

    reason = repmat({''}, n, 1);
    repair = repmat({''}, n, 1);

    tow      = NaN(n, 1);
    age      = NaN(n, 1);
    censored = false(n, 1);

    seen = containers.Map('KeyType', 'char', 'ValueType', 'logical');

    for i = 1:n
        ins = raw.install_hr(i);
        rem = raw.removal_hr(i);
        rep = raw.repair_hr(i);
        cod = raw.removal_code(i);

        if raw.serial(i) == 0
            reason{i} = 'Q_BLANK_SERIAL'; continue
        end
        if isnan(ins)
            reason{i} = 'Q_MISSING_INSTALL'; continue
        end
        if ins > cutoff
            reason{i} = 'Q_FUTURE_STAMP'; continue
        end

        key = sprintf('%d|%d|%.4f', raw.part_number(i), raw.serial(i), ins);
        if isKey(seen, key)
            reason{i} = 'Q_DUPLICATE'; continue
        end

        if ~isnan(rem)
            if rem > cutoff
                reason{i} = 'Q_FUTURE_STAMP'; continue
            end
            if rem <= ins
                reason{i} = 'Q_NEGATIVE_TOW'; continue
            end
            if ~isnan(rep) && rep < rem
                reason{i} = 'Q_NEGATIVE_REPAIR'; continue
            end
            if ~ismember(cod, [1 2 3 4])
                reason{i} = 'Q_BAD_CODE'; continue
            end

            tow(i) = rem - ins;
            age(i) = cutoff - rem;      % age of the replacement in this slot
            if cod == 1
                censored(i) = false;
            else
                censored(i) = true;                    % pulled, not failed
                repair{i}   = 'R_NONFAILURE_CENSOR';
            end
        else
            % A repair cannot exist without the removal that caused it.
            % Referential, not statistical: the two fields contradict
            % each other and one of them is wrong.
            if ~isnan(rep)
                reason{i} = 'Q_ORPHAN_REPAIR'; continue
            end
            tow(i)      = cutoff - ins;
            age(i)      = tow(i);       % original unit, still on wing
            censored(i) = true;
            repair{i}   = 'R_STILL_INSTALLED';
        end

        seen(key) = true;
    end

    % ---- pass two: the statistical fence -----------------------------
    prov = strcmp(reason, '');
    if any(prov)
        ref   = median(tow(prov));
        floor_hr = ref / policy.tow_fence_ratio;
        bad = prov & (tow < floor_hr | tow > policy.max_tow_hr);
        reason(bad) = {'Q_IMPLAUSIBLE_TOW'};
        repair(bad) = {''};
    else
        ref = NaN; floor_hr = NaN;
    end

    keep = strcmp(reason, '');

    report = struct();
    report.tow_reference_hr = ref;
    report.tow_floor_hr     = floor_hr;
    report.n_in           = n;
    report.n_accepted     = sum(keep);
    report.n_quarantined  = sum(~keep);
    report.quarantine_rate = report.n_quarantined / n;
    report.reasons        = tally(reason(~keep));
    report.repairs        = tally(repair(keep & ~strcmp(repair, '')));
    % Only the reclassification is a modelling DECISION. Censoring a unit
    % that is simply still installed is the definition of right-censoring,
    % not a policy repair, and counting it as one made the reported repair
    % rate read as "93% of records were modified", which is not what
    % happened.
    report.n_reclassified = sum(keep & strcmp(repair, 'R_NONFAILURE_CENSOR'));
    report.n_censored_open = sum(keep & strcmp(repair, 'R_STILL_INSTALLED'));
    report.reason_per_record = reason;
    report.refused        = false;
    report.threshold      = policy.max_quarantine_rate;

    % Reconciliation. If these ever disagree a record went missing, which
    % is the one outcome this function exists to make impossible.
    assert(report.n_accepted + report.n_quarantined == report.n_in, ...
           'ingest:reconcile', 'record count did not reconcile');

    % Written as a negated <= so that a NaN rate fails CLOSED. With
    % `rate > threshold`, a NaN sails through and the function returns a
    % confident fleet built from nothing.
    if ~(report.quarantine_rate <= policy.max_quarantine_rate)
        report.refused = true;
        fleet = [];
        if policy.error_on_refuse
            error('ingest:quarantine_rate', ...
                ['Quarantine rate %.1f%% exceeds the %.1f%% threshold. ' ...
                 'Refusing to emit estimates: the accepted records are no ' ...
                 'longer a sample of the fleet, only a sample of the ' ...
                 'well-formed records.'], ...
                100 * report.quarantine_rate, 100 * policy.max_quarantine_rate);
        end
        return
    end

    pid = raw.part_number(keep);
    N   = raw.n_parts;

    fleet = struct();
    fleet.t              = tow(keep);
    fleet.age_at_cutoff  = age(keep);
    fleet.censored       = censored(keep);
    fleet.part_id        = pid;
    fleet.n_parts        = N;
    fleet.units_per_part = accumarray(pid, 1, [N 1]);
    fleet.horizon        = cutoff;
    fleet.n_failures     = accumarray(pid, double(~censored(keep)), [N 1]);
end

% ---------------------------------------------------------------------

function t = tally(c)
    t = struct();
    u = unique(c);
    for i = 1:numel(u)
        if isempty(u{i}), continue; end
        t.(u{i}) = sum(strcmp(c, u{i}));
    end
end

function p = defaults(p)
    % tow_fence_ratio: how far below the fleet median a time on wing may
    % fall before it is treated as a recording error rather than an early
    % failure. 12 is deliberately loose -- for a wearing-out population
    % (k > 1) genuine failures that far below the median are rare, so the
    % false-positive cost is small, while a days-for-hours error lands
    % roughly 24x low and is caught with margin. Tighten it only with
    % evidence about the fleet's real infant-mortality behaviour.
    d = struct('tow_fence_ratio', 12, 'max_tow_hr', 1e5, ...
               'max_quarantine_rate', 0.15, 'error_on_refuse', true);
    f = fieldnames(d);
    for i = 1:numel(f)
        if ~isfield(p, f{i}), p.(f{i}) = d.(f{i}); end
    end
end
