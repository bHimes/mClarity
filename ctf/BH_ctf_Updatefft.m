function [  ] = BH_ctf_Updatefft( PARAMETER_FILE, STACK_PRFX, applyFullorUpdate)


global bh_global_do_2d_fourier_interp;

pBH = BH_parseParameterFile(PARAMETER_FILE);

flgSkipUpdate = 0;
% To avoid accidently masking any failures in subsequent update, clean out
% all stacks and reconstructions from the local cache.
flgShiftEucentric = 0;
try
  load(sprintf('%s.mat', pBH.('subTomoMeta')), 'subTomoMeta');
  mapBackIter = subTomoMeta.currentTomoCPR; 
catch
  mapBackIter = 0;
end

if isnan(str2double(STACK_PRFX))
  % It is a name, run here.
  nGPUs = 1;
  flgParallel = 0;
  STACK_LIST = {STACK_PRFX};
  ITER_LIST = {STACK_LIST};
else
  flgParallel = 1;

  updateCMD = sprintf('%s,%d,TiltAlignment,UpdateTilts,[%d,0,0],STD', ...
                                    PARAMETER_FILE,subTomoMeta.currentCycle, ...
                                    subTomoMeta.currentCycle);
 % fprintf('%s/n',updateCMD);
  nGPUs = pBH.('nGPUs');
  STACK_LIST_tmp = fieldnames(subTomoMeta.mapBackGeometry);
  STACK_LIST_tmp = STACK_LIST_tmp(~ismember(STACK_LIST_tmp,'tomoName'));
  ITER_LIST = cell(nGPUs,1);
  nST = 1; STACK_LIST = {};
  for iStack = 1:length(STACK_LIST_tmp)
    if subTomoMeta.mapBackGeometry.(STACK_LIST_tmp{iStack}).nTomos
      STACK_LIST{nST} = STACK_LIST_tmp{iStack};
      nST = nST +1;
    end
  end
  clear STACK_LIST_tmp
  for iGPU = 1:nGPUs
    ITER_LIST{iGPU} = STACK_LIST(iGPU:nGPUs:length(STACK_LIST));
  end
end

eucShiftsResults = 0;
if strcmpi(applyFullorUpdate, 'fullScale')
  eucShiftsResults = cell(size(ITER_LIST));
end
% BH_geometryAnalysis(sprintf('%s',PARAMETER_FILE),sprintf('%d',subTomoMeta.currentCycle),'TiltAlignment','UpdateTilts',sprintf('[%d,0,0]',subTomoMeta.currentCycle),'STD')
try
  conserveDiskSpace = pBH.('conserveDiskSpace');
catch
  conserveDiskSpace = 0;
end

try
  ppool = parpool(nGPUs);
catch
  delete(gcp('nocreate'));
  ppool = parpool(nGPUs);
end

% For some reason matlab was geeking out about calling this in the parfor
% loop, getting confused about whether it is a variable or a function.
recGeomForThickness = subTomoMeta.reconGeometry;

parfor iGPU = 1:nGPUs
  for iTilt = 1:length(ITER_LIST{iGPU})
    
  if ( flgParallel )
    useGPU = iGPU;
    gDev = gpuDevice(useGPU);
  else
    useGPU = BH_multi_checkGPU(-1);
    gDev = gpuDevice(useGPU);
  end
  STACK_PRFX = ITER_LIST{iGPU}{iTilt};

      
% Assuming that mapBackIter > 0 since we are updating
if (mapBackIter)
  mapBackPrfx = sprintf('mapBack%d/%s_ali%d_ctf',mapBackIter,STACK_PRFX,mapBackIter)
  flgInitResample = 0;
  flgCombine = 1;
else
  flgInitResample = 1;
  flgCombine = 0;
  % If this isn't initialized the parallel pool takes a shit.
  mbEST = '';
end

