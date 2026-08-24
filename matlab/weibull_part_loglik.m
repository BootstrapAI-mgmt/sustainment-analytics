function ll = weibull_part_loglik(t, censored, part_id, n_parts, k, lambda)
%WEIBULL_PART_LOGLIK  Per-part right-censored Weibull log-likelihood.
%
%   Returns an [n_parts x 1] vector. Splitting the likelihood by part is
%   what makes the block Metropolis update valid: given (k, mu, sigma) the
%   part-level scales are conditionally independent, so all n_parts
%   proposals can be generated and accepted/rejected in one vectorised
%   pass instead of a loop.
%
%   Failure at t contributes log f(t); a unit still running at t
%   contributes log S(t) = -(t/lambda)^k. Dropping the censored units
%   entirely would bias lambda low -- they are the majority of the fleet.
%
%   THE log(t) IS MASKED, NOT MULTIPLIED BY ZERO. An earlier version
%   computed log(t) for every record and zeroed the censored ones with
%   (~censored) .* (...). For a record at t = 0 that is 0 * (-Inf) = NaN,
%   which does not raise, does not warn, and propagates: once one part's
%   log-likelihood is NaN, every Metropolis comparison for that part is
%   false, the shared shape k freezes because its acceptance ratio is
%   also NaN, and the sampler returns four flat chains that still produce
%   means, intervals, and a buy list. It was reachable through the shipped
%   ingest whenever a unit was installed exactly at the reporting cutoff.
%   A guard costs one branch; finding it costs an afternoon.

    if any(~isfinite(t)) || any(t <= 0)
        error('weibull:bad_time', ...
              ['Time on wing must be finite and strictly positive; found ' ...
               '%d non-positive or non-finite values. A zero-duration ' ...
               'record is not a short life, it is a data error, and it ' ...
               'must be quarantined upstream rather than modelled.'], ...
              sum(~isfinite(t) | t <= 0));
    end
    if ~isfinite(k) || k <= 0 || any(~isfinite(lambda)) || any(lambda <= 0)
        error('weibull:bad_param', 'Shape and scale must be finite and positive.');
    end

    lam_obs = lambda(part_id);
    z       = (t ./ lam_obs) .^ k;

    failed = ~censored;
    contrib = zeros(size(t));
    contrib(failed) = log(k) - k * log(lam_obs(failed)) + (k - 1) * log(t(failed));

    ll = accumarray(part_id, -z + contrib, [n_parts 1]);
end
