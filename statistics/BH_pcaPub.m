function [  ] = BH_pcaPub(PARAMETER_FILE, CYCLE, PREVIOUS_PCA)
%Extract and interpolate a subTomogram from a 3d volume.
%
%   Input variables:
%
%  CYCLE = 0,1,2 etc.
%
%
%
%   samplingRate = Binning factor, assumed to be integer value. Image is first
%              smoothed by an appropriate low-pass filter to reduce aliasing.
%
%   randomSubset = -1, count all non-ignored particles (class -9999).
%
%                float, randomly select this many paparticleBandpassrticles for the
%                decomposition, denote by updating the flag in column 8 to be 1
%                or 0.
%
%                string - indicates a mat file with prior decomposition.
%
%   maxEigs = Maximum number of principle components to save, general 50
%                   has been plenty. This is a big memory saver.
%
%   bandpass =  [HIGH_THRESH, HIGH_CUT, LOW_CUT, PIXEL_SIZE]
%
%   AVERAGE_MOTIF = string pointing to an average to be used for wedge masked
%                   differences.
%
%   GEOMETRY = A structure with tomogram names as the field names, and geometry
%              information in a 28 column array.
%              Additionally, a field called 'source_path' has a value with the
%              absolute path to the location of the tomograms.
%
%              The input is a string 'Geometry_templatematching.mat' for
%              example, and it is expected that the structure is saved as the
%              variable named geometry.
%
%
%
%
%   Output variables:
%
%   None = files are written to disk in the current directory. This will be a
%   mat file that has the 
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%   Goals & Limitations:
%
%   Extract, filter, and mask included subtomograms and perform a singular value
%   decomposition. Either all included (non -9999 class) or a subset may be
%   specified. If a subset is specified, then the decomposition will be done on
%   these while the full projection follows.
%
%   Assumed to run on GPU (extraction) and then CPU (Decomposition) the latter
%   can be very memory intensive.
%
%   To avoid errors and complications, the full data set will be extracted,
%   which is used to generate an average
%
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
%
%   TODO
%     - Error checking for memory limitations     
%     - In testing verify "implicit" gpu arrays are actually gpu arrays
%     - Check binning
%     - Confirm position 7 is where I want to keep FSC value
%     - Update geometry to record % sampling
%
%     - calculate max size possible to keep temp data matrix on the gpu,
%     sigfificantly reduces overhead.
%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%


%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
% PARAMETER_FILE = 'testParam.m';
%CYCLE = 2;
%PREVIOUS_PCA = true;

%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

if (nargin ~= 3)
%  error('PARAMETER_FILE, CYCLE, PREVIOUS_PCA')
end

startTime =  clock;

CYCLE = str2num(CYCLE);
PREVIOUS_PCA = str2num(PREVIOUS_PCA);

global bh_global_binary_pcaMask_threshold;

% Previous_pca has two functions, when true and > 0 use the decomposition
% calculated from a random subset of the data to project the full data set
% onto each of the selected principle components. when true and < 0 run
% with the same parameters as before, but this time load in the adjusted
% variance maps to use as a mask for each scale space. 
% -2 use variance map, -1 use stdDev instead

switch PREVIOUS_PCA
  case -3
    flgVarianceMap = 0;
    flgStdDev = 0;
    flgLoadMask = 1;
    PREVIOUS_PCA = 0;
  case -2
    flgVarianceMap = 1;
    flgStdDev = 1;
    PREVIOUS_PCA = 0;
    flgLoadMask = 0;
  case -1
    flgVarianceMap = 1;
    flgStdDev = 0.5;
    PREVIOUS_PCA = 0;
    flgLoadMask = 0;
  case 0
    flgVarianceMap = 0;
    flgStdDev = 0;
    flgLoadMask = 0;
  case 1 
    % case 0 and 1 same except value of PREVIOUS_PCA
    flgVarianceMap = 0;
    flgStdDev = 0;
    flgLoadMask = 0;
  otherwise
    error('PREVIOUS_PCA should be 1,0,-1,-2,-3')
end
    
flgWMDs = 3;

cycleNumber = sprintf('cycle%0.3u', CYCLE);

pBH = BH_parseParameterFile(PARAMETER_FILE);
reconScaling = 1;
%%% Put this in the param file later - the input values should be in angstrom
%%% and are the relevant scale spaces for classification.

pcaScaleSpace  = pBH.('pcaScaleSpace');
nScaleSpace = numel(pcaScaleSpace);
samplingRate   = pBH.('Cls_samplingRate');
refSamplingRate= pBH.('Ali_samplingRate');
randomSubset   = pBH.('Pca_randSubset');
maxEigs        = pBH.('Pca_maxEigs');
pixelSize = pBH.('PIXEL_SIZE').*10^10.*samplingRate;
refPixelSize = pBH.('PIXEL_SIZE').*10^10.*refSamplingRate;
if pBH.('SuperResolution')
  pixelSize = pixelSize * 2;
  refPixelSize = refPixelSize * 2;
end
nCores  = BH_multi_parallelWorkers(pBH.('nCpuCores'));
pInfo = parcluster();

