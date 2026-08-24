function rep = convergence_report(fit, threshold)
%CONVERGENCE_REPORT  The gate that decides whether draws may be published.
%
%   Returns a struct with the R-hat vector, the acceptance rates, and a
%   single PASS boolean, so the demo and the JSON result cannot disagree
%   about what "converged" meant.
%
%   TWO THINGS THIS CHECKS THAT AN R-HAT THRESHOLD ALONE DOES NOT.
%
%   NaN. MAX SILENTLY DROPS NaN: max([NaN 1.001]) is 1.001. SPLIT_RHAT
%   returns NaN for a chain with zero within-chain variance -- a
%   parameter that never moved at all -- so the single most broken
%   possible sampler state reports the healthiest possible number. The
%   gate therefore requires every R-hat to be FINITE before it compares
%   any of them to a threshold.
%
%   Acceptance. A frozen chain also shows an acceptance rate of exactly
%   zero, which is unmistakable and was, in the failure that motivated
%   this function, the loudest available signal that nothing was looking
%   at. A sampler accepting nothing, or accepting everything, has not
%   explored anything regardless of what R-hat says.

    if nargin < 2, threshold = 1.05; end

    v = [fit.rhat.k, fit.rhat.mu, fit.rhat.sigma, fit.rhat.lambda_max];
    a = [fit.accept.lambda, fit.accept.k, fit.accept.sigma];

    rep = struct();
    rep.rhat        = v;
    rep.rhat_names  = {'k', 'mu', 'sigma', 'lambda_max'};
    rep.accept      = a;
    rep.threshold   = threshold;
    rep.all_finite  = all(isfinite(v));
    rep.rhat_max    = max(v(isfinite(v)));
    if isempty(rep.rhat_max), rep.rhat_max = Inf; end
    rep.rhat_ok     = rep.all_finite && rep.rhat_max < threshold;
    rep.accept_ok   = all(isfinite(a)) && all(a > 0.02) && all(a < 0.95);
    rep.pass        = rep.rhat_ok && rep.accept_ok;

    if ~rep.all_finite
        rep.reason = 'one or more R-hat values are not finite (a chain never moved)';
    elseif ~rep.rhat_ok
        rep.reason = sprintf('max R-hat %.4f is at or above %.2f', rep.rhat_max, threshold);
    elseif ~rep.accept_ok
        rep.reason = sprintf('acceptance rate outside (0.02, 0.95): [%.3f %.3f %.3f]', a);
    else
        rep.reason = '';
    end
end
