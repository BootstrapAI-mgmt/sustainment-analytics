function A = fleet_availability(ebo, n_aircraft, qty_per_aircraft)
%FLEET_AVAILABILITY  Sherbrooke's availability from expected backorders.
%
%       A = prod_i ( 1 - EBO_i / (Z * Q_i) ) ^ Q_i
%
%   Z aircraft, Q_i units of part i installed on each. The form assumes
%   backorders land independently across part numbers, which is the
%   standard single-indenture METRIC assumption and the reason the
%   allocation can be optimised greedily rather than jointly.
%
%   Reference: Sherbrooke, C.C., "METRIC: A Multi-Echelon Technique for
%   Recoverable Item Control", Operations Research 16(1), 1968.
%
%   Degenerate quantities are rejected rather than clamped. With Q_i = 0
%   the expression evaluates to 0^0 = 1, so a part with backorders and a
%   mis-keyed installed quantity drops silently out of the product and
%   raises apparent availability.

    if ~isscalar(n_aircraft) || ~isfinite(n_aircraft) || n_aircraft <= 0
        error('avail:bad_fleet', 'Aircraft count must be a positive scalar.');
    end
    if any(~isfinite(qty_per_aircraft)) || any(qty_per_aircraft <= 0)
        error('avail:bad_qty', ...
              'Per-aircraft quantity must be positive for every part.');
    end
    if any(~isfinite(ebo)) || any(ebo < 0)
        error('avail:bad_ebo', 'Expected backorders must be finite and non-negative.');
    end

    z = 1 - ebo(:) ./ (n_aircraft * qty_per_aircraft(:));
    z = max(z, 0);
    A = prod(z .^ qty_per_aircraft(:));
end