nTempParticles = pBH.('PcaGpuPull');
try
  scaleCalcSize = pBH.('scaleCalcSize');
catch
  scaleCalcSize = 1.5;
end
outputPrefix   = sprintf('%s_%s', cycleNumber, pBH.('subTomoMeta'));
%%%flgGold      = pBH.('flgGoldStandard');

try
  nPeaks = pBH.('nPeaks');
catch
  nPeaks = 1;
end

flgNorm = 0;% pBH.('flgNormalizeWMDs');
try
  flgPcaShapeMask = pBH.('flgPcaShapeMask');
catch
  flgPcaShapeMask = 1;
end

flgClassify = pBH.('flgClassify');

% Removed flgGold everywhere else, but keep ability to classify full data set at
% the end (after all alignment is finished.) 
%%% For general release, I've disabled class average alignment and
%%% multi-reference alignment, so set the default to OFF. If either of
%%% these features are re-introduced, this will need to be reverted.
if ( flgClassify ); flgClassify = -1 ; end

if flgClassify < 0
  flgGold = 0;
else
  flgGold = 1;
end


load(sprintf('%s.mat', pBH.('subTomoMeta')), 'subTomoMeta');
mapBackIter = subTomoMeta.currentTomoCPR;
geometry = subTomoMeta.(cycleNumber).Avg_geometry;

try
  flgCutOutVolumes = pBH.('flgCutOutVolumes');
catch
  flgCutOutVolumes = 0;
end

try
  CUTPADDING = subTomoMeta.('CUTPADDING')
catch
  CUTPADDING=20
end

% % 
% % pathList= subTomoMeta.mapPath;
% % extList = subTomoMeta.mapExt;
masterTM = subTomoMeta; clear subTomoMeta

[ useGPU ] = BH_multi_checkGPU( -1 );
gDev = gpuDevice(useGPU);


% Get the number of tomograms to process.
tomoList = fieldnames(geometry);
nTomograms = length(tomoList);

                                                     
[ maskType, maskSize, maskRadius, maskCenter ] = ...
                                  BH_multi_maskCheck(pBH, 'Cls', pixelSize);

[ preMaskType, preMaskSize, preMaskRadius, preMaskCenter ] = ...
                                  BH_multi_maskCheck(pBH, 'Ali', refPixelSize);

% This is prob not a good way to make sure the mask size matches::w
maskSize=preMaskSize;

% Make sure everthing matches the extracted average and wedge
cpuVols = struct;

[ preSizeWindow, preSizeCalc, preSizeMask, prePadWindow, prePadCalc ] = ...
                                    BH_multi_validArea(preMaskSize,preMaskRadius, scaleCalcSize )


  [ sizeWindow, sizeCalc, sizeMask, padWindow, padCalc ] = ...
                 BH_multi_validArea( maskSize, maskRadius, scaleCalcSize )


refName = 0;
averageMotif = cell(2,1);

% If flgClassify is negative combine the data for clustering, but don't set
% any of the alignment changes to be persistant so that extracted class
% averages are still independent half-sets.
if (flgGold)
  oddRot = eye(3);
else
  iRefPrev = 1;
  try
    aliParams = masterTM.(cycleNumber).('fitFSC').(sprintf('Resample%s%d','REF',iRefPrev))
    oddRot = reshape(aliParams(1,:),3,3)';
    % refine the translation per particle.
  catch
    fprintf('\nReverting from %s to Raw in loading fitFSC\n','REF');
    aliParams = masterTM.(cycleNumber).('fitFSC').(sprintf('Resample%s%d','Raw',iRefPrev))
    oddRot = reshape(aliParams(1,:),3,3)';
    % refine the translation per particle.    
  end
  clear iRefPrev
end

    
for iGold = 1:2
  
%   if (flgGold)
    if iGold == 1;
      halfSet = 'ODD';
    else
      halfSet = 'EVE';
    end
%   else
%     halfSet = 'STD';
%   end

  try


        imgNAME = sprintf('class_%d_Locations_Raw_%s', refName, halfSet);
 

      [ averageMotif{iGold} ] = BH_unStackMontage4d(1, ...
                                   masterTM.(cycleNumber).(imgNAME){1}, ...
                                   masterTM.(cycleNumber).(imgNAME){2},...
                                   preSizeMask);

  catch

        imgNAME = sprintf('class_%d_Locations_REF_%s', refName, halfSet);
 

      [ averageMotif{iGold} ] = BH_unStackMontage4d(1, ...
                                   masterTM.(cycleNumber).(imgNAME){1}, ...
                                   masterTM.(cycleNumber).(imgNAME){2},...
                                   preSizeMask);
    
  end
  
  averageMotif{iGold} = averageMotif{iGold}{1};
  masterTM.(cycleNumber).(imgNAME){1}
  if (flgLoadMask) && (iGold == 1)
    fprintf('\n\nLoading external mask\n');
    externalMask = getVolume(MRCImage(sprintf('%s-pcaMask',masterTM.(cycleNumber).(imgNAME){1})));
  end
end

