function fleet = ingest_naive(raw)
%INGEST_NAIVE  The strawman: the ingest most pipelines actually ship.
%
%   Drops anything that will not arithmetic cleanly, keeps everything
%   else, and counts EVERY removal as a failure. It never errors, never
%   warns, and produces a complete-looking answer on any input.
%
%   Kept in the repository on purpose. The cost of the hardened path is
%   only arguable against a measured alternative, and
%   tests/test_ingest_hardening.m turns that comparison into dollars.

    ok = ~isnan(raw.install_hr);
    t  = raw.removal_hr - raw.install_hr;
    still = isnan(raw.removal_hr);
    t(still) = raw.cutoff_hr - raw.install_hr(still);

    ok = ok & ~isnan(t) & t > 0;

    pid = raw.part_number(ok);
    N   = raw.n_parts;

    fleet = struct();
    fleet.t              = t(ok);
    fleet.age_at_cutoff  = t(ok);   % assumes nothing was ever replaced
    fleet.censored       = still(ok);      % every recorded removal = a failure
    fleet.part_id        = pid;
    fleet.n_parts        = N;
    fleet.units_per_part = accumarray(pid, 1, [N 1]);
    fleet.horizon        = raw.cutoff_hr;
    fleet.n_failures     = accumarray(pid, double(~still(ok)), [N 1]);
end
