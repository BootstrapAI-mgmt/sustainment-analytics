function alloc = marginal_spares_allocation(dem, cost, n_aircraft, qty, budget, s_max)
%MARGINAL_SPARES_ALLOCATION  Greedy buy list, self-documenting by construction.
%
%   Classic marginal analysis: repeatedly buy the single spare that
%   removes the most expected backorders per dollar. Because expected
%   backorders are convex and decreasing in the stock level, one pass
%   produces the whole cost/EBO curve. How good that curve is, is
%   MEASURED, not asserted: tests/test_allocation_optimality.m holds it
%   against an exact budget-indexed dynamic program for the EBO objective
%   and finds every prefix within ~2e-3 backorders (of totals near 20) of
%   the DP at its own spend on the demo-scale configuration. An earlier
%   version of this comment said the prefix optimality "holds exactly",
%   citing a DP that existed nowhere in the repository -- the test that
%   now exists is what disproved the "exactly": with unequal integer
%   costs the greedy can sit a hair above the DP, and the honest claim is
%   the measured bound. (Availability weights each part's backorders
%   differently, so the availability-optimal allocation is a different,
%   combinatorial problem that neither the greedy nor the DP solves.)
%
%   The reason to prefer this over handing the same problem to a general
%   integer-program solver is not speed. It is that the ORDER of the buy
%   list is itself the explanation. "This part was bought 7th because at
%   that point it returned 0.00071 backorders removed per dollar, against
%   0.00049 for the next candidate" is an audit trail a supply chain
%   officer can challenge on its merits. A solver returning an optimal
%   vector supports no such conversation.
%
%   AFFORDABILITY IS A MASK, NOT A STOP. An earlier version broke out of
%   the loop the first time the best-ranked candidate exceeded the
%   remaining budget, leaving budget unspent while cheaper parts still had
%   affordable units with positive return. Re-measured by
%   tests/test_allocation_optimality.m on its fixed $40,000 configuration:
%   the stop rule leaves $1,750 unspent and 0.31 expected backorders
%   (about half an availability point) on the table against the same rule
%   with the mask. (Earlier versions of this comment quoted a different
%   configuration's numbers from memory; only the test's output is quoted
%   now, because only the test's output regenerates.)
%
%   The result is a budget-constrained greedy: formally a knapsack
%   heuristic, measured on the same test at 0.002 expected backorders
%   (under 0.01%) above the exact DP at the full budget. STOP_REASON
%   records why the list ended, so "budget spent", "stock cap reached",
%   and "nothing left worth buying" are never confused for one another.

    N = numel(cost);
    if nargin < 6 || isempty(s_max), s_max = 30; end

    % Exact expected backorders per stock level, averaged over the
    % posterior. See EXPECTED_BACKORDERS for why this is not resampled.
    ebo_tab = expected_backorders(dem.Lambda, s_max);

    s     = zeros(N, 1);
    spent = 0;
    step  = 0;
    stop_reason = 'no_gain';

    trace = struct('step', {}, 'part', {}, 'unit_cost', {}, ...
                   'cum_cost', {}, 'dEBO', {}, 'dEBO_per_dollar', {}, ...
                   'availability', {});

    ebo_now = ebo_tab(1, :)';
    A0 = fleet_availability(ebo_now, n_aircraft, qty);

    while true
        gain      = zeros(N, 1);
        affordable = false(N, 1);
        for i = 1:N
            if s(i) >= s_max, continue; end
            if spent + cost(i) > budget, continue; end
            affordable(i) = true;
            gain(i) = (ebo_tab(s(i) + 1, i) - ebo_tab(s(i) + 2, i)) / cost(i);
        end

        if ~any(affordable)
            if any(s >= s_max) && all(s(~affordable) >= s_max)
                stop_reason = 'stock_cap';
            else
                stop_reason = 'budget';
            end
            break
        end

        [best_gain, i] = max(gain);
        if best_gain <= 1e-12
            stop_reason = 'no_gain';
            break
        end

        d_ebo = ebo_tab(s(i) + 1, i) - ebo_tab(s(i) + 2, i);
        s(i)  = s(i) + 1;
        spent = spent + cost(i);
        step  = step + 1;

        for j = 1:N, ebo_now(j) = ebo_tab(s(j) + 1, j); end
        A = fleet_availability(ebo_now, n_aircraft, qty);

        trace(step) = struct('step', step, 'part', i, 'unit_cost', cost(i), ...
                             'cum_cost', spent, 'dEBO', d_ebo, ...
                             'dEBO_per_dollar', best_gain, 'availability', A);
    end

    alloc = struct();
    alloc.stock              = s;
    alloc.total_cost         = spent;
    alloc.budget             = budget;
    alloc.unspent            = budget - spent;
    alloc.stop_reason        = stop_reason;
    alloc.at_stock_cap       = sum(s >= s_max);
    alloc.ebo                = ebo_now;
    alloc.availability       = fleet_availability(ebo_now, n_aircraft, qty);
    alloc.availability_zero  = A0;
    alloc.trace              = trace;
    alloc.frontier_cost      = [0, arrayfun(@(x) x.cum_cost,     trace)];
    alloc.frontier_avail     = [A0, arrayfun(@(x) x.availability, trace)];
end
