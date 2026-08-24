function set_seed(s)
%SET_SEED  Seed the RNG portably across MATLAB and GNU Octave.
    try
        rng(s, 'twister');
    catch
        rand('twister', s);
        randn('state', s);
    end
end