% IF combining for analysis, resample prior to any possible binning.
if ~(flgGold)
  averageMotif{1} = averageMotif{2} + ...
                    BH_resample3d(gather(averageMotif{1}), ...
                                         oddRot, ...
                                         aliParams(2,1:3), ...
                                         {'Bah',1,'spline'}, 'cpu', ...
                                         'forward');
  averageMotif{2} = [];
end
  
%%% incomplete, the idea is to generate an antialiased scaled volume for PCA
if ( refSamplingRate ~= samplingRate ) 
    fprintf('Resampling from %d refSampling to %d pcaSampling\n',refSamplingRate,samplingRate);
    for iGold = 1:1+flgGold
      averageMotif{iGold} = BH_reScale3d(averageMotif{iGold},'',sprintf('%f',1/samplingRate),'GPU');
    end
    
    if (flgLoadMask)
      externalMask = BH_reScale3d(externalMask,'',sprintf('%f',1/samplingRate),'GPU');
    end
end
    
  
  
prevVarianceMaps = struct();
if (flgVarianceMap)
  
  for iGold = 1:1+flgGold
    
    if (flgGold)
      if iGold == 1;
        halfSet = 'ODD';
      else
        halfSet = 'EVE';
      end
    else
      halfSet = 'STD';
    end    

    % For randomsubset (PREVIOUS_PCA = 0) the suffix is *_pcaPart.mat) but
    % presumably we could have also just done full, so try that first

    try
      load(sprintf('%s_%s_pcaFull.mat',outputPrefix,halfSet))
    catch
      fprintf('\nDid not find, %s_%s_pcaFUll.mat, trying *_pcaPart.mat\n',outputPrefix,halfSet);
      load(sprintf('%s_%s_pcaPart.mat',outputPrefix,halfSet));
    end
    
    % In most cases, this is the number of "features" specified in the
    % parameter file, but in some data not even this may non-zero singluar
    % values are found, so the number could be different (lower)
    for iScale = 1:nScaleSpace
      eigsFound = size(coeffs{iScale},1);    
      fname = sprintf('%s_varianceMap%d-%s-%d.mrc', ...
                                 outputPrefix, eigsFound, halfSet, iScale);
      
      prevVarianceMaps.(sprintf('h%d',iGold)).(sprintf('s%d',iScale)) = ...
                                     getVolume(MRCImage(fname)).^flgStdDev;
    end
    clear v coeffs eigsFound idxList
  end
end



if (PREVIOUS_PCA) 
  volumeMask = gpuArray(getVolume(MRCImage( ...
                              sprintf('%s_pcaVolMask.mrc',outputPrefix))));
else

  try
    pcaSymmetry = pBH.('Pca_symMask');
    [ volumeMask ]    = BH_mask3d(maskType, sizeMask, maskRadius, maskCenter,0,pcaSymmetry);
  catch
    [ volumeMask ]    = BH_mask3d(maskType, sizeMask, maskRadius, maskCenter);

  end

  if ( flgPcaShapeMask )
      % when combining the addition is harmless, but is a convenient way to
      % include when sets are left 100% separate.
      volumeMask = volumeMask .* BH_mask3d(averageMotif{1}+averageMotif{1+flgGold}, pixelSize, '','');  
  end
  
  if (flgLoadMask)
size(volumeMask)
size(externalMask)
    volumeMask = volumeMask .* externalMask;
  end
  
  SAVE_IMG(MRCImage(gather(volumeMask)),sprintf('%s_pcaVolMask.mrc',outputPrefix),pixelSize);
end

volMask = struct();
nPixels = zeros(2,nScaleSpace);
for iScale = 1:nScaleSpace
  for iGold = 1:1+flgGold
    stHALF = sprintf('h%d',iGold);
    stSCALE = sprintf('s%d',iScale);
    if (flgVarianceMap)
      volTMP = gather(volumeMask.*prevVarianceMaps.(stHALF).(stSCALE));
    else 
      volTMP = gather(volumeMask);
    end
    
    masks.('volMask').(stHALF).(stSCALE) = (volTMP);
    masks.('binary').(stHALF).(stSCALE)  = (volTMP >= bh_global_binary_pcaMask_threshold);
    masks.('binary').(stHALF).(stSCALE)  = ...
                                  masks.('binary').(stHALF).(stSCALE)(:);
    masks.('binaryApply').(stHALF).(stSCALE)  = (volTMP >= 0.01);
% % % volBinaryMask = (volMask >= 0.5);
% % % volBinaryApply = (volMask >= 0.01);
% % % volBinaryMask = (volBinaryMask(:));
    nPixels(iGold,iScale) = gather(sum(masks.('binary').(stHALF).(stSCALE)));
    clear volTMP stHALF stSCALE
  end
end
clear volumeMask


      
% radius, convert Ang to pix , denom = equiv stdv from normal to include, e.g.
% for 95% use 1/sig = 1/2
%stdDev = 1/2 .* (pcaScaleSpace ./ pixelSize - 1)  .* 3.0./log(pcaScaleSpace)
stdDev = 1/2 .* (pcaScaleSpace ./ pixelSize )  ./ log(pcaScaleSpace)
for iScale = 1:nScaleSpace

    masks.('scaleMask').(sprintf('s%d',iScale)) = ...
                            gather(BH_bandpass3d( sizeMask, 10^-6, 400, ...
                                  pcaScaleSpace(iScale).*0.9, 'GPU', pixelSize ));

