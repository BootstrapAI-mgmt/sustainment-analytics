function ebo_tab = expected_backorders(Lambda, s_max)
%EXPECTED_BACKORDERS  Exact E[(D-s)^+] under Poisson demand, per stock level.
%
%   Lambda is [n_draws x n_parts] of posterior demand rates. Returns an
%   [s_max+1 x n_parts] table of expected backorders, averaged over the
%   posterior.
%
%   For D ~ Poisson(L):
%
%       E[(D-s)^+] = L * (1 - F(s-1; L))  -  s * (1 - F(s; L))
%
%   evaluated in closed form and averaged across draws, rather than by
%   counting Monte Carlo samples of D.
%
%   THIS REPLACED A SAMPLE-COUNTING VERSION, and the reason matters. The
%   marginal difference EBO(s) - EBO(s+1) equals P(D > s), which at 4,000
%   Poisson samples carries a standard error near 0.008 -- comparable to
%   the gap between adjacent candidates once the buy list is a few items
%   deep. Re-drawing the same posterior eight times moved the buy ORDER
%   from rank 8 onward. Since the docstring of MARGINAL_SPARES_ALLOCATION
%   claims that order is the explanation, an explanation that changes when
%   nothing changed is not one. The closed form removes the sampling
%   noise entirely and leaves only the posterior uncertainty, which is
%   real and belongs there.
%
%   Expected backorders, not fill rate, is the quantity that composes
%   across parts into fleet availability (Sherbrooke 1968), which is why
%   the allocation optimises against it.

    if any(~isfinite(Lambda(:))) || any(Lambda(:) < 0)
        error('ebo:bad_rate', 'Demand rate must be finite and non-negative.');
    end
    if any(Lambda(:) > 500)
        error('ebo:rate_too_large', ...
              ['Demand rate above 500 underflows exp(-Lambda) in the ' ...
               'recursion; use a normal approximation for that regime.']);
    end

    [~, N] = size(Lambda);
    ebo_tab = zeros(s_max + 1, N);

    pmf = exp(-Lambda);            % P(D = 0)
    F   = pmf;                     % F(0)
    Fm1 = zeros(size(Lambda));     % F(-1) = 0

    for s = 0:s_max
        val = Lambda .* (1 - Fm1) - s .* (1 - F);
        ebo_tab(s + 1, :) = mean(max(val, 0), 1);

        Fm1 = F;
        pmf = pmf .* Lambda / (s + 1);
        F   = F + pmf;
    end
end
