function attr = attribute_evidence(fleet, fit)
%ATTRIBUTE_EVIDENCE  Decompose each part estimate into its evidence sources.
%
%   The explanation a sustainment analyst actually needs is not a feature
%   importance score. It is an answer to "how much of this number came
%   from THIS part, and how much was borrowed from the family it was
%   pooled with?" -- because that determines whether the estimate will
%   move when the next failure is reported, and whether it is safe to act
%   on now.
%
%   The borrowed fraction is the precision-weighted shrinkage factor
%   (Gelman et al., BDA3 ch. 5), with the part's precision taken as the
%   OBSERVED FISHER INFORMATION about log(lambda_i) under right
%   censoring, evaluated at the posterior scale:
%
%       tau_data_i = k^2 * sum_j (t_ij / lambda_post_i)^k    (all units j)
%       tau_family = 1 / sigma^2
%       w_i        = tau_family / (tau_family + tau_data_i)
%
%   The sum runs over EVERY unit of the part, survivors included: under
%   censoring, exposure IS evidence -- that is the entire reason censored
%   units are modelled rather than dropped -- and sum_j z_ij is the
%   model's expected failure count given that exposure. An earlier
%   version plugged in the OBSERVED failure count d_i instead, which
%   zeroes the survivors' contribution; a never-failed part with 24 units
%   and hundreds of hours each reported "100% borrowed" while its own
%   posterior sat visibly tighter than the family prior -- the number and
%   the interval contradicted each other on the same screen. (At the
%   part's own MLE the two definitions coincide, since the censored MLE
%   solves sum_j z_ij = d_i; they part company exactly where attribution
%   matters most, the zero- and few-failure parts whose posterior is not
%   at their own MLE.)
%
%   w_i is the fraction of the estimate carried by the family. It falls
%   as a part's own evidence -- failures or exposure -- grows, lies in
%   (0, 1] by construction, and reaches 1 only for a part with no
%   exposure at all.
%
%   An EARLIER VERSION of this function defined w geometrically, as how
%   far the posterior sat between the part's own MLE and the family mean.
%   That definition failed here: under 90%+ censoring the marginal
%   posterior for a part's scale is strongly right-skewed, so its
%   summary can fall OUTSIDE the interval spanned by those two anchors,
%   and w had to be clipped -- producing weights that were not monotone
%   in the failure count and could not be defended to a reviewer. The
%   empirical anchors are still reported below for transparency; they are
%   no longer what the weight is computed from.

    N = fleet.n_parts;

    k_hat     = mean(fit.pooled.k);
    sigma_hat = mean(fit.pooled.sigma);

    % Geometric (log-scale) summaries: the Weibull scale is a
    % multiplicative quantity, so the log scale is where it is averaged.
    lam_post   = exp(mean(log(fit.pooled.lambda), 1))';
    lam_family = exp(mean(fit.pooled.mu));

    [lam_own, has_own] = weibull_scale_mle(fleet.t, fleet.censored, ...
                                           fleet.part_id, N, k_hat);

    d          = fleet.n_failures;
    tau_data   = zeros(N, 1);
    for i = 1:N
        ti = fleet.t(fleet.part_id == i);
        tau_data(i) = k_hat^2 * sum((ti ./ lam_post(i)) .^ k_hat);
    end
    tau_family = 1 / sigma_hat^2;
    w          = tau_family ./ (tau_family + tau_data);

    lo = zeros(N, 1); hi = zeros(N, 1);
    for i = 1:N
        lo(i) = pctile(fit.pooled.lambda(:, i), 0.05);
        hi(i) = pctile(fit.pooled.lambda(:, i), 0.95);
    end

    attr = struct();
    attr.part_id        = (1:N)';
    attr.n_units        = fleet.units_per_part;
    attr.n_failures     = d;
    attr.lambda_own     = lam_own;
    attr.has_own        = has_own;
    attr.lambda_family  = repmat(lam_family, N, 1);
    attr.lambda_post    = lam_post;
    attr.lambda_lo90    = lo;
    attr.lambda_hi90    = hi;
    attr.family_weight  = w;
    attr.interval_width_ratio = hi ./ lo;
end