%    masks.('scaleMask').(sprintf('s%d',iScale)) = ...
%                            gather(BH_bandpass3d( sizeMask, 0.1, 400, ...
%                                  2.25.*pixelSize, 'GPU', pixelSize )) .* ...
%                            fftn(BH_multi_gaussian3d( ...
%                                                 sizeMask, -1.*stdDev(iScale)));

%     masks.('scaleMask').(sprintf('s%d',iScale)) = ...
%                             fftn(ifftshift(BH_multi_gaussian3d(sizeMask, 1.*stdDev(iScale))));

end

avgMotif_FT = cell(1+flgGold,nScaleSpace);
avgFiltered = cell(1+flgGold,nScaleSpace);
% Here always read in both, combine if flgGold = 0
for iGold = 1:1+flgGold
  for iScale = 1:nScaleSpace
    % Should I set these as double? Prob
    iGold

% % %     avgMotif_FT{iGold, iScale} = fftn(averageMotif{iGold}.*...
% % %                                       masks.('volMask').(sprintf('h%d',iGold)).(sprintf('s%d',iScale))) .* ...
% % %                                       masks.('scaleMask').(sprintf('s%d',iScale)) ;
            
% % % % %               masks.('scaleMask')
% % % % %               masks.('binaryApply').(sprintf('h%d',iGold))
% % % % %               masks.('volMask').(sprintf('h%d',iGold))

    averageMotif{iGold} = averageMotif{iGold} - mean(averageMotif{iGold}(masks.('binaryApply').(sprintf('h%d',iGold)).(sprintf('s%d',iScale))));
    averageMotif{iGold} = averageMotif{iGold} ./ rms(averageMotif{iGold}(masks.('binaryApply').(sprintf('h%d',iGold)).(sprintf('s%d',iScale))));
    averageMotif{iGold} = averageMotif{iGold} .* masks.('volMask').(sprintf('h%d',iGold)).(sprintf('s%d',iScale));
    
    avgMotif_FT{iGold, iScale} = ...
                            BH_bandLimitCenterNormalize(averageMotif{iGold},...
                            masks.('scaleMask').(sprintf('s%d',iScale)), ...           
                            masks.('binaryApply').(sprintf('h%d',iGold)).(sprintf('s%d',iScale)),...
                                                        [0,0,0;0,0,0],'single');

% % %       avgMotif_FT{iGold, iScale} = (real(ifftn( avgMotif_FT{iGold, iScale})));
      avgFiltered{iGold, iScale} = real(ifftn(avgMotif_FT{iGold, iScale}));

    avgFiltered{iGold, iScale} = avgFiltered{iGold, iScale} - mean(avgFiltered{iGold, iScale}(masks.('binary').(sprintf('h%d',iGold)).(sprintf('s%d',iScale))));
    avgFiltered{iGold, iScale} = gather(avgFiltered{iGold, iScale} ./rms(avgFiltered{iGold, iScale}(masks.('binaryApply').(sprintf('h%d',iGold)).(sprintf('s%d',iScale)))) .* ...
                                                                                                    masks.('binaryApply').(sprintf('h%d',iGold)).(sprintf('s%d',iScale)));
% % %     cpuVols.('avgMotif_FT').(sprintf('g%d_%d',iGold,iScale)) = gather(avgMotif_FT{iGold, iScale});
  end
end




montOUT = BH_montage4d(avgFiltered(1,:),'');
SAVE_IMG(MRCImage(montOUT), sprintf('test_filt.mrc'),pixelSize);
clear montOUT

% If randomSubset is string with a previous matfile use this, without any 
% decomposition. 

