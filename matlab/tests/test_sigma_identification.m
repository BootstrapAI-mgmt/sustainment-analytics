function r = test_sigma_identification()
%TEST_SIGMA_IDENTIFICATION  The documented sigma limit, measured with replicates.
%
%   VALIDATION.md section 5 documents that the part-to-part spread sigma
%   is weakly identified with few groups. Its original table was a
%   one-off, single-fleet measurement with no generating command -- and
%   when this test first regenerated it with fresh seeds, the single-draw
%   "bias" came out with the OPPOSITE sign, which is the difference
%   between one draw and a bias made concrete. A bias is a property of
%   repetition, so this test fits REPLICATE fleets per size and compares
%   the mean error against the standard error measured from those same
%   replicates. The doc quotes this output and nothing else.

    r = struct('name', 'sigma identification vs number of groups', ...
               'pass', true, 'lines', {{}});

    truth = 0.45; R = 8;
    G = [12 40];
    stats = zeros(numel(G), 3);   % mean sigma-hat, se of mean, mean CI width
    for gi = 1:numel(G)
        sh = zeros(R, 1); wid = zeros(R, 1);
        for rep = 1:R
            cfg = struct('n_parts', G(gi), 'units_per_part', 16, 'k_true', 1.8, ...
                         'mu_true', log(3000), 'sigma_true', truth, ...
                         'horizon', 900, 'seed', 1000 * gi + rep);
            fleet = generate_synthetic_fleet(cfg);
            fit = fit_hierarchical_weibull(fleet, struct('n_burn', 1500, 'n_keep', 1500, ...
                                                         'n_chains', 2, 'seed', 70 + rep));
            s = fit.pooled.sigma;
            sh(rep)  = mean(s);
            wid(rep) = pctile(s, 0.95) - pctile(s, 0.05);
        end
        stats(gi, :) = [mean(sh), std(sh) / sqrt(R), mean(wid)];
        r.lines{end+1} = sprintf(['  %3d parts, %d replicate fleets: sigma-hat %.3f ' ...
                                  '+/- %.3f (truth %.2f), mean 90%% CI width %.3f'], ...
                                 G(gi), R, stats(gi, 1), stats(gi, 2), truth, stats(gi, 3));
    end

    bias = stats(:, 1) - truth;
    ok = abs(bias(2)) <= abs(bias(1)) + 2 * norm(stats(1:2, 2));
    r = add(r, ok, sprintf(['  identification improves with groups: |bias| %.3f at 12 ' ...
                            'parts vs %.3f at 40 (2-SE slack %.3f)'], ...
                           abs(bias(1)), abs(bias(2)), 2 * norm(stats(1:2, 2))));
    ok = stats(1, 3) > stats(2, 3);
    r = add(r, ok, '  the 12-part interval is wider, as a weakly identified parameter''s should be');
    ok = abs(bias(1)) <= 3 * stats(1, 2) + 0.10;
    r = add(r, ok, sprintf(['  12-part bias %.3f within 3 SE + 0.10 of zero -- the limit is ' ...
                            'WIDTH and prior pull, not a large systematic bias'], bias(1)));
end

function r = add(r, ok, line)
    r.pass = r.pass && ok;
    if ok, tag = 'PASS'; else, tag = 'FAIL'; end
    r.lines{end+1} = sprintf('%s  %s', line, tag);
end
