function x = poissrnd_basic(lam)
%POISSRND_BASIC  Poisson draws without the Statistics Toolbox.
%
%   Vectorised inverse-CDF sampling: exact, and every element advances in
%   the same loop so cost scales with max(lambda) rather than with the
%   number of draws.
%
%   Above lambda = 500 the CDF walk stops being worth its cost and a
%   Normal(lambda, lambda) approximation with a continuity correction is
%   used instead. That threshold is far above anything this pipeline
%   generates, but the branch is stated rather than assumed away.
%
%   THE INPUT IS VALIDATED, and that guard is not defensive boilerplate.
%   Without it a NaN rate returns 0 -- zero forecast demand, zero spares
%   recommended, and a report that looks entirely healthy. A negative rate
%   is worse: the running pmf alternates sign, the CDF oscillates, and the
%   walk returns arbitrary positive counts rather than failing. Both are
%   silent-wrong-number failures, which is the one outcome this project
%   exists to prevent, so they raise here.

    if any(~isfinite(lam(:))) || any(lam(:) < 0)
        error('poiss:bad_rate', ...
              ['Poisson rate must be finite and non-negative; found %d ' ...
               'invalid entries. A NaN rate would silently return zero ' ...
               'demand and a negative rate would return arbitrary counts.'], ...
              sum(~isfinite(lam(:)) | lam(:) < 0));
    end

    x = zeros(size(lam));
    big = lam > 500;

    if any(big(:))
        x(big) = max(0, round(lam(big) + sqrt(lam(big)) .* randn(sum(big(:)), 1)));
    end

    idx = ~big;
    if ~any(idx(:)), return; end

    l = lam(idx);
    u = rand(size(l));
    p = exp(-l);          % P(X = 0)
    cdf = p;
    xi = zeros(size(l));
    active = u > cdf;

    n = 0;
    while any(active) && n < 100000
        n = n + 1;
        p   = p .* l / n;
        cdf = cdf + p;
        xi(active) = n;
        active = u > cdf;
    end

    x(idx) = xi;
end