for iGold = 1:1+flgGold
  flgRefIsPadded = 0;
  if (flgGold)
    if iGold == 1;
      halfSet = 'ODD';
      stHALF = sprintf('h%d',iGold);
      randSet =1;
    else
      stHALF = sprintf('h%d',iGold);
      halfSet = 'EVE';
      randSet = 2;
    end
  else
    stHALF = sprintf('h%d',iGold);
    halfSet = 'STD';
    randSet = [1,2];
  end
  
  if (PREVIOUS_PCA)
    previousPCA = sprintf('%s_%s_pcaPart.mat',outputPrefix,halfSet);
    randomSubset = -1;
    [ geometry, nTOTAL, nSUBSET ] = BH_randomSubset( geometry,'pca', -1 , randSet);
  else
    if (randomSubset)
      previousPCA = false;
      [ geometry, nTOTAL, nSUBSET ] = BH_randomSubset( geometry,'pca', randomSubset, randSet );
    else
      previousPCA = false;
      [ geometry, nTOTAL, nSUBSET ] = BH_randomSubset( geometry,'pca', -1 , randSet);
    end
  end
  
  % Extend the random subset to each peak if needed
  if (nPeaks > 1)
    for iTomo = 1:nTomograms
      selectedList = geometry.(tomoList{iTomo})(:,8) > 0;
      geometry.(tomoList{iTomo})(selectedList,8+26:26:nPeaks*26) = 1;
      clear selectedList
    end
    nTOTAL = nTOTAL*nPeaks;
    nSUBSET = nSUBSET*nPeaks;
  end

  % Initialize array in main memory for pca
  clear dataMatrix tempDataMatrix 
  dataMatrix = cell(3,1);
  tempDataMatrix = cell(3,1);
  for iScale = 1:nScaleSpace
    dataMatrix{iScale} = zeros(nPixels(iGold,iScale), nSUBSET, 'single');
    tempDataMatrix{iScale} = zeros(nPixels(iGold,iScale), nTempParticles, 'single', 'gpuArray');
  end

  % Pull masks onto GPU (which are cleared along with everything else when
  % the device is reset at the end of each loop.)
  gpuMasks = struct();
  for iScale = 1:nScaleSpace
      stSCALE = sprintf('s%d',iScale);
      
      gpuMasks.('volMask').(stSCALE) = ...
                            gpuArray(masks.('volMask').(stHALF).(stSCALE));
      gpuMasks.('binary').(stSCALE) = ...
                             gpuArray(masks.('binary').(stHALF).(stSCALE));
      gpuMasks.('binaryApply').(stSCALE)  = ...
                        gpuArray(masks.('binaryApply').(stHALF).(stSCALE));
      gpuMasks.('scaleMask').(stSCALE) = gpuArray(masks.('scaleMask').(stSCALE));                      
   
  end
  
% % %   for iGold_inner = 1:1+flgGold
% % %     for iScale = 1:nScaleSpace
% % %       avgMotif_FT{iGold_inner, iScale} = ...
% % %                gpuArray(cpuVols.('avgMotif_FT').(sprintf('g%d_%d',iGold_inner,iScale)));
% % %     end
% % %   end


  nExtracted = 1;
  nTemp = 1;
  nTempPrev = 0;
  idxList = zeros(1,nSUBSET);
  peakList = zeros(1,nSUBSET);

  firstLoop = true;  sI = 1;
  nIgnored = 0;
  for iTomo = 1:nTomograms


    tomoName = tomoList{iTomo};
    iGPU = 1;
   tomoNumber = masterTM.mapBackGeometry.tomoName.(tomoList{iTomo}).tomoNumber;
   tiltName = masterTM.mapBackGeometry.tomoName.(tomoList{iTomo}).tiltName;
   reconCoords = masterTM.mapBackGeometry.(tiltName).coords(tomoNumber,:);
 
    if (flgCutOutVolumes)
     volumeData = [];
    else
      [ volumeData ] = BH_multi_loadOrBuild( tomoList{iTomo}, ...
                                    reconCoords, mapBackIter, ...
                                    samplingRate, iGPU, reconScaling,0); 
        volHeader = getHeader(volumeData);                              
    end
    

      nCtfGroups = masterTM.('ctfGroupSize').(tomoList{iTomo})(1);
      iTiltName = masterTM.mapBackGeometry.tomoName.(tomoName).tiltName;
      wgtName = sprintf('cache/%s_bin%d.wgt',iTiltName,samplingRate);       
%       wgtName = sprintf('cache/%s_bin%d.wgt', tomoList{iTomo},...
%                                               samplingRate);
      iTomoCTFs = BH_unStackMontage4d(1:nCtfGroups,wgtName,...
                                        ceil(sqrt(nCtfGroups)).*[1,1],'');
      padWdg = BH_multi_padVal(sizeMask,size(iTomoCTFs{1}));
      [radialGrid,~,~,~,~,~] = BH_multi_gridCoordinates(size(iTomoCTFs{1}), ...
                                                        'Cartesian',...
                                                        'GPU',{'none'},1,0,1);
      radialGrid = radialGrid ./ pixelSize;


      if ~(flgRefIsPadded)
        for iScale = 1:nScaleSpace
          avgMotif_FT{iGold, iScale} = BH_padZeros3d(avgMotif_FT{iGold, iScale},...
                                                     padWdg(1,:),padWdg(2,:),...
                                                     'GPU','single',0,1);
        end
        flgRefIsPadded = 1;
      end
    
 

        
    tiltGeometry = masterTM.tiltGeometry.(tomoList{iTomo});

    sprintf('Working on %d/%d volumes %s\n',iTomo,nTomograms,tomoName)
    % Load in the geometry for the tomogram, and get number of subTomos.
    positionList = geometry.(tomoList{iTomo});
    
    % Loop over peaks inside each tomo to limit wedge mask xfer
    nSubTomos = sum(positionList(:,26) ~= -9999);


    if (flgWMDs == 1)
      % Make a wedge mask that can be interpolated with no extrapolation for
      % calculating wedge weighting in class average alignment. 

      % COMMMMMMENT
        
      % make a binary wedge
      [ wedgeMask ]= BH_weightMask3d(sizeMask, tiltGeometry, ...
                     'binaryWedgeGPU',2*maskRadius,1, 1, samplingRate);
            
      SAVE_IMG(MRCImage(gather(wedgeMask)),'wdg.mrc');
      error('do not do it man');
    end    
    
    
    % reset for each tomogram
    wdgIDX = 0;
    
    for iSubTomo = 1:nSubTomos
      %%%%% %%%%%
      if (wdgIDX ~= positionList(iSubTomo,9))
        % Geometry is sorted on this value so that tranfers are minimized,
        % as these can take up a lot of mem. For 9 ctf Groups on an 80s
        % ribo at 2 Ang/pix at full sampling ~ 2Gb eache.
        wdgIDX = positionList(iSubTomo,9);
        fprintf('pulling the wedge %d onto the GPU\n',wdgIDX);
        wedgeMask = gpuArray(iTomoCTFs{wdgIDX});        
        % Weights are ctf^2
        wedgeMask = sqrt(wedgeMask - min(wedgeMask(:)) + 1e-6);
