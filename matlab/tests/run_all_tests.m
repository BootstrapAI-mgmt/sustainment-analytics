%RUN_ALL_TESTS  Verification suite.
%
%   octave-cli tests/run_all_tests.m      (from the matlab/ directory)
%   >> run_all_tests                      (MATLAB, matlab/ on the path)
%
%   Set COVERAGE_REPS in the environment to change the number of
%   replicate fleets in the coverage test. The default of 60 runs in a
%   couple of minutes; more replicates tighten the Monte Carlo band.

here = fileparts(mfilename('fullpath'));
if isempty(here), here = pwd(); end
addpath(fileparts(here)); addpath(here);

reps = str2double(getenv('COVERAGE_REPS'));
if isnan(reps) || reps < 5, reps = 60; end

fprintf('\n================ verification suite ================\n');
t0 = tic;

results = {};
results{end+1} = test_samplers();
results{end+1} = test_guards();
results{end+1} = test_ingest_hardening();
results{end+1} = test_parameter_recovery();
results{end+1} = test_allocation_optimality();
results{end+1} = test_sigma_identification();
results{end+1} = test_pooling_benefit();
results{end+1} = test_interval_coverage(reps);

n_pass = 0;
for i = 1:numel(results)
    r = results{i};
    if r.pass, tag = 'PASS'; else, tag = 'FAIL'; end
    fprintf('\n[%s] %s\n', tag, r.name);
    for j = 1:numel(r.lines), fprintf('%s\n', r.lines{j}); end
    n_pass = n_pass + r.pass;
end

fprintf('\n----------------------------------------------------\n');
fprintf('%d of %d suites passed in %.0f s\n\n', n_pass, numel(results), toc(t0));

% The committed results/verification_output.txt used to be a hand-captured
% copy of this console output, which is how an artifact rots: nothing
% regenerated it, so nothing could notice it no longer matched the code.
% The suite now writes it itself; CI regenerates it on every push and
% compares it numerically against the committed copy (tools/check_drift.py).
% Wall time goes on a [timing] line the comparator is told to skip.
rep = {'================ verification suite ================'};
for i = 1:numel(results)
    r = results{i};
    if r.pass, tag = 'PASS'; else, tag = 'FAIL'; end
    rep{end+1} = '';
    rep{end+1} = sprintf('[%s] %s', tag, r.name);
    for j = 1:numel(r.lines), rep{end+1} = r.lines{j}; end
end
rep{end+1} = '';
rep{end+1} = '----------------------------------------------------';
rep{end+1} = sprintf('%d of %d suites passed', n_pass, numel(results));
rep{end+1} = sprintf('[timing] %.0f s on this machine (excluded from comparison)', toc(t0));
if exist('OCTAVE_VERSION', 'builtin')
    interp = sprintf('octave %s', OCTAVE_VERSION());
else
    interp = sprintf('matlab %s', version());
end
rep{end+1} = sprintf('[env] %s on %s (excluded from comparison)', interp, computer());
outdir = fullfile(fileparts(fileparts(here)), 'results');
if ~exist(outdir, 'dir'), mkdir(outdir); end
vf = fullfile(outdir, 'verification_output.txt');
fid = fopen(vf, 'w');
fprintf(fid, '%s\n', rep{:});
fclose(fid);
fprintf('written %s\n', vf);

% exit() quits the whole application in MATLAB, destroying the user's
% workspace on a test failure. Only exit when running headless, where a
% non-zero status is the point (CI reads it).
if n_pass < numel(results)
    if exist('OCTAVE_VERSION', 'builtin') || ~usejava('desktop')
        exit(1);
    else
        error('tests:failed', '%d of %d suites failed.', ...
              numel(results) - n_pass, numel(results));
    end
end