if strcmpi(applyFullorUpdate, 'full')
  % Combine old and new transformations and apply as well as erasing beads,
  % e.g. go from raw stack to preCTF.
  flgSkipErase = 0;
  flgShiftEucentric=0;
  flgApplyFullXform = 1;
  PRJ_STACK ={sprintf('fixedStacks/%s.fixed',STACK_PRFX)}
  PRJ_OUT = {sprintf('%s_ali%d',STACK_PRFX,mapBackIter+1)}
  PRJ_OLD = sprintf('%s_ali%d',STACK_PRFX,mapBackIter);
  outputDirectory = 'aliStacks' 
elseif strcmpi(applyFullorUpdate, 'fullScale')
  % Combine old and new transformations and apply as well as erasing beads,
  % e.g. go from raw stack to preCTF.
  
  % Also remove shifts due to the sample being non-eucentric. This is a
  % test, and if it helps, it would be even better to just apply this shift
  % to all the subtomos pre-emptivel.
  flgShiftEucentric = 1;
  flgSkipErase = 0;
  flgApplyFullXform = 1;
  PRJ_STACK ={sprintf('fixedStacks/%s.fixed',STACK_PRFX)}
  PRJ_OUT = {sprintf('%s_ali%d',STACK_PRFX,mapBackIter+1)}
  PRJ_OLD = sprintf('%s_ali%d',STACK_PRFX,mapBackIter);
  
  outputDirectory = 'aliStacks';
elseif strcmpi(applyFullorUpdate, 'refine')
  
  % Don't combine, just use tlt with new defocus values and erase beads
  flgSkipErase = 0;
  flgApplyFullXform = 1;
  flgCombine = 0;
  PRJ_STACK ={sprintf('fixedStacks/%s.fixed',STACK_PRFX)}
  PRJ_OUT = {sprintf('%s_ali%d',STACK_PRFX,mapBackIter+1)}
  PRJ_OLD = sprintf('%s_ali%d',STACK_PRFX,mapBackIter);
  
  
  outputDirectory = 'aliStacks';
elseif strcmpi(applyFullorUpdate,'update')
  % Combine old and new transformations, but only apply the new xform and
  % don't erase beads. e.g. in inital binned mapback just update the tilt
  % files and resample the ctfCorrected stack.
  flgSkipErase = 1;
  flgApplyFullXform = 0;
  PRJ_STACK ={sprintf('ctfStacks/%s_ali%d_ctf.fixed',STACK_PRFX,mapBackIter+flgInitResample)}
  PRJ_OUT = {sprintf('%s_ali%d_ctf',STACK_PRFX,mapBackIter+1)}
  PRJ_OLD = sprintf('%s_ali%d_ctf',STACK_PRFX,mapBackIter);
  
  outputDirectory = 'ctfStacks';
else
 
  error('applyFullorUpdate should be [full], [fullScale] or [update]')
end

try
  tlt = {sprintf('fixedStacks/ctf/%s_ali%d_ctf_refine.tlt',STACK_PRFX,mapBackIter+flgInitResample)};
  load(tlt{1});
catch
  tlt = {sprintf('fixedStacks/ctf/%s_ali%d_ctf.tlt',STACK_PRFX,mapBackIter+flgInitResample)};
end
tlt_OUT = {sprintf('fixedStacks/ctf/%s_ali%d_ctf.tlt',STACK_PRFX,mapBackIter+1)};

eraseStack = sprintf('rm cache/%s_*.fixed',STACK_PRFX);
eraseRec   = sprintf('rm cache/%s_*.rec',STACK_PRFX);
% Converte bead diameter to pixels and add a little to be safe.
PIXEL_SIZE = pBH.('PIXEL_SIZE');
SuperResolution = pBH.('SuperResolution');

% Don't apply any fourier cropping of super-res data if only updating,
% as it would already be done.
if strcmpi(applyFullorUpdate,'update')
  SuperResolution = 0;
end

if (SuperResolution)
  % Transform the raw images at full sampling then crop the fft to physical
  % nyquist
  PIXEL_SIZE = 2.* PIXEL_SIZE;
end


eraseSigma = 3;%pBH.('beadSigma');

eraseRadius = ceil(1.2.*(pBH.('beadDiameter')./PIXEL_SIZE.*0.5));
flgImodErase = 0

        % FIXME, this should be stored from previous mask calc and accessed there.
      % For now just take based on tomogram (which will be larger than the true specimen thickness)
      %THICKNESS = recGeomForThickness.(sprintf('%s_1',STACK_PRFX));
      %THICKNESS = min(10,abs(THICKNESS(1,3)-THICKNESS(2,3)).*PIXEL_SIZE.*10^9);
      THICKNESS = 10;