% %         SAVE_IMG(MRCImage(gather(wedgeMask)),'tmpWdg.mrc')
      end
            
      % Check that the given subTomo is not to be ignored - for now, treat
      % all peaks as included. The assumption is that using this will be
      % for initializing the project to get a good starting model. "True"
      % classification will be done at a later stage after reducing to some
      % subset of peaks. FIXME
      includeParticle = positionList(iSubTomo, 8);
      

      if (includeParticle) 

        for iPeak = 0:nPeaks-1

        % Get position and rotation info, angles stored as e1,e3,e2 as in AV3
        % and PEET. This also makes inplane shifts easier to see.

        center = positionList(iSubTomo,[11:13]+26*iPeak)./samplingRate;
        angles = positionList(iSubTomo,[17:25]+26*iPeak);
        
        % If flgGold there is no change, otherwise temporarily resample the
        % eve halfset to minimize differences due to orientaiton
        if positionList(iSubTomo,7) == 1 % This is true for all peaks 
          % TODO FIXME should this be the transpose of oddRot?
          angles = reshape(angles,3,3) * oddRot;
        end


        % Find range to extract, and check for domain error.
        if (flgCutOutVolumes)
            [ indVAL, padVAL, shiftVAL ] = ...
                          BH_isWindowValid(2*CUTPADDING+sizeWindow, ...
                                            sizeWindow, maskRadius, center);
        else
          [ indVAL, padVAL, shiftVAL ] = ...
                          BH_isWindowValid([volHeader.nX,volHeader.nY,volHeader.nZ], ...
                                            sizeWindow, maskRadius, center);
        end

        if ~(flgGold)
          shiftVAL = shiftVAL + aliParams(2,1:3)./samplingRate;
        end

        if ~ischar(indVAL)
          % Read in and interpolate at single precision as the local values
          % in the interpolant suffer from any significant round off errors.
          particleIDX = positionList(iSubTomo, 4); % Same for all peaks


          if (flgCutOutVolumes)
            
            particleOUT_name = sprintf('cache/subtomo_%0.7d_%d.mrc',positionList(iSubTomo,4),iPeak+1);
            iParticle = gpuArray(getVolume(MRCImage(particleOUT_name),...
                                                      [indVAL(1,1),indVAL(2,1)], ...
                                                      [indVAL(1,2),indVAL(2,2)], ...
                                                      [indVAL(1,3),indVAL(2,3)],'keep'));

          else
            
           iParticle = getVolume(volumeData,[indVAL(1,1),indVAL(2,1)], ...
                                            [indVAL(1,2),indVAL(2,2)], ...
                                            [indVAL(1,3),indVAL(2,3)],'keep');
          end


        if any(padVAL(:))

          [ iParticle ] = BH_padZeros3d(iParticle,  padVAL(1,1:3), ...
                                        padVAL(2,1:3), 'GPU', 'single');
        end

        % Transform the particle, and then trim to motif size

        [ iParticle ] = BH_resample3d(iParticle, angles, shiftVAL, ...
                                                        'Bah', 'GPU', 'inv');

          [ iWedge ] = BH_resample3d(wedgeMask, angles, [0,0,0], ...
                                    'Bah', 'GPU', 'inv');
