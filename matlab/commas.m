function s = commas(x)
%COMMAS  Thousands separators, for printed reports only.
    s = sprintf('%.0f', abs(x));
    n = numel(s);
    if n > 3
        out = '';
        for i = 1:n
            out = [out s(i)];
            r = n - i;
            if r > 0 && mod(r, 3) == 0, out = [out ',']; end
        end
        s = out;
    end
    if x < 0, s = ['-' s]; end
end
