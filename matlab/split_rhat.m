function r = split_rhat(x)
%SPLIT_RHAT  Split potential-scale-reduction factor (Gelman et al., BDA3).
%
%   x is [n_draws x n_chains]. Each chain is split in half before the
%   between/within comparison, so that a chain which is drifting -- rather
%   than merely disagreeing with its neighbours -- is also caught.
%
%   R-hat near 1 means the chains are exploring the same distribution.
%   Values above about 1.01-1.05 mean the draws should not be trusted as
%   a posterior sample yet.

    [n, c] = size(x);
    h = floor(n / 2);
    if h < 2, r = NaN; return; end

    s = [x(1:h, :), x(h+1:2*h, :)];   % [h x 2c] split chains
    m = size(s, 2);

    chain_means = mean(s, 1);
    chain_vars  = var(s, 0, 1);

    W = mean(chain_vars);
    B = h * var(chain_means, 0);

    if W <= 0, r = NaN; return; end

    var_hat = (h - 1) / h * W + B / h;
    r = sqrt(var_hat / W);
end