% % %           SAVE_IMG(MRCImage(gather(iWedge)),'tmpWdg2.mrc')
  
     


        iTrimParticle = iParticle(padWindow(1,1)+1 : end - padWindow(2,1), ...
                                  padWindow(1,2)+1 : end - padWindow(2,2), ...
                                  padWindow(1,3)+1 : end - padWindow(2,3));




        for iScale = 1:nScaleSpace
          iPrt = BH_bandLimitCenterNormalize( ...
                            iTrimParticle .* ...
                            gpuMasks.('volMask').(sprintf('s%d',iScale)), ...
                            gpuMasks.('scaleMask').(sprintf('s%d',iScale)),...
                            gpuMasks.('binary').(sprintf('s%d',iScale)),...
                                                      [0,0,0;0,0,0],'single');



          
                                      
             
              [iWmd,~] = BH_diffMap(avgMotif_FT{iGold, iScale},iPrt,ifftshift(iWedge),...
                                    flgNorm,pixelSize,radialGrid, padWdg);
                            


          if all(isfinite(iWmd(gpuMasks.('binary').(sprintf('s%d',iScale)))))
            keepTomo = 1;
            tempDataMatrix{iScale}(:,nTemp) = single(iWmd(gpuMasks.('binary').(sprintf('s%d',iScale))));
          else
            fprintf('inf or nan in subtomo %d scalePace %d',iSubTomo,iScale);
            keepTomo = 0;
          end

        end
        clear iAvg iWmd  iTrimParticle



        if (keepTomo)
          idxList(1, nExtracted) = particleIDX;
          peakList(1,nExtracted) = iPeak+1; % This probably is not necessary - it should be 1:nPEaks,1:nPeaks,1:nPeaks...
          nExtracted = nExtracted +1;
          nTemp = nTemp + 1;

          % pull data of the gpu every 1000 particls (adjust this to max mem)
          if nTemp == nTempParticles - 1
            for iScale = 1:nScaleSpace
              dataMatrix{iScale}(:,1+nTempPrev:nTemp+nTempPrev-1) = ...
                                gather(tempDataMatrix{iScale}(:,1:nTemp-1));
            end

            nTempPrev = nTempPrev + nTemp - 1;
            nTemp = 1;
          end
        else
          nIgnored = nIgnored + 1;
          masterTM.(cycleNumber).Avg_geometry.(tomoList{iTomo})(iSubTomo, 26+iPeak*26) = -9999;
        end


      else
        nIgnored = nIgnored + 1;
        masterTM.(cycleNumber).Avg_geometry.(tomoList{iTomo})(iSubTomo, 26+iPeak*26) = -9999;

      end % end of ignore new particles

        end % end of loop over peaks
        
      end % end of ignore if statment
      if ~rem(iSubTomo,100)
        fprintf('\nworking on %d/%d subTomo peak %d/%d from %d/%d Tomo\n', ...
                                           iSubTomo, nSubTomos,iPeak+1,nPeaks, iTomo,nTomograms);

        fprintf('Total nExtracted = %d\n', nExtracted-1);
      end
    end % end of the loop over subTomos

  clear volumeData
  end % end of the loop over Tomograms,
  
