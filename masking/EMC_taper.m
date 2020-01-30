function [TAPER] = EMC_taper(TYPE, SIZE, OPTION)
%
% [TAPER] = EMC_taper(TYPE, SIZE, OPTION)
% Compute a taper of a given type and a given length.
%
% Inputs:
%   TYPE (str):                 Type of taper; 'cosine' or 'linear'.
%
%   SIZE (int):                 Size (in pixel) of the taper. Should be at least 2.
%
%   OPTION (cell|struct):       Optional parameters.
%                               If cell: {param, value ; ...}, note the ';' between parameters.
%                               NOTE: Can be empty.
%                               NOTE: Unknown fields will raise an error.
%
%     -> 'start' (float|int):   Start the taper with this value.
%                               NOTE: by default ('first'=false), the first value ('startAt' value),
%                                     is not included in the taper.
%                               default = 1
%
%     -> 'end' (float|int):     Last value of the taper.
%                              	default = 0
%
%     -> 'first' (bool):        Whether or not the taper should include the 'start' pixel. In any case,
%                               the size of the taper will be respected (see example).
%                               default = false
%
%     -> 'method' (str):        Compute and return the taper on the 'cpu' or 'gpu'.
%                               default = 'cpu'
%
%     -> 'precision' (str):     'single' or 'double' precision of the taper.
%                               default = 'single'
%
% Output:
%   TAPER:                      Numerical row vector of size=SIZE.
%
% Examples:
%   - OUT = EMC_taper('linear', 6, {});  % start=1, end=0
%     OUT (single): [0.83, 0.67, 0.50, 0.33, 0.17, 0]
%
%   - OUT = EMC_taper('linear', 6, {'first', true});  % start=1, end=0
%     OUT (single): [1, 0.8, 0.6, 0.4, 0.2, 0]
%
% Other EMC-files required:
%   EMC_getOption, EMC_setMethod, EMC_setPrecision
%

% Created:  18Jan2020, R2019a
% Version:  v.1.0   switch to optional parameters (TF, 20Jan2020).
%           v.1.1   unittest (TF, 21Jan2020).
%

%% CheckIN

% SIZE
if ~(isscalar(SIZE) && isnumeric(SIZE) && ~rem(SIZE, 1) && SIZE > 1)
    error('EMC_taper:SIZE', 'SIZE should be an int, greater than 1')
end

OPTION = EMC_getOption(OPTION, {'start', 'end', 'first', 'method', 'precision'}, false);

% precision
if isfield(OPTION, 'precision')
    if ~(strcmpi('single', OPTION.precision) || strcmpi('double', OPTION.precision))
      	error('EMC_taper:precision', "OPTION.precision should be 'single' or 'double'")
    end
else
    OPTION.precision = 'single';  % default
end

% method
if isfield(OPTION, 'method')
    if ~(strcmpi('gpu', OPTION.method) || strcmpi('cpu', OPTION.method))
      	error('EMC_taper:method', "OPTION.method should be 'cpu' or 'gpu'")
    end
else
    OPTION.method = 'cpu';  % default
end

% start
if isfield(OPTION, 'start')
    if ~(isscalar(OPTION.start) && isnumeric(OPTION.start))
        error('EMC_taper:start', 'start should be a float|int, got %s, numel=%d', ...
              class(OPTION.start), numel(OPTION.start))
    end
else
    OPTION.start = 1;  % default
end

% end
if isfield(OPTION, 'end')
    if ~(isscalar(OPTION.end) && isnumeric(OPTION.end))
        error('EMC_taper:end', 'end should be a float|int, got %s, numel=%d', ...
              class(OPTION.end), numel(OPTION.end))
    end
else
    OPTION.end = 0;  % default
end

% first
if isfield(OPTION, 'first')
    if isscalar(OPTION.first) && islogical(OPTION.first)
        if OPTION.first
            OPTION.first = 1;
        else
            OPTION.first = 0;
        end
    else
        error('EMC_taper:first', 'first should be a (scalar) bool, got %s, numel=%d', ...
              class(OPTION.first), numel(OPTION.first))
    end
else
    OPTION.first = 0;  % default
end

%% Compute the taper

% With reallistic taper size, it is faster (in my [TF] case) to compute it on the cpu and transfer
% to gpu rather than creating the vector directly on the gpu with gpuArray.colon|linspace or by inheritance.
if strcmpi(TYPE, 'cosine')
    adjust = abs(OPTION.start - OPTION.end)/2 + min(OPTION.start, OPTION.end);
    adjustSize = SIZE - OPTION.first;
    TAPER = cos((1-OPTION.first:adjustSize) .* pi ./ adjustSize) .* (OPTION.start - OPTION.end)/2 + adjust;

elseif strcmpi(TYPE, 'linear')
    TAPER = linspace(OPTION.start, OPTION.end, SIZE + 1 - OPTION.first);
    if ~OPTION.first
        TAPER = TAPER(2:end);
    end
else
    error('EMC_taper:TYPE', "TYPE should be 'cosine' or 'linear'")
end

% Cast to desired precision; push or gather if necessary.
TAPER = EMC_setMethod(EMC_setPrecision(TAPER, OPTION.precision), OPTION.method);

end