% Assuming all extreme pixels have already been removed from the stack.
%PRJ_STACK = {sprintf('%s_local04_18.mrc',mjIDX)};%,sprintf('%s_local14_18.mrc',mjIDX),sprintf('%s_local24_18.mrc',mjIDX),sprintf('%s_local34_18.mrc',mjIDX)};
nStacks = length(tlt);
INPUT_CELL = cell(nStacks,7);
TLT_Trans = cell(nStacks,1);

% killed the loop, clean up later
i=1;
if exist(tlt{i}, 'file') &&  exist(PRJ_STACK{i}, 'file')
  INPUT_CELL{i,1} = load(tlt{i});
  INPUT_CELL{i,2} = PRJ_STACK{i};
  [pathName,fileName,extension] = fileparts(PRJ_STACK{i});
  if isempty(pathName)
    pathName = '.';
  end
  [ctfPath,~,~] = fileparts(tlt{i});
  INPUT_CELL{i,3} = pathName;
  INPUT_CELL{i,4} = fileName;
  INPUT_CELL{i,5} = extension;
  INPUT_CELL{i,6} = PRJ_OUT{i};
  INPUT_CELL{i,7} = ctfPath;
else
  if ~exist(tlt{i}, 'file')
    fprintf('\nignoring %s, because the file is not found.\n', tlt{i});
  end
  if ~exist(PRJ_STACK{i}, 'file')
    fprintf('\nignoring %s, because the file is not found.\n',PRJ_STACK{i});
  end

end

  
% killed the loop, clean up later
iStack=1;



  iMrcObj = MRCImage(INPUT_CELL{iStack,2},0);

  % The pixel size should be previously set correctly, but if it is not, then we
  % must maintain whatever is there in case beads are to be erased. The model
  % used for this process depends on the pixel size in the header when it was
  % created in IMod alignment.
%   [~,iPixelHeader] = system(sprintf('header -pixel %s',INPUT_CELL{iStack,2}));
%   iPixelHeader = str2num(iPixelHeader);
  iHeader = getHeader(iMrcObj);
  iPixelHeader = [iHeader.cellDimensionX/iHeader.nX .* (1+abs(SuperResolution)), ...
                  iHeader.cellDimensionY/iHeader.nY .* (1+abs(SuperResolution)), ...
                  iHeader.cellDimensionZ/iHeader.nZ];
                
  iOriginHeader= [iHeader.xOrigin , ...
                  iHeader.yOrigin , ...
                  iHeader.zOrigin ] ./ (1+abs(SuperResolution));

  d1 = iHeader.nX; d2 = iHeader.nY; d3 = size(INPUT_CELL{iStack,1},1);%iHeader.nZ;
  
 osX = 1-mod(d1,2); osY = 1-mod(d2,2);
  
if (SuperResolution)
  gradientAliasMask = BH_bandpass3d(1.*[d1-osX,d2-osY,1],0,0,-0.235,'GPU','nyquistHigh');
else
  gradientAliasMask = BH_bandpass3d(1.*[d1-osX,d2-osY,1],0,0,0,'GPU','nyquistHigh');
end

TLT = INPUT_CELL{iStack,1};
pathName = INPUT_CELL{iStack,3}
fileName = INPUT_CELL{iStack,4}
extension = INPUT_CELL{iStack,5} 

% Copy with column for defocus = input to CTF correct
% saved as <filename>_ctf.tlt


nPrjs = size(TLT,1);