% % %   volBinaryMask = reshape(gather(volBinaryMask),sizeMask);
  for iScale = 1:nScaleSpace
    masks.('binary').(stHALF).(sprintf('s%d',iScale)) = ...
      reshape(masks.('binary').(stHALF).(sprintf('s%d',iScale)),sizeMask);
  end
  

  masterTM.(cycleNumber).('newIgnored_PCA').(halfSet) = gather(nIgnored);
  
  subTomoMeta = masterTM;
  save(sprintf('%s.mat', pBH.('subTomoMeta')), 'subTomoMeta');

  for iScale = 1:nScaleSpace
    dataMatrix{iScale}(:,1+nTempPrev:nTemp-1+nTempPrev) = ...
                                    gather(tempDataMatrix{iScale}(:,1:nTemp-1));
  end

  clear tempDataMatrix
  % Get rid of any zero vals from newly ignored particles which are there due to
  % pre-allocation. Assuming no zeros have found their way in anywhere else which
  % would be a major problem.
  cleanIDX = (idxList~=0)';
  idxList = idxList(cleanIDX);
  peakList = peakList(cleanIDX);
  
  for iScale = 1:nScaleSpace
    dataMatrix{iScale} = dataMatrix{iScale}(:,1:size(idxList,2));
    % Center the rows
    for row = 1:size(dataMatrix{iScale},1)
     dataMatrix{iScale}(row,:) = dataMatrix{iScale}(row,:) -  mean(double(dataMatrix{iScale}(row,:)));                                
    end
  end

  
  

  %save('preparpoolSave.mat');
  try
    parpool(nCores);
  catch
    delete(gcp('nocreate'));
    parpool(nCores);
  end

  if (previousPCA)
    % Read the matrix of eigenvectors from the prior PCA.
    oldPca = load(previousPCA);
    U = oldPca.U;
    clear oldPca;
    for iScale = 1:nScaleSpace
      % Sanity checks on the dimensionality
      numEigs = size(U{iScale}, 2);
      if nPixels(iGold,iScale) ~= size(U{iScale}, 1)
        error('Image size %d does not match that of previous PCA %d!', nPixels(iGold,iScale), size(U{iScale},1));
      end

      coeffs{iScale} = U{iScale}' * dataMatrix{iScale}; 
    end
  else
    
    U = cell(nScaleSpace,1);
    V = cell(nScaleSpace,1);
    S = cell(nScaleSpace,1);
    coeffs = cell(nScaleSpace,1);
    varianceMap = cell(nScaleSpace,1);
    for iScale = 1:nScaleSpace

      % Calculate the decomposition
      [U{iScale},S{iScale},V{iScale}] = svd(dataMatrix{iScale}, 0);

      numNonZero = find(( diag(S{iScale}) ~= 0 ), 1, 'last');
      % For Method 1, save eigenvectors 1-4 (or user-specified max) as images
      eigsFound = min(maxEigs, numNonZero);

      fprintf('Found %d / %d non-zero eigenvalues in set %s.\n', numNonZero, size(S{iScale}, 1),halfSet);

      coeffs{iScale} = S{iScale} * V{iScale}' 

      % Can be GB-TB if calculated full
      %varianceMap{iScale} = (U{iScale}*S{iScale}.^2*V{iScale} ./ numel(U{iScale}-1));
      fprintf('Size S, %d %d  Size U %d %d \n', size(S{iScale},1),size(S{iScale},2), size(U{iScale},1),size(U{iScale},2));
  
      rightSide = S{iScale}(1:numNonZero,1:numNonZero).^2*U{iScale}';
      varianceMap = zeros(nPixels(iGold,iScale),1);
      for k = 1:nPixels(iGold,iScale)
        varianceMap(k) = U{iScale}(k,1)*rightSide(1,k) + ...
                         U{iScale}(k,2)*rightSide(2,k) + ...
                         U{iScale}(k,3)*rightSide(3,k);
      end
      tmpReshape = zeros(prod(sizeMask),1);
      tmpReshape(masks.('binary').(stHALF).(sprintf('s%d',iScale)) ) = varianceMap(:);
     
      fname = sprintf('%s_varianceMap%d-%s-%d.mrc',outputPrefix, eigsFound, halfSet, iScale);     
      SAVE_IMG(MRCImage(single(gather(reshape(tmpReshape, sizeMask)))), fname,pixelSize);


        
      eigList = cell(eigsFound,1);
      eigList_SUM = cell(eigsFound,1);
      
      for iEig = 1:eigsFound
        tmpReshape = zeros(prod(sizeMask),1);
        tmpReshape(masks.('binary').(stHALF).(sprintf('s%d',iScale)) ) = U{iScale}(:, iEig);
        eigenImage = reshape(tmpReshape, sizeMask);
        eigenImage = eigenImage - mean(eigenImage(masks.('binaryApply').(stHALF).(sprintf('s%d',iScale))));
        eigenImage = eigenImage ./rms(eigenImage(masks.('binaryApply').(stHALF).(sprintf('s%d',iScale)))).* masks.('binary').(stHALF).(sprintf('s%d',iScale)) ;
        eigList{iEig,1} = gather(eigenImage);
        eigList_SUM{iEig,1} = gather((eigenImage + avgFiltered{iGold, iScale} )./2);
      end


      [ eigMont ] = BH_montage4d(eigList, 'eigMont');
      [ eigMont_SUM ] = BH_montage4d(eigList_SUM, 'eigMont_SUM');
        fname = sprintf('%s_eigenImage%d-%s-mont_%d.mrc',outputPrefix, eigsFound, halfSet, iScale);
        fname_SUM = sprintf('%s_eigenImage%d-SUM-%s-mont_%d.mrc',outputPrefix, eigsFound, halfSet, iScale);
        SAVE_IMG(MRCImage(single(gather(eigMont))), fname,pixelSize);
        SAVE_IMG(MRCImage(single(gather(eigMont_SUM))), fname_SUM,pixelSize);


      % If requested, limit the number of principal components and coeffs saved
      if maxEigs < size(S{iScale}, 1)
        fprintf('Saving only the first %d principal components.\n',          ...
          maxEigs);
        if ~isempty(U{iScale}) % U will not exist for pcaMethods 2 or 3
          U{iScale} = U{iScale}(:, 1:maxEigs); 
        end
        if ~(previousPCA)
          S{iScale} = S{iScale}(1:maxEigs, 1:maxEigs); 
          V{iScale} = V{iScale}(:, 1:maxEigs); 
        end
        coeffs{iScale} = coeffs{iScale}(1:maxEigs, :); %
      end
    end
  end


  % Only U is needed for further analysis, so save only this, unless
  % troubleshooting.
  if (previousPCA)
    for iScale = 1:nScaleSpace
    
      % If requested, limit the number of principal components and coeffs saved.
      if maxEigs < size(U{iScale}, 2)
        fprintf('Saving only the first %d principal components.\n',          ...
          p.pcaMaxNumComponents);
        U{iScale} = U{iScale}(:, 1:maxEigs); 
        coeffs{iScale} = coeffs{iScale}(1:maxEigs, :); 
      end
      
    end
    save(sprintf('%s_%s_pcaFull.mat',outputPrefix,halfSet), 'nTOTAL', 'coeffs','idxList','peakList');
  else
    if (randomSubset)
      save(sprintf('%s_%s_pcaPart.mat',outputPrefix,halfSet),'U', 'idxList','peakList');
    else
      save(sprintf('%s_%s_pcaFull.mat',outputPrefix,halfSet), 'nTOTAL', 'coeffs','idxList','peakList');
    end
  end
  
  fprintf('Total execution time on %s set: %f seconds\n', halfSet, etime(clock, startTime));

  close all force; 
  %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%

clear dataMatrix U S V coeffs eigMont eigMontSum

delete(gcp('nocreate'));

% after resetting the device, bring back masks etc.


end % end of loop over halfsets
gpuDevice(1);
delete(gcp('nocreate'));
end % end of pca function


