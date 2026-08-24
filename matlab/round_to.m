function y = round_to(x, n)
%ROUND_TO  Round to n decimal places, portably.
%
%   MATLAB's two-argument ROUND(X, N) arrived in R2014b and is still not
%   in GNU Octave 8. Doing it by hand keeps one code path for both.
    if nargin < 2, n = 0; end
    f = 10 ^ n;
    y = round(x * f) / f;
end
