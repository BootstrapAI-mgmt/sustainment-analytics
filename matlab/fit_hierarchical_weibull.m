function fit = fit_hierarchical_weibull(fleet, opts)
%FIT_HIERARCHICAL_WEIBULL  Partial-pooling Weibull reliability model.
%
%   Model
%       t_ij       ~ Weibull(k, lambda_i)     right-censored at the horizon
%       log lambda_i ~ Normal(mu, sigma)      part-level partial pooling
%       log k      ~ Normal(log 1.5, 0.5)
%       mu         ~ Normal(mu0, tau0)
%       sigma      ~ HalfNormal(0.75)
%
%   The shared shape k encodes the engineering assumption that parts in a
%   commodity family wear out the same WAY even though they wear out at
%   different RATES. That assumption is testable and is checked in
%   tests/test_pooling_benefit.m.
%
%   Inference is Metropolis-within-Gibbs, hand-rolled so the file has no
%   toolbox dependency and runs unchanged in GNU Octave:
%
%     lambda   block random-walk Metropolis. Given (k, mu, sigma) the
%              part scales are conditionally independent, so all n_parts
%              proposals are drawn and accepted/rejected in one
%              vectorised pass -- no loop over parts.
%     mu       exact Gibbs draw. Normal likelihood on log lambda with a
%              Normal prior is conjugate, so there is no reason to spend
%              a Metropolis rejection on it.
%     k, sigma scalar random-walk Metropolis on the log scale.
%
%   Proposal scales adapt during burn-in toward 0.35 acceptance -- a
%   chosen compromise between the 1-D random-walk optimum (~0.44) and the
%   high-dimensional limit (0.234) of Roberts & Rosenthal (2001), which
%   contains neither 0.35 nor a rule for this blocked sampler; the
%   convergence gate checks the ACHIEVED rates -- and are then FROZEN, so
%   the retained draws come from a time-homogeneous chain and remain a
%   valid posterior sample.

    if nargin < 2, opts = struct(); end
    opts = set_defaults(opts);

    t   = fleet.t;
    c   = fleet.censored;
    pid = fleet.part_id;
    N   = fleet.n_parts;

    n_total = opts.n_burn + opts.n_keep;
    C       = opts.n_chains;

    keep_k     = zeros(opts.n_keep, C);
    keep_mu    = zeros(opts.n_keep, C);
    keep_sigma = zeros(opts.n_keep, C);
    keep_lam   = zeros(opts.n_keep, N, C);
    acc_report = zeros(C, 3);

    for chain = 1:C
        set_seed(opts.seed + 1000 * chain);

        % Overdispersed starts, so that R-hat is a real test of mixing
        % rather than four chains agreeing because they began together.
        logk     = log(1.0 + 0.5 * (chain - 1));
        mu       = opts.mu0 + 0.6 * (chain - 2);
        logsigma = log(0.3 * chain);
        loglam   = mu + 0.2 * randn(N, 1);

        step_lam = 0.4 * ones(N, 1);
        step_k   = 0.15;
        step_s   = 0.25;

        % Acceptance is counted over the RETAINED draws only. Counting it
        % across burn-in too averages in the adaptation phase, so the
        % number printed next to "target 0.35" would not be the rate that
        % the frozen, time-homogeneous chain actually achieved.
        acc_lam = zeros(N, 1); acc_k = 0; acc_s = 0;
        win_lam = zeros(N, 1); win_k = 0; win_s = 0;

        ll_part = weibull_part_loglik(t, c, pid, N, exp(logk), exp(loglam));
        if ~all(isfinite(ll_part))
            error('fit:nonfinite_loglik', ...
                  ['Initial log-likelihood is not finite for %d part(s). ' ...
                   'The chain cannot start, and continuing would freeze ' ...
                   'the sampler while still producing means and ' ...
                   'intervals.'], sum(~isfinite(ll_part)));
        end

        for it = 1:n_total
            k     = exp(logk);
            sigma = exp(logsigma);

            % ---- lambda: vectorised block Metropolis -------------------
            prop_loglam = loglam + step_lam .* randn(N, 1);
            ll_prop = weibull_part_loglik(t, c, pid, N, k, exp(prop_loglam));

            % Normal(mu, sigma) prior on log lambda; the Jacobian of the
            % log transform cancels because we propose symmetrically in
            % log space and score the prior in log space too.
            lp_cur  = -0.5 * ((loglam      - mu) / sigma) .^ 2;
            lp_prop = -0.5 * ((prop_loglam - mu) / sigma) .^ 2;

            accept = log(rand(N, 1)) < (ll_prop + lp_prop) - (ll_part + lp_cur);
            loglam(accept)  = prop_loglam(accept);
            ll_part(accept) = ll_prop(accept);
            if it > opts.n_burn, acc_lam = acc_lam + accept; end
            win_lam = win_lam + accept;

            % ---- k: scalar Metropolis on the full likelihood -----------
            prop_logk = logk + step_k * randn();
            ll_prop_v = weibull_part_loglik(t, c, pid, N, exp(prop_logk), exp(loglam));
            d_ll = sum(ll_prop_v) - sum(ll_part);
            d_lp = logk_prior(prop_logk, opts) - logk_prior(logk, opts);
            if log(rand()) < d_ll + d_lp
                logk    = prop_logk;
                ll_part = ll_prop_v;
                if it > opts.n_burn, acc_k = acc_k + 1; end
                win_k = win_k + 1;
            end

            % ---- mu: exact conjugate Gibbs draw ------------------------
            prec = N / sigma^2 + 1 / opts.tau0^2;
            mean_mu = (sum(loglam) / sigma^2 + opts.mu0 / opts.tau0^2) / prec;
            mu = mean_mu + randn() / sqrt(prec);

            % ---- sigma: scalar Metropolis on log scale -----------------
            prop_logsigma = logsigma + step_s * randn();
            d = hier_logpost_sigma(prop_logsigma, loglam, mu, opts) ...
              - hier_logpost_sigma(logsigma,      loglam, mu, opts);
            if log(rand()) < d
                logsigma = prop_logsigma;
                if it > opts.n_burn, acc_s = acc_s + 1; end
                win_s = win_s + 1;
            end

            % ---- adaptation, burn-in only ------------------------------
            if it <= opts.n_burn && mod(it, opts.adapt_every) == 0
                r = opts.adapt_every;
                step_lam = adapt(step_lam, win_lam / r);
                step_k   = adapt(step_k,   win_k   / r);
                step_s   = adapt(step_s,   win_s   / r);
                win_lam(:) = 0; win_k = 0; win_s = 0;
            end

            if it > opts.n_burn
                j = it - opts.n_burn;
                keep_k(j, chain)      = exp(logk);
                keep_mu(j, chain)     = mu;
                keep_sigma(j, chain)  = exp(logsigma);
                keep_lam(j, :, chain) = exp(loglam)';
            end
        end

        acc_report(chain, :) = [mean(acc_lam), acc_k, acc_s] / opts.n_keep;
    end

    fit = struct();
    fit.k      = keep_k;
    fit.mu     = keep_mu;
    fit.sigma  = keep_sigma;
    fit.lambda = keep_lam;
    fit.opts   = opts;
    fit.accept = struct('lambda', mean(acc_report(:,1)), ...
                        'k',      mean(acc_report(:,2)), ...
                        'sigma',  mean(acc_report(:,3)));

    fit.rhat = struct('k',     split_rhat(keep_k), ...
                      'mu',    split_rhat(keep_mu), ...
                      'sigma', split_rhat(keep_sigma));
    rl = zeros(N, 1);
    for i = 1:N
        rl(i) = split_rhat(squeeze(keep_lam(:, i, :)));
    end
    fit.rhat.lambda_max = max(rl);

    % Pooled draws across chains, for downstream propagation.
    fit.pooled = struct();
    fit.pooled.k      = keep_k(:);
    fit.pooled.mu     = keep_mu(:);
    fit.pooled.sigma  = keep_sigma(:);
    fit.pooled.lambda = reshape(permute(keep_lam, [1 3 2]), opts.n_keep * C, N);
