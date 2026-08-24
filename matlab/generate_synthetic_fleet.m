function fleet = generate_synthetic_fleet(cfg)
%GENERATE_SYNTHETIC_FLEET  Simulate a fleet of parts with known ground truth.
%
%   Ground-truth model (the same model the estimator assumes, so that
%   parameter recovery is a fair test of the sampler rather than of the
%   model form):
%
%       t_ij ~ Weibull(shape = k, scale = lambda_i)      unit j of part i
%       log lambda_i ~ Normal(mu, sigma)                 partial pooling
%
%   Units still operating at cfg.horizon are RIGHT CENSORED, which is the
%   normal condition for a fielded fleet: most installed parts have not
%   failed yet, and discarding them biases every estimate low.
%
%   cfg fields:
%     n_parts        number of distinct part numbers
%     units_per_part scalar or [n_parts x 1] installed quantity
%     k_true         shared Weibull shape (>1 = wear-out)
%     mu_true        mean of log-scale across parts
%     sigma_true     spread of log-scale across parts
%     horizon        observation window (flight hours)
%     seed           RNG seed
%
%   Returns struct with observation vectors t, censored, part_id and a
%   .truth substruct carrying the generating parameters.

    cfg = set_defaults(cfg);
    set_seed(cfg.seed);

    N = cfg.n_parts;
    m = cfg.units_per_part;
    if isscalar(m), m = repmat(m, N, 1); end
    m = m(:);

    lambda_true = exp(cfg.mu_true + cfg.sigma_true * randn(N, 1));

    total = sum(m);
    t        = zeros(total, 1);
    censored = false(total, 1);
    part_id  = zeros(total, 1);

    pos = 1;
    for i = 1:N
        n  = m(i);
        idx = pos:(pos + n - 1);

        % Inverse-CDF sampling of a Weibull: t = lambda * (-log U)^(1/k)
        u  = rand(n, 1);
        ti = lambda_true(i) * (-log(u)) .^ (1 / cfg.k_true);

        c  = ti > cfg.horizon;
        ti(c) = cfg.horizon;

        t(idx)        = ti;
        censored(idx) = c;
        part_id(idx)  = i;
        pos = pos + n;
    end

    fleet = struct();
    fleet.t             = t;
    fleet.censored      = censored;
    fleet.part_id       = part_id;
    fleet.n_parts       = N;
    fleet.units_per_part = m;
    fleet.horizon       = cfg.horizon;
    fleet.n_failures    = accumarray(part_id, double(~censored), [N 1]);

    % Age of whatever is installed in each slot at the cutoff. A surviving
    % unit carries its full time on wing; a slot whose unit failed carries
    % the age of the replacement fitted at that moment. Demand forecasting
    % needs this -- a fleet is not new at the start of a lead time.
    fleet.age_at_cutoff = cfg.horizon - t;
    fleet.age_at_cutoff(censored) = t(censored);

    fleet.truth = struct('k', cfg.k_true, 'mu', cfg.mu_true, ...
                         'sigma', cfg.sigma_true, 'lambda', lambda_true);
end

function cfg = set_defaults(cfg)
    d = struct('n_parts', 12, 'units_per_part', 8, 'k_true', 1.8, ...
               'mu_true', log(3000), 'sigma_true', 0.45, ...
               'horizon', 2500, 'seed', 1);
    f = fieldnames(d);
    for i = 1:numel(f)
        if ~isfield(cfg, f{i}), cfg.(f{i}) = d.(f{i}); end
    end
end
