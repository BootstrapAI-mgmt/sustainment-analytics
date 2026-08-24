function [lam, ok] = weibull_scale_mle(t, censored, part_id, n_parts, k)
%WEIBULL_SCALE_MLE  Closed-form per-part scale MLE with shape held fixed.
%
%       lambda_hat = ( sum_j t_j^k / d )^(1/k),   d = observed failures
%
%   This is the "no pooling" baseline. It is UNDEFINED for any part with
%   zero observed failures (d = 0), which in a sparse fleet is most of
%   them -- the practical reason a hierarchical model is not a stylistic
%   preference here but the only estimator that returns a number at all.
%   ok(i) is false where the MLE does not exist.

    s = accumarray(part_id, t .^ k,     [n_parts 1]);
    d = accumarray(part_id, double(~censored), [n_parts 1]);

    ok  = d > 0;
    lam = NaN(n_parts, 1);
    lam(ok) = (s(ok) ./ d(ok)) .^ (1 / k);
end