% Optionally address magnification changes.
% system(sprintf('mkdir -p %s/recon',INPUT_CELL{i,3}));
system('mkdir -p aliStacks');
 
  if (flgCombine)
    fprintf('Combining tranformations\n\n');
    % Load in the mapBack alignment
    mbEST = load(sprintf('%s.tltxf',mapBackPrfx));
    mbTLT = load(sprintf('%s.tlt',mapBackPrfx));
    defShifts = sprintf('%s.defShifts',mapBackPrfx);
    if exist(defShifts,'file')
      defShifts = load(defShifts);
      fprintf('Updating defocus shifts from tomoCPR\n');
    else
      defShifts = 0;
      fprintf('Did not find updated defocus estimate from tomoCPR\n');
    end
  end
  
  if ( flgShiftEucentric )
    % For now take the mean, but it would probably be better to fit a line,
    % use the Y intercept, and use the deviation from 0 of the slope as a
    % measure of quality.
    fprintf('\n\nYou suspect a eucentric drift\n\n')
    mbEST(:,5)
    eucShift = mbEST(:,5) ./ sind(mbTLT);
    
    eucShift = eucShift(isfinite(eucShift))
    if isempty(eucShift)
      fprintf('All non-finite entries in the eucentric shift estimate\n');
      eucShift = 0;
    else
      eucShift = mean(eucShift);
    end
%     mbEST(:,5) = mbEST(:,5) - eucShift.*sind(mbTLT);
    fprintf('\n\nFound a possible eucentric shift of %f\n\n',eucShift);