end

% ---------------------------------------------------------------------

function s = adapt(s, rate)
    % Nudge toward 0.35 acceptance; bounded so one unlucky window cannot
    % send the proposal scale to zero or infinity.
    s = s .* exp(min(max(rate - 0.35, -0.4), 0.4));
    s = min(max(s, 1e-3), 10);
end

function lp = logk_prior(logk, opts)
    lp = -0.5 * ((logk - log(opts.k_prior_mean)) / opts.k_prior_sd)^2;
end

function lp = hier_logpost_sigma(logsigma, loglam, mu, opts)
    sigma = exp(logsigma);
    n = numel(loglam);
    % Normal likelihood on log lambda ...
    lp = -n * logsigma - 0.5 * sum(((loglam - mu) / sigma) .^ 2);
    % ... plus HalfNormal(sigma_prior_sd) prior, with the log-transform
    % Jacobian (+log sigma) so the density is correct on the sampled scale.
    lp = lp + logsigma - 0.5 * (sigma / opts.sigma_prior_sd)^2;
end

function opts = set_defaults(opts)
    d = struct('n_burn', 2000, 'n_keep', 2000, 'n_chains', 4, ...
               'seed', 7, 'adapt_every', 100, ...
               'mu0', log(2000), 'tau0', 1.0, ...
               'k_prior_mean', 1.5, 'k_prior_sd', 0.5, ...
               'sigma_prior_sd', 0.75);
    f = fieldnames(d);
    for i = 1:numel(f)
        if ~isfield(opts, f{i}), opts.(f{i}) = d.(f{i}); end
    end
end
