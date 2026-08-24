function q = pctile(x, p)
%PCTILE  Percentile of a sample by linear interpolation.
%
%   Deliberately hand-rolled: MATLAB's QUANTILE lives in the Statistics
%   and Machine Learning Toolbox, and this repository is meant to run on
%   a bare MATLAB install or on GNU Octave with nothing added.
%
%   Matches the MATLAB/Octave default definition: sample values sit at
%   plotting positions (i - 0.5)/n, with clamping outside that range.
%
%   NaNs are dropped rather than sorted to the end. SORT places NaN last,
%   so leaving them in inflates n and shifts every percentile -- the
%   median of [1..9, NaN] comes back as 5.5 instead of 5, quietly.

    x = x(:);
    x = sort(x(~isnan(x)));
    n = numel(x);
    if n == 0, q = NaN(size(p)); return; end
    if n == 1, q = repmat(x, size(p)); return; end

    pos = n * p(:) + 0.5;              % 1-based fractional index
    lo  = floor(pos); hi = ceil(pos);
    lo  = min(max(lo, 1), n);
    hi  = min(max(hi, 1), n);
    w   = pos - floor(pos);

    q = (1 - w) .* x(lo) + w .* x(hi);
    q = reshape(q, size(p));
end
