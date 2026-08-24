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