%     mbEST(:,5)
    eucShiftsResults{iGPU}{iTilt} = eucShift;

  end
  outputStackName = sprintf('%s/%s%s',outputDirectory,INPUT_CELL{iStack,6},INPUT_CELL{iStack,5});
  oldStackName = sprintf('%s/%s%s',outputDirectory,PRJ_OLD,INPUT_CELL{iStack,5});
  if exist(sprintf('fixedStacks/%s.erase',fileName),'file')
    flgEraseBeads = 1;
    % create and later run a script to erase gold beads using imods
    % ccderaser and the present fiducial model.



  else
    flgEraseBeads = 0;
  end

  


  


    SIZEOUT = [d1,d2];





  tlt_tmp = cell(d3,1);
  out_tmp = cell(d3,1);
  


  origOrder = TLT(:,1);
  TLT = sortrows(TLT,1);


  for i = 1:d3
    tlt_tmp{i} = TLT(i,:);
  end



  if (flgSkipUpdate)
    continue
  end

  if (SuperResolution)
    % Forcing output to odd size.
    sizeCropped = floor([d1,d2,d3]./2)-(1-mod(floor([d1,d2,d3]./2),2));
  else
    sizeCropped = [d1,d2,d3]-(1-mod([d1,d2,d3],2));
  end
  sizeCropped(3) = d3; 
  
 STACK = zeros(sizeCropped,'single');
 samplingMaskStack = zeros(sizeCropped,'uint8');
 
  for i = 1:d3





  if (SuperResolution)
    % The transform shifts need to be scaled by 2 since the stored values
    % are relative to full sampling, while the tomoCPR are relative to
    % physical pixel size.
    updateScale = 2;
  else
    updateScale = 1;
  end

  if (flgCombine)

    % Stored in row order as output by imod, st transpose is needed. Inversion
    % of the xform is handled in resample2d.
    origXF = reshape(tlt_tmp{i}(7:10),2,2)';
     newXF = reshape(mbEST(i,1:4),2,2)';


    dXYZ  = [(newXF*tlt_tmp{i}(2:3)')' + mbEST(i,5:6).*updateScale , 0];
    if ~isvector(dXYZ)
      % In case some implicit expansion were to happen for whatever reason.
      error('dXYZ is a matrix and should be a vector');
    end
    tlt_tmp{i}(2:3) = dXYZ(1:2);
    


    combinedXF = reshape((newXF*origXF)',1,4);
    tlt_tmp{i}(7:10) = combinedXF;
  else
    combinedXF = tlt_tmp{i}(7:10);
    dXYZ = [tlt_tmp{i}(2:3),0];
  end

    % Now that we are always cropping prior to transforming, reduce the
    % scale. Probable should just instruct to fourier crop prior to tilt
    % alignment.flgSkipUpdate
    dXYZ = dXYZ ./ updateScale;
  
 
 

  

 
  
  
  % Pad the projection prior to xforming in Fourier space.
  if (SuperResolution)
    
    iProjection = single(getVolume(iMrcObj,-1,-1,tlt_tmp{i}(23),'keep'));
    iProjection = real(ifftn(fftn(iProjection).*gradientAliasMask));
    
    % Information beyond the physical nyquist should be removed to limit
    % aliasing of noise prior tto interpolation.
    iProjection = BH_padZeros3d(iProjection,[0,0],[0,0],'GPU','singleTaper',mean(iProjection(:)));
    trimVal = BH_multi_padVal(1.*size(iProjection),sizeCropped(1:2));
 
         largeOutliersMean= mean(iProjection(:));
     largeOutliersSTD = std(iProjection(:));
     largeOutliersIDX = (iProjection < largeOutliersMean - 6*largeOutliersSTD | ...
                         iProjection > largeOutliersMean + 6*largeOutliersSTD);
     iProjection(largeOutliersIDX) = (3*largeOutliersSTD).*randn([gather(sum(largeOutliersIDX(:))),1],'single','gpuArray');
     
    iProjection = real(ifftn(ifftshift(...
                               BH_padZeros3d(fftshift(...
                                             fftn(iProjection)), ...
                                             trimVal(1,:),trimVal(2,:),...
                                             'GPU','single'))));  
       
                             
    iSamplingMask = BH_resample2d(ones(sizeCropped(1:2),'single','gpuArray'),[0,0,0],[0,0],'Bah','GPU','forward',1/2,sizeCropped(1:2));
    sizeODD = size(iProjection)-[osX,osY];
  else
    sizeODD = [d1,d2]-[osX,osY];
    
    
    % If it is even sized, shift up one pixel so that the origin is in the middle
    % of the odd output here we can just read it in this way, unlike super res.
     
     iProjection = ...
                 single(getVolume(iMrcObj,[1+osX,d1],[1+osY,d2],tlt_tmp{i}(23),'keep'));
     iProjection = real(ifftn(fftn(iProjection).*gradientAliasMask));         
     largeOutliersMean= mean(iProjection(:));
     
     largeOutliersSTD = std(iProjection(:));
     largeOutliersIDX = (iProjection < largeOutliersMean - 6*largeOutliersSTD | ...
                         iProjection > largeOutliersMean + 6*largeOutliersSTD);
     iProjection(largeOutliersIDX) = (3*largeOutliersSTD).*randn([gather(sum(largeOutliersIDX(:))),1],'single');
                  

  end
  
  % Because the rotation/scaling and translation are done separately,
  % we must use a square transform; otherwise, a rotation angle dependent
  % anisotropic distortion (like mag distortion) is introduced.
    sizeSQ = floor(([1,1]+bh_global_do_2d_fourier_interp).*sizeODD);
    padVal  = BH_multi_padVal(sizeODD,sizeSQ);
    trimVal = BH_multi_padVal(sizeSQ,sizeCropped(1:2));
     
    iProjection = iProjection - mean(iProjection(:));

  if ( SuperResolution )
    iProjection = BH_padZeros3d(iProjection(1+osX:end,1+osY:end), ...
                            padVal(1,:),padVal(2,:),'GPU','singleTaper');
  else
    iProjection = BH_padZeros3d(iProjection,padVal(1,:),padVal(2,:), ...
                                                    'GPU','singleTaper');
  end

  if (i == 1 && bh_global_do_2d_fourier_interp)
    bhF = fourierTransformer(iProjection);
  end
    

  if (flgApplyFullXform)
     % Do the phase shift after rotating - need to invert the scaling since
     % we are in reciprocal space
     [imodMAG, imodStretch, imodSkewAngle, imodRot] = ...
                                           BH_decomposeIMODxf(combinedXF);
     % Assuming stretch and skew are not fit, leave defined for possible
     % later consideration.
     

     if (bh_global_do_2d_fourier_interp)
       if (i == 1)
         fprintf('resampling at 2x padding with fourier interp\n');
       end
      combinedInverted = BH_defineMatrix([imodRot,0,0],'Bah','forward').*(1/imodMAG);
      combinedInverted = combinedInverted([1,2,4,5]);
      
      iProjection = BH_resample2d(iProjection,combinedInverted,dXYZ(1:2),'Bah','GPU','forward',imodMAG,size(iProjection),bhF);
     else
       if (i == 1)
         fprintf('resampling at 1x padding with linear interp\n');
       end
       % Real space, do not invert mag
        combinedInverted = BH_defineMatrix([imodRot,0,0],'Bah','forward').*(imodMAG);
        combinedInverted = combinedInverted([1,2,4,5]);
       iProjection = BH_resample2d(iProjection,combinedInverted,dXYZ(1:2),'Bah','GPU','forward',1.0,size(iProjection));
     end

     iSamplingMask = BH_resample2d(ones(sizeCropped(1:2),'single','gpuArray'),combinedXF,dXYZ(1:2),'Bah','GPU','forward',1.0,sizeCropped(1:2),NaN);
          
  else
     [imodMAG, imodStretch, imodSkewAngle, imodRot] = ...
                                           BH_decomposeIMODxf(mbEST(i,1:4));
     % Assuming stretch and skew are not fit, leave defined for possible
     % later consideration.

     % NOTE mag is ignored when the rotation matrix has 4 elements (IMOD)
    
      if (bh_global_do_2d_fourier_interp)
       if (i == 1)
         fprintf('resampling at 2x padding with fourier interp\n');
       end
        mbEstInverted = BH_defineMatrix([imodRot,0,0],'Bah','forward').*(1/imodMAG);
        mbEstInverted = mbEstInverted([1,2,4,5]);
        iProjection = BH_resample2d(iProjection,mbEstInverted,dXYZ(1:2),'Bah','GPU','forward',imodMAG,size(iProjection),bhF);
      else
       if (i == 1)
         fprintf('resampling at 1x padding with linear interp\n');
       end
        mbEstInverted = BH_defineMatrix([imodRot,0,0],'Bah','forward').*(imodMAG);
        mbEstInverted = mbEstInverted([1,2,4,5]);
        iProjection = BH_resample2d(iProjection,mbEstInverted,dXYZ(1:2),'Bah','GPU','forward',1.0,size(iProjection));
      end
     iSamplingMask = BH_resample2d(ones(sizeCropped(1:2),'single','gpuArray'),mbEST(i,1:4),dXYZ(1:2),'Bah','GPU','forward',1.0,sizeCropped(1:2),NaN);                     
  end
  

    
      STACK(:,:,i)  = gather(real(BH_padZeros3d(iProjection, ...
                                             trimVal(1,:),trimVal(2,:),...
                                             'GPU','single')));
                                           
      iSamplingMask(isnan(iSamplingMask(:))) = 0;
      samplingMaskStack(:,:,i) = uint8(gather(real(iSamplingMask)));
      iSamplingMask = [];
%      
%   end
             
  end

  

 
  for i= 1:d3
    TLT(i,:) = tlt_tmp{i};
%     STACK(:,:,TLT(i,1)) = out_tmp{i};
  end

  out_tmp = [];
  
  if (flgCombine)
    % Update the tilt angles
    TLT(:,4) = mbTLT;
    if (defShifts)
      TLT(:,15) = TLT(:,15) + defShifts;
      TLT(:,16) = PIXEL_SIZE;
    end
  

      % Sort descending along the magnitude of the tilt angles because higher tilts take
      % longer on CTF correction. If more processor available than projections,
      % this doesn't affect anything.
      [~, idx] = sortrows(abs(TLT(:,4)), -1);
      TLT = TLT(idx,:);
      % number in stack, dx, dy, tilt angle, projection rotation, tilt azimuth, tilt
      % elevation, e1,e2,e3, dose number (order in tilt collection), offsetX, offsetY
      % scaleFactor, defocus, pixelSize, CS, Wavelength, Amplitude contrast
      
      sprintf('%s/%s.tlt',INPUT_CELL{iStack,7},INPUT_CELL{iStack,6})
      fileID = fopen(tlt_OUT{iStack}, 'w');
      fprintf(fileID,['%d\t%08.2f\t%08.2f\t%07.3f\t%5e\t%5e\t%07.7f\t%07.7f\t',...
               '%07.7f\t%07.7f\t%5e\t%5e\t%5e\t%7e\t%5e\t%5e\t%5e\t%5e\t%5e\t',...
               '%d\t%d\t%d\t%3.2f\n'], TLT');
             

    if ( flgEraseBeads  )    
      beadList = importdata(sprintf('fixedStacks/%s.erase2',fileName));
      beadList(:,1:2) = beadList(:,1:2) ./ updateScale;
      [ STACK ] = BH_eraseBeads(STACK,eraseRadius, beadList);

    end


      
      fprintf('Using an estimated thickenss of %3.3f nm for tilt-series %s\n',...
               THICKNESS, STACK_PRFX);
             
      [ STACK ] = BH_multi_loadAndMaskStack(STACK,TLT,'',THICKNESS,PIXEL_SIZE*10^10,samplingMaskStack);
      SAVE_IMG(MRCImage(STACK),outputStackName,iPixelHeader,iOriginHeader);
      SAVE_IMG(MRCImage(samplingMaskStack),sprintf('%s.samplingMask',outputStackName));
      
     xShift= []; yShift = []; scale = []; angleShift = [];
     dZ = [];  recZ= []; rotMat = []; angX = []; angY = [];             
  else
    
    if ( flgEraseBeads )
        beadList = importdata(sprintf('fixedStacks/%s.erase2',fileName));
        beadList(:,1:2) = beadList(:,1:2) ./ updateScale;
        STACK = BH_eraseBeads(STACK,eraseRadius, beadList);
    end 


      
      fprintf('Using an estimated thickenss of %3.3f nm for tilt-series %s\n',...
               THICKNESS, STACK_PRFX);
             
      [ STACK ] = BH_multi_loadAndMaskStack(STACK,TLT,'',THICKNESS,PIXEL_SIZE*10^10,samplingMaskStack);
      SAVE_IMG(MRCImage(STACK),outputStackName,iPixelHeader,iOriginHeader);
      SAVE_IMG(MRCImage(samplingMaskStack),sprintf('%s.samplingMask',outputStackName),iPixelHeader,iOriginHeader);

  end
  if (mapBackIter && conserveDiskSpace)
    system(sprintf('rm %s',oldStackName));
  end

  
  % Once updated the reconstructions are no longer valid
  system(eraseStack);
  system(eraseRec);
  end % end of loop over tilts
end % end of par for loop


% 
if iscell(eucShiftsResults)
  % Update the sub tomo z coords with an estimate of the shift
  for iGPU = 1:nGPUs
  
    for iTilt = 1:length(ITER_LIST{iGPU})  
     
      STACK_PRFX = ITER_LIST{iGPU}{iTilt}
      eucShift = eucShiftsResults{iGPU}{iTilt}
  
      for jTomo = 1:subTomoMeta.mapBackGeometry.(STACK_PRFX).nTomos
        if any(subTomoMeta.mapBackGeometry.(STACK_PRFX).coords(jTomo,:))
          fprintf('shifting %s_%d\n',STACK_PRFX,jTomo);
          subTomoMeta.(sprintf('cycle%0.3d',subTomoMeta.currentCycle)).RawAlign.(sprintf('%s_%d',STACK_PRFX,jTomo))(:,13) = ...
          eucShift + subTomoMeta.(sprintf('cycle%0.3d',subTomoMeta.currentCycle)).RawAlign.(sprintf('%s_%d',STACK_PRFX,jTomo))(:,13);

        end
      end
    end
  end
  save(sprintf('%s.mat', pBH.('subTomoMeta')), 'subTomoMeta');
end
    
if ( flgParallel )
  fprintf('\nAuto updating the tilt geometry\n');
 % BH_geometryAnalysis(updateCMD)
 BH_geometryAnalysis(sprintf('%s',PARAMETER_FILE),sprintf('%d',subTomoMeta.currentCycle),'TiltAlignment','UpdateTilts',sprintf('[%d,0,0]',subTomoMeta.currentCycle),'STD');
else
  fprintf('\n\nSince you are updating each tilt series manually, you must');
  fprintf(' run\nemClarity geometry [param] [cycle] TiltAlignment UpdateTilts [cycle,0,0] STD\n\n');
end

 
