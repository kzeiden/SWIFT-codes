%% Reprocess SWIFT v4 signature velocities from burst data
%   Loops through burst MAT or DAT files for a given SWIFT deployment,
%   reprocessing signature data

%   QC/Process Steps:
%     HR Processing:
%       1. De-spike vertical velocity 2. NaN data w/low cor + amp 3.
%       Identify if instrument was out of water using cor & amp min 4.
%       Compute dissipation w/inertial subrange method (Tennekes '75) 5.
%       Structure function dissipation (?) 6. Average to get w profile

%     Broadband Processing:
%       1. Average to get velocity profiles 2. trim based on altimeter

%     Echo Sounder Processing
%       1. Re-scale?

%   Replace values in the SWIFT data structure of results (from onboard
%   processing)

%      J. Thomson, Sept 2017 (modified from AQH reprocessing)
%       7/2018, fix bug in the burst time stamp applied 4/2019, apply
%       altimeter results to trim profiles
%               and plot echograms, with vertical velocities
%       12/2019 add option for spectral dissipation,
%               with screening for too much rotational variance
%       Sep 2020 corrected bug in advective velocity applied to spectra Nov
%       2021 clean up and add more plotting for burst, avg, and echo Feb
%       2022 (K. Zeiden)
%         1. Cleaned up vestigial code (for readability) 2. New
%         out-of-water flag based on step functions in temp + press 3.
%         Method for flagging fish based on PDFs of amplitude and
%         correlation 4. Identify bad pings + bad bins, but only QC using
%         bad pings, bad bins + fish.
%               Include flag for bad bins in SWIFT structure for user
%               choice.
%         5. Include variance as well as average E+N profiles (similar to
%         w). 6. Toggle figure creation + saving. 7. Modular directories.
%       Jul 2022 (K. Zeiden)
%         1. Plots all SWIFT burst average velocity data after processing
%         is completed 2. Saves standard error (sigma_U/sqrt(N)) 3. No
%         longer saves QC flags -- user can evaluate based on standard
%         error after QC. 4. Switch to a QC toggle: user can use standard
%         amp & corr to remove bad pings + bad bins, and/or individual
%         data, and/or fish. Gives warning if standard error is increased
%         by applying the QC.
%       Aug 2022(K. Zeiden)
%            1. Add toggle to save new SWIFT structure or not 
%            2. Removed any "continue" statements
%               -> might want burst plots for post-mortem even if data is bad
%            3. Variables have been renamed (for typing efficiency mostly,
%                   and seem more inutitive)
%            4. Added test to see if QC reduced the standard error. If not,
%                   relace with non-qc values
%            5. Add toggle to also/istead save burst-averaged signature data 
%                   in a separate structure with analagous format to SWIFT structure  
%                   (SIG structure, see catSIG as well for plotting the structure)
%                   motivated by missing data in SWIFT structure due to no timestamp match)
%            6. Add maximum velocity error to flag bad bursts (i.e. out of water)
%            7. Added toggle to save burst-averaged amp, corr & gyro
%       Sep 2022 (K. Zeiden)
%           1. updated dissipation estimate with new structure function
%                   methodology
%       Jan 2023 (K. Zeiden)
%           1. updated QC to de-spike HR velocity always, still optional to
%                   remove entire bad pings and bins
%           2. separated QC of bad pings and bad bins -- can remove entire
%                   bad pings and still get an averge, but bad bins removes entire
%                   average. Better to leave to post-processing
%           3. Remove amplitude thresholds -- amp has arbitrary bias. Amp
%                   still used in fish detection, b/c that is based on distribution
%                   of amplitude values in a burst.
%       Feb 2023 (K. Zeiden)
%           1. Re-added readSWIFTv4_SIG w/option to read-in raw burst files

%% User Defined Inputs

% Directory with existing SWIFT structures (e.g. from telemetry)
swiftstructdir = './';
% Directory with signature burst mat files 
burstmatdir = './';% 
% Directory with signature burst dat files 
burstdatdir = './';
% Directory to save updated/new SWIFT structure (see toggle 'savenewSWIFT')
savestructdir = [ swiftstructdir ];
% Directory to save figures (will create folder for each mission if doesn't already exist)
savefigdir = './';

% Plotting/Saving Toggles
plotburst = false; % generate plots for each burst
plotmission = true; % generate summary plot for mission
saveplots = false; % save generated plots
readraw = true;% read raw binary files
trimalt = false; % trim data based on altimeter
saveSWIFT = false;% overwrites original structure with new SWIFT data
saveSIG = false; %save burst averaged sig data separately

% User defined processing parameters
xcdrdepth = 0.2; % depth of transducer [m]
mincor = 50; % correlation cutoff, 50 is max value recorded in air (30 if single beam acq)
maxavgerr = 0.02; % max avg velocity error (m/s)
pbadmax = 80; % maximum percent 'bad' amp/corr/err values per bin or ping allowed (see QC toggles below)

% QC Toggles
QCcorr = false;% (NOT recommended) standard, QC removes any data below 'mincor'
QCbin = false;% QC entire bins with greater than pbadmax perecent bad correlation 
QCping = false; % QC entire ping with greater than pbadmax percent bad correlation
QCfish = true;% detects fish from highly skewed amplitude distributions in a depth bin 

%Populate list of V4 SWIFT missions to re-process (signature data)
cd(burstmatdir)
swifts = dir('SWIFT*');
swifts = {swifts.name};
nswift = length(swifts);

%% Loop through SWIFT missions
% For each mission, loop through burst files and process the data
clear SWIFT SIG

for iswift = 1:nswift
    
    SNprocess = swifts{iswift}; 
    disp(['********** Reprocessing ' SNprocess ' **********'])
    
    %Load pre-existing mission mat file with SWIFT structure 
    structfile = dir([swiftstructdir  SNprocess ]);
    if length(structfile) > 1
    %    structfile = structfile(contains({structfile.name},'SIG')); %?
    end 
    load(structfile.name)
    % Create SIG structure
    SIG = struct;
    
    if readraw
        bfiles = dir([burstdatdir '/SIG/Raw/*/*.dat']);
        if isempty(bfiles)
            disp('   No burst dat files found...')
%             continue
        end
    else
        bfiles = dir([burstmatdir  '/SIG/Raw/*/*.mat']);
        if isempty(bfiles)
            disp('   No burst mat files found...')
%             continue
        end
    end
    nburst = length(bfiles);
    
        for iburst = 1:nburst
            
            % Load burst mat file
            if readraw
                cd(bfiles(iburst).folder)
                [burst,avg,battery,echo] = readSWIFTv4_SIG(bfiles(iburst).name);
            else
            load(bfiles(iburst).name)
            end

            % Burst time stamp
            day = bfiles(iburst).name(13:21);
            hour = bfiles(iburst).name(23:24);
            mint = bfiles(iburst).name(26:27);
            btime = datenum(day)+datenum(0,0,0,str2double(hour),(str2double(mint)-1)*12,0);
            bname = bfiles(iburst).name(1:end-4);
            disp(['Burst ' num2str(iburst) ' : ' bname])
            
            % Broadband Data
            avgtime = avg.time;
            avgamp = avg.AmplitudeData;
            avgcorr = avg.CorrelationData;
            avgvel = avg.VelocityData;
            avgtemp = avg.Temperature;
            avgtemp = filloutliers(avgtemp,'linear');
            avgpress = avg.Pressure;
            avgz = xcdrdepth + avg.Blanking + avg.CellSize*(1:size(avg.VelocityData,2));
            [~,nbin,~] = size(avgvel);
            
            % HR Data
            hrtime = burst.time;
            hrcorr = burst.CorrelationData';
            hramp = burst.AmplitudeData';
            hrvel = -burst.VelocityData';
            hrz = xcdrdepth + burst.Blanking + burst.CellSize*(1:size(burst.VelocityData,2));
                        
            % Flag if file is too small
            if bfiles(iburst).bytes < 1e6 % 2e6,
                disp('   FLAG: Bad-file (small file)...')
                smallfile = true;
            else
                smallfile = false;
            end      
            
            %Flag if coming in/out of the water
            if any(ischange(burst.Pressure)) && any(ischange(burst.Temperature))
                disp('   FLAG: Out-of-Water (temp/pressure change)...')
                outofwater = true;
            else
                outofwater = false;
            end  
            
            % Flag out of water based on bursts w/low amp
            badamp =  squeeze(nanmean(avgamp)) < 40;
            if any(100*sum(badamp)/nbin > pbadmax)
                if ~outofwater
                disp('   FLAG: Out-of-water (high average amp)...')
                end
                outofwater = true;
            end                 
            
            % Flag out of water based on bursts w/low cor
            badcorr = squeeze(mean(avgcorr,'omitnan')) < 50;
            if any(100*sum(badcorr)/nbin > pbadmax)
                if ~outofwater
                disp('   FLAG: Out-of-water (high average corr)...')
                end
                outofwater = true;
            end 
            
            % Flag out of water based on bursts with high velocity error
            baderr = std(avgvel(:,:,1),[],1,'omitnan') > 0.5;
            if any(100*sum(baderr)./nbin > pbadmax)
                if ~outofwater
                disp('   FLAG: Out-of-water (high burst error)...')
                end
                outofwater = true;
            end 
            
            % Determine Altimeter Distance
            if isfield(avg,'AltimeterDistance') && trimalt
                maxz = median(avg.AltimeterDistance);
            else
                maxz = inf;
            end
            
%%%%%%%%%%%%%%% QC Broadband velocity data ('avg' structure) %%%%%%

            % Raw velocity profiles & standard error
            nping = length(avgtime);
            nbin = length(avgz);
            avgu_noqc = squeeze(nanmean(avgvel,1));
            avguerr_noqc = squeeze(nanstd(avgvel,[],1))/sqrt(nping);
            
            % QC: flag corr minimum values
            badcorr = avgcorr < mincor;
            badbin = squeeze(nansum(badcorr,1)./nping > pbadmax/100); %#ok<*NANSUM>
            badbin = permute(repmat(badbin,1,1,nping),[3 1 2]);
            badping = squeeze(sum(badcorr,2)./nbin > pbadmax/100);
            badping = permute(repmat(badping,1,1,nbin),[1 3 2]);
            
            % QC: flag fish w/ anomalously high amplitude: look for heavily skewed distributions
            badfish = false(size(avgamp));
            for ibeam = 1:4
                for ibin = 1:nbin
                    [a,b] = hist(squeeze(avgamp(:,ibin,ibeam)));
                    if sum(a) == 0
                        continue
                    end
                    [~,j] = max(a);
                    if j == 1
                        ampfloor = b(1)+5;
                        badfish(:,ibin,ibeam) = avgamp(:,ibin) > ampfloor;
                    end
                end
            end
            
            % QC broadband data and recompute velocity profiles & SE
            iQC = false(size(avgvel));
            if QCcorr; iQC(badcorr) = true; end%#ok<*UNRCH>
            if QCbin; iQC(badbin) = true; end
            if QCping; iQC(badping) = true; end
            if QCfish; iQC(badfish) = true; end
            velqc = avgvel;
            velqc(iQC) = NaN;
            navg = squeeze(sum(~iQC,1));
            avgu = squeeze(nanmean(velqc,1));
            avguerr = squeeze(nanstd(velqc,[],1))./sqrt(navg);
            
            % Plot beam data and QC flags
            if plotburst
                badany = zeros(size(badcorr));
                badany(badcorr) = 1;
                badany(badfish) = 2;
                clear c
                QCcolor = [rgb('white');rgb('red');rgb('blue')];
                figure('color','w','Name',[bname '_bband_data'])
                MP = get(0,'monitorposition');
                set(gcf,'outerposition',MP(1,:).*[1 1 1 1]);
                for ibeam = 1:4
                    subplot(5,4,ibeam+0*4)
                    imagesc(squeeze(avgamp(:,:,ibeam))')
                    caxis([50 160]); cmocean('amp')
                    title(['Beam ' num2str(ibeam)]);
                    if ibeam == 1; ylabel('Bin #'); end
                    if ibeam == 4;pos = get(gca,'Position');c(1) = colorbar;set(gca,'Position',pos);end
                    subplot(5,4,ibeam+1*4)
                    imagesc(squeeze(avgcorr(:,:,ibeam))')
                    caxis([mincor-5 100]);  cmocean('amp')
                    if ibeam == 1; ylabel('Bin #'); end
                    if ibeam == 4;pos = get(gca,'Position');c(2) = colorbar;set(gca,'Position',pos);end
                    subplot(5,4,ibeam+2*4)
                    imagesc(squeeze(avgvel(:,:,ibeam))')
                    caxis([-0.5 0.5]);cmocean('balance');
                    if ibeam == 1; ylabel('Bin #'); end
                    if ibeam == 4;pos = get(gca,'Position');c(3) = colorbar;set(gca,'Position',pos);end
                    subplot(5,4,ibeam+3*4)
                    imagesc(squeeze(badany(:,:,ibeam))')
                    caxis([0 2]);colormap(gca,QCcolor)
                    if ibeam == 1; ylabel('Bin #'); end
                    if ibeam == 4;pos = get(gca,'Position');c(4) = colorbar;set(gca,'Position',pos);end
                    subplot(5,4,ibeam+4*4)
                    bincolor = jet(nbin);
                    for ibin = 1:nbin
                    vbin = squeeze(avgvel(:,ibin,ibeam));
                     [PS,F,err] = hannwinPSD2(vbin,90,1,'par');
                    loglog(F,PS,'color',bincolor(ibin,:))
                    hold on
                    end
                    if ibeam == 1;ylabel('E [m^2s^{-2}]');end
                    xlabel('F (Hz)')
                    ylim(10.^[-3 0])
                    xlim([min(F) max(F)])
                    if ibeam == 4;pos = get(gca,'Position');c(5) = colorbar;set(gca,'Position',pos);end
                    colormap(gca,jet)
                end
                c(1).Label.String = 'A (dB)';
                c(2).Label.String = 'C (%)';
                c(3).Label.String = 'U_r(m/s)';
                c(4).Ticks = [0.25 1 1.75];c(4).TickLabels = {'Good','Bad C','Fish'};
                c(5).Label.String = 'Bin #';c(5).TickLabels = num2str([c(5).Ticks']*nbin);
                drawnow
                if saveplots
                    % Create mission folder if doesn't already exist
                    if ~isfolder([savefigdir SNprocess])
                        mkdir([savefigdir SNprocess])
                    end
                    figname = [savefigdir SNprocess '\' get(gcf,'Name')];
                    print(figname,'-dpng')
                    close gcf
                end

                figure('color','w','Name',[bname '_bband_QC'])
                set(gcf,'outerposition',MP(1,:).*[1 1 0.5 1]);
                clear b1 b2 b3 p1 p2 p3
                for ibeam = 1:4
                    subplot(2,3,ibeam)
                    [b1(ibeam),p1(ibeam)] = boundedline(-avgz,avgu_noqc(:,ibeam),avguerr_noqc(:,ibeam));
                    hold on
                    [b2(ibeam),p2(ibeam)] = boundedline(-avgz,avgu(:,ibeam),avguerr(:,ibeam));
                    grid
                    xlim([min(-avgz) max(-avgz)])
                    ylim(nanmean(avgu_noqc(:,ibeam))+[-0.1 0.1])
                    plot(xlim,[0 0],'--k')
                    if ibeam == 1
                        legend([b1(ibeam) b2(ibeam)],'No QC','QC','Location','southeast')
                    end
                    view(gca,[90 -90])
                    title(['Beam ' num2str(ibeam)])
                    ylabel('u_{r} [m/s]');xlabel('z[m]')
                end
                set([b1 b2],'LineWidth',2)
                set([p1 p2],'FaceAlpha',0.1)
                set(p1,'FaceColor',rgb('crimson'));set(b1,'Color',rgb('crimson'));
                set(p2,'FaceColor','k');set(b2,'Color','k');
                subplot(2,3,5)
                p1 = plot(squeeze(nanmean(avgamp)),-avgz,'linewidth',1.5);
                hold on
                ylim([min(-avgz) max(-avgz)])
                xlim([50 175])
                hold on
                legend(p1,'Beam 1','Beam 2','Beam 3','Beam 4',...
                    'location','southeast')
                xlabel('A [dB]')
                ylabel('z [m]')
                title('Amplitude')
                subplot(2,3,6)
                plot(squeeze(nanmean(avgcorr)),-avgz,'linewidth',1.5);
                hold on
                ylim([min(-avgz) max(-avgz)])
                xlim([40 100])
                plot(mincor*[1 1],ylim,'r');
                title('Correlation')
                xlabel('C [%]')
                ylabel('z [m]')
                drawnow
                if saveplots
                    figname = [savefigdir SNprocess '\' get(gcf,'Name')];
                    print(figname,'-dpng')
                    close gcf
                end
            end
            
            % Check that QC actually reduced the standard error, if not then remove it in those bins
            if any(avguerr(:) > avguerr_noqc(:))
                ibadqc = avguerr > avguerr_noqc;
                avgu(ibadqc) = avgu_noqc(ibadqc);
                avguerr(ibadqc) = avguerr_noqc(ibadqc);
            end     
            
            % Separate U, V, W
            avgw = avgu(:,4);
            avgv = avgu(:,2);
            avgu = avgu(:,1);
            avgwerr = avguerr(:,4);
            avgverr = avguerr(:,2);
            avguerr = avguerr(:,1);
            
            % Save corr & amp profiles for QC later if necessary
            ucorr = squeeze(mean(avgcorr(:,:,1)));
            vcorr = squeeze(mean(avgcorr(:,:,2)));
            wcorr = squeeze(mean(avgcorr(:,:,4)));
            uamp = squeeze(mean(avgamp(:,:,1)));
            vamp = squeeze(mean(avgamp(:,:,2)));
            wamp = squeeze(mean(avgamp(:,:,4)));

%%%%%%%%%%%% QC HR velocity data ('burst' structure) %%%%%%

            % N pings + N z-bins 
            [nbin,nping] = size(hrvel);
            dt = range(hrtime)./nping*24*3600;
            dz = median(diff(hrz));
            
            % Find spikes w/phase-shift threshold (Shcherbina 2018)
            Vr = mean(burst.SoundSpeed,'omitnan').^2./(4*10^6*5.5);% m/s
            nfilt = round(1/dz);% 1 m
            [wclean,ispike] = despikeSIG(hrvel,nfilt,Vr/2,'interp');
            
            % Spatial High-pass to flag bad pings w/too high variance
            nsm = round(2/dz); % 1 m
            wphp = wclean - smooth_mat(wclean',hann(nsm))';
            badbin = sum(ispike,2)./nping > 0.5;
            badping = sum(ispike(~badbin,:),1)./sum(~badbin) > 0.5 | ...
                std(wphp(~badbin,:),[],'omitnan') > 0.01;
            
            % QC & Calculate Mean Velocity + SE
            hrw = nanmean(wclean,2);
            hrwerr = nanstd(wclean,[],2)./sqrt(nping);
            
            % Plot beam data and QC info
            if plotburst
                clear c
                figure('color','w','Name',[bname '_hr_data'])
                set(gcf,'outerposition',MP(1,:).*[1 1 1 1]);
                subplot(4,1,1)
                imagesc(hramp)
                caxis([50 160]); cmocean('amp')
                title('HR Data');
                ylabel('Bin #')
                c = colorbar;c.Label.String = 'A (dB)';
                subplot(4,1,2)
                imagesc(hrcorr)
                caxis([mincor-5 100]);cmocean('amp')
                ylabel('Bin #')
                c = colorbar;c.Label.String = 'C (%)';
                subplot(4,1,3)
                imagesc(hrvel)
                caxis([-0.5 0.5]);cmocean('balance');
                ylabel('Bin #')
                c = colorbar;c.Label.String = 'U_r(m/s)';
                subplot(4,1,4)
                imagesc(ispike)
                caxis([0 2]);colormap(gca,[rgb('white'); rgb('black')])
                ylabel('Bin #')
                c = colorbar;c.Ticks = [0.5 1.5];
                c.TickLabels = {'Good','Spike'};
                xlabel('Ping #')
                drawnow
                if saveplots
                    figname = [savefigdir SNprocess '\' get(gcf,'Name')];
                    print(figname,'-dpng')
                    close gcf
                end
            end
            
%%%%%%%%%%%% Dissipation Estimates %%%%%%

            if sum(badping)/nping > 0.9
                disp('Bad burst, skipping dissipation...')
                eps_struct0 = NaN(size(hrw));
                eps_structHP = NaN(size(hrw));
                eps_structEOF = NaN(size(hrw));
                mspe0 = NaN(size(hrw));
                mspeHP = NaN(size(hrw));
                mspeEOF = NaN(size(hrw));
                slope0 = NaN(size(hrw));
                slopeHP = NaN(size(hrw));
                slopeEOF = NaN(size(hrw));
            else

                %EOF High-pass
                nsumeof = 3;
                eof_amp = NaN(nping,nbin);
                [eofs,eof_amp(~badping,:),~,~] = eof(wclean(:,~badping)');
                for ieof = 1:nbin
                    eof_amp(:,ieof) = interp1(find(~badping),eof_amp(~badping,ieof),1:nping);
                end
                wpeof = eofs(:,nsumeof+1:end)*(eof_amp(:,nsumeof+1:end)');

                %Structure Function Dissipation
                rmin = dz;
                rmax = 4*dz;
                nzfit = 1;
                w = wclean;
                wp1 = wpeof;
                wp2 = wphp;
                ibad = repmat(badping,nbin,1)| ispike;
                w(ibad) = NaN;
                wp1(ibad) = NaN;
                wp2(ibad) = NaN;
                warning('off','all')
                [eps_struct0,~,~,qual0] = SFdissipation(w,hrz,rmin,2*rmax,nzfit,'cubic','mean');
                [eps_structEOF,~,~,qualEOF] = SFdissipation(wp1,hrz,rmin,rmax,nzfit,'linear','mean');
                [eps_structHP,~,~,qualHP] = SFdissipation(wp2,hrz,rmin,rmax,nzfit,'linear','mean');
                warning('on','all')
                mspe0 = qual0.mspe;
                mspeHP = qualHP.mspe;
                mspeEOF = qualEOF.mspe;
                slope0 = qual0.slope;
                slopeHP = qualHP.slope;
                slopeEOF = qualEOF.slope;

                % Spectral dissipation (self-advected turbulence: Tennekes '75)
                fs = 1/dt; nwin = 64;
                if nwin > nping
                    nwin = nping;
                end
                if isfield(burst,'AHRS_GyroX')
                    hrurot =((deg2rad(burst.AHRS_GyroX))'*hrz)';
                    hrvrot =((deg2rad(burst.AHRS_GyroY))'*hrz)';
                    else
                        hrurot = zeros(size(hrvel));
                        hrvrot = zeros(size(hrvel));
                end
                uadvect = sqrt(var(hrurot,[],2,'omitnan')...
                                + var(hrvrot,[],2,'omitnan') ...
                                 + var(wclean,[],2,'omitnan'));
                [eps_spectral,wpsd] = PSDdissipation(wclean,uadvect,nwin,fs);

                % Motion spectra (bobbing)
                [bobpsd,f] = pwelch(detrend(gradient(burst.Pressure,dt)),nwin,[],[],fs);

                if plotburst
                    clear b s
                    figure('color','w','Name',[bname '_wspectra_eps'])
                    set(gcf,'outerposition',MP(1,:).*[1 1 1 1]);
                    subplot(1,4,[1 2])
                    cmap = colormap;
                    for ibin = 1:nbin
                        cind = round(size(cmap,1)*ibin/nbin);
                        l1 = loglog(f,wpsd(ibin,:),'color',cmap(cind,:),'LineWidth',1.5);
                        hold on
                    end
                    l2 = loglog(f,bobpsd,'LineWidth',2,'color',rgb('grey'));
                    l3 = loglog(f(f>1),...
                        8*(mean(uadvect).^(2/3)).*((10^(-5)).^(2/3)).*(2*pi*f(f>1)).^(-5/3),...
                        '-k','LineWidth',2);
                    xlabel('Frequency [Hz]')
                    ylabel('TKE [m^2/s^2/Hz]')
                    title('HR Spectra')
                    c = colorbar;
                    c.Label.String = 'Bin #';
                    c.TickLabels = num2str(round(c.Ticks'.*nbin));
                    legend([l1 l2 l3],'S_{w}','S_{bob}','\epsilon = 10^{-5}m^2s^{-3}','Location','northwest')
                    ylim(10.^[-6 0.8])
                    xlim([10^-0.5 max(f)])
                    subplot(1,4,3)
                    b(1) = errorbar(hrw,hrz,hrwerr,'horizontal');
                    hold on
                    b(2) = errorbar(avgw,avgz,avgwerr,'horizontal');
                    set(b,'LineWidth',2)
                    plot([0 0],[0 20],'k--')
                    xlabel('w [m/s]');
                    title('Velocity')
                    set(gca,'Ydir','reverse')
                    legend(b,'HR','Broadband','Location','southeast')
                    ylim([0 max(hrz)])
                    set(gca,'YAxisLocation','right')
                    subplot(1,4,4)
                    s(1) = semilogx(eps_SF,hrz,'r','LineWidth',2);
                    hold on
                    s(2) =  semilogx(eps_SFHP,hrz,':r','LineWidth',2);
                    s(3) = semilogx(eps_spectral,hrz,'b','LineWidth',2);
                    legend(s,'SF','SF (high-pass)','Spectral','Location','southeast')
                    title('Dissipation')
                    xlabel('\epsilon [W/Kg]'),ylabel('z [m]')
                    set(gca,'Ydir','reverse')
                    set(gca,'YAxisLocation','right')
                    drawnow
                    if saveplots
                        figname = [savefigdir SNprocess '\' get(gcf,'Name')];
                        print(figname,'-dpng')
                        close gcf
                    end
                end
            end
            
    %%%%%%%% Save processed signature data in seperate structure %%%%%%%%
                 % HR data
                SIG(iburst).HRprofile.w = hrw;
                SIG(iburst).HRprofile.werr = hrwerr;
                SIG(iburst).HRprofile.z = hrz';
                SIG(iburst).HRprofile.eps_struct0 = eps_struct0';
                SIG(iburst).HRprofile.eps_structHP = eps_structHP';
                SIG(iburst).HRprofile.eps_structEOF = eps_structEOF';
                SIG(iburst).HRprofile.eps_spectral = eps_spectral';
                % Broadband data
                SIG(iburst).profile.u = avgu;
                SIG(iburst).profile.v = avgv;
                SIG(iburst).profile.w = avgw;
                SIG(iburst).profile.uerr = avguerr;
                SIG(iburst).profile.verr = avgverr;
                SIG(iburst).profile.werr = avgwerr;
                SIG(iburst).profile.z = avgz;
                %Altimeter & Out-of-Water Flag
                SIG(iburst).altimeter = maxz;
                SIG(iburst).outofwater = outofwater;
                SIG(iburst).smallfile = smallfile;
                %Temperaure
                SIG(iburst).watertemp = nanmean(avgtemp(1:round(end/4)));
                %Time
                SIG(iburst).time = btime;
                %QC Info
                SIG(iburst).QC.ucorr = ucorr;
                SIG(iburst).QC.wcorr = vcorr;
                SIG(iburst).QC.vcorr = wcorr;
                SIG(iburst).QC.uamp = uamp;
                SIG(iburst).QC.vamp = vamp;
                SIG(iburst).QC.wamp = wamp;
                SIG(iburst).QC.hrcorr = mean(hrcorr,2,'omitnan')';
                SIG(iburst).QC.hramp = mean(hramp,2,'omitnan')';
                SIG(iburst).QC.pitch = mean(avg.Pitch,'omitnan');
                SIG(iburst).QC.roll = mean(avg.Roll,'omitnan');
                SIG(iburst).QC.head = mean(avg.Heading,'omitnan');
                SIG(iburst).QC.pitchvar = var(avg.Pitch,'omitnan');
                SIG(iburst).QC.rollvar = var(avg.Roll,'omitnan');
                SIG(iburst).QC.headvar = var(unwrap(avg.Heading),'omitnan');
                SIG(iburst).QC.wpsd = wpsd;
                SIG(iburst).QC.bobpsd = bobpsd;
                SIG(iburst).QC.f = f;
                SIG(iburst).QC.mspe0 = mspe0;
                SIG(iburst).QC.mspeHP = mspeHP;
                SIG(iburst).QC.mspeEOF = mspeEOF;
                SIG(iburst).QC.slope0 = slope0;
                SIG(iburst).QC.slopeHP = slopeHP;
                SIG(iburst).QC.slopeEOF = slopeEOF;

	%%%%%%%% Match burst time to SWIFT structure fields and replace signature data %%%%%%%%
    
            [tdiff,tindex] = min(abs([SWIFT.time]-btime));
            if tdiff > 1/(24*10) %must be within 6 min (half a burst)
                disp('   NO time index match...')
                timematch = false;
            else
                timematch = true;
                disp(['   Burst time: ' datestr(btime)])
                disp(['   SWIFT time: ' datestr(SWIFT(tindex).time)])
            end

            if  timematch && ~outofwater && ~smallfile
                % HR data
                SWIFT(tindex).signature.HRprofile = [];
                SWIFT(tindex).signature.HRprofile.w = hrw;
                SWIFT(tindex).signature.HRprofile.werr = hrwerr;
                SWIFT(tindex).signature.HRprofile.z = hrz';
                SWIFT(tindex).signature.HRprofile.tkedissipationrate = eps_structEOF';
                SWIFT(tindex).signature.HRprofile.tkedissipationrate_spectral = eps_spectral;
                % Broadband data
                SWIFT(tindex).signature.profile = [];
                SWIFT(tindex).signature.profile.east = avgu;
                SWIFT(tindex).signature.profile.north = avgv;
                SWIFT(tindex).signature.profile.w = avgw;
                SWIFT(tindex).signature.profile.uerr = avguerr;
                SWIFT(tindex).signature.profile.verr = avgverr;
                SWIFT(tindex).signature.profile.werr = avgwerr;
                SWIFT(tindex).signature.profile.z = avgz;
                %Altimeter & Out-of-Water Flag
                SWIFT(tindex).signature.altimeter = maxz;
                %Temperaure
                SWIFT(tindex).watertemp = nanmean(avgtemp(1:round(end/4)));
                
            elseif timematch && (outofwater || smallfile)
                % HR data
                SWIFT(tindex).signature.HRprofile = [];
                SWIFT(tindex).signature.HRprofile.w = NaN(size(hrw));
                SWIFT(tindex).signature.HRprofile.werr = NaN(size(hrw));
                SWIFT(tindex).signature.HRprofile.z = hrz;
                SWIFT(tindex).signature.HRprofile.tkedissipationrate = NaN(size(eps_structEOF'));
                SWIFT(tindex).signature.HRprofile.tkedissipationrate_spectral = NaN(size(eps_spectral));
                % Broadband data
                SWIFT(tindex).signature.profile = [];
                SWIFT(tindex).signature.profile.w = NaN(size(avgu));
                SWIFT(tindex).signature.profile.east = NaN(size(avgu));
                SWIFT(tindex).signature.profile.north = NaN(size(avgu));
                SWIFT(tindex).signature.profile.uerr = NaN(size(avgu));
                SWIFT(tindex).signature.profile.verr = NaN(size(avgu));
                SWIFT(tindex).signature.profile.werr = NaN(size(avgu));
                SWIFT(tindex).signature.profile.z = avgz;
                %Optional QC
                SWIFT(tindex).signature.altimeter = NaN;
                %Temperaure
                SWIFT(tindex).watertemp = NaN;
            elseif ~timematch && ~outofwater && ~smallfile
                disp('   ALERT: Burst good, but no time match...')
                tindex = length(SWIFT)+1;
                varcopy = fieldnames(SWIFT);
                varcopy = varcopy(~strcmp(varcopy,'signature'));
                for icopy = 1:length(varcopy)
                    if isa(SWIFT(1).(varcopy{icopy}),'double')
                        SWIFT(tindex).(varcopy{icopy}) = NaN;
                    elseif isa(SWIFT(1).(varcopy{icopy}),'struct')
                        varcopy2 = fieldnames(SWIFT(1).(varcopy{icopy}));
                        for icopy2 = 1:length(varcopy2)
                            varsize = size(SWIFT(1).(varcopy{icopy}).(varcopy2{icopy2}));
                            SWIFT(tindex).(varcopy{icopy}).(varcopy2{icopy2}) = NaN(varsize);
                        end
                    end
                end
                % HR data
                SWIFT(tindex).signature.HRprofile = [];
                SWIFT(tindex).signature.HRprofile.w = hrw;
                SWIFT(tindex).signature.HRprofile.werr = hrwerr;
                SWIFT(tindex).signature.HRprofile.z = hrz;
                SWIFT(tindex).signature.HRprofile.tkedissipationrate = eps_structEOF';
                SWIFT(tindex).signature.HRprofile.tkedissipationrate_spectral = eps_spectral;
                % Broadband data
                SWIFT(tindex).signature.profile = [];
                SWIFT(tindex).signature.profile.east = avgu;
                SWIFT(tindex).signature.profile.north = avgv;
                SWIFT(tindex).signature.profile.w = avgw;
                SWIFT(tindex).signature.profile.uerr = avguerr;
                SWIFT(tindex).signature.profile.verr = avgverr;
                SWIFT(tindex).signature.profile.werr = avgwerr;
                SWIFT(tindex).signature.profile.z = avgz;
                %Altimeter
                SWIFT(tindex).signature.altimeter = maxz;
                %Temperaure
                SWIFT(tindex).watertemp = nanmean(avgtemp(1:round(end/4)));
                % Time
                SWIFT(tindex).time = btime;
                disp(['   Burst time: ' datestr(btime)])
                disp(['   (new) SWIFT time: ' datestr(SWIFT(tindex).time)])
            end

        % End burst loop
        end
        [~,isort] = sort([SWIFT.time]);
        SWIFT = SWIFT(isort);
    
    %%%%%% Plot burst Averaged SWIFT Signature Data %%%%%%
    if plotmission
        time = [SIG.time];
        oow = [SIG.outofwater];
        avgz = SIG(1).profile.z;
        hrz = SIG(1).HRprofile.z;
        avgu = NaN(length(avgz),length(time));
        avgv = avgu;
        avgw = avgu;
        avgcorr = avgu;
        avgamp = avgu;
        avguerr = avgu;
        avgverr = avgu;
        avgwerr = avgu;     
        hrw = NaN(length(hrz),length(time));
        hrwvar = hrw;
        hrcorr = hrw;
        hramp = hrw;
        eps_struct = hrw;
        eps_struct0 = hrw;
        struct_slope = hrw;
        eps_spectral = hrw;
        pitch = NaN(1,length(time));
        roll = NaN(1,length(time));
        pitchvar = NaN(1,length(time));
        rollvar = NaN(1,length(time));
        for it = 1:length(time)
            %Broadband
            avgu(:,it) = SIG(it).profile.u;
            avgv(:,it) = SIG(it).profile.v;
            avgw(:,it) = SIG(it).profile.w;
            avguerr(:,it) = SIG(it).profile.uerr;
            avgverr(:,it) = SIG(it).profile.verr;
            avgwerr(:,it) = SIG(it).profile.werr;
            avgamp(:,it) = SIG(it).QC.uamp;
            avgcorr(:,it) = SIG(it).QC.ucorr;
            %HR
            hrw(:,it) = SIG(it).HRprofile.w;
            hrwvar(:,it) = SIG(it).HRprofile.werr;
            hrcorr(:,it) = SIG(it).QC.hrcorr;
            hramp(:,it) = SIG(it).QC.hramp;
            eps_struct(:,it) = SIG(it).HRprofile.eps_structEOF;
            eps_struct0(:,it) = SIG(it).HRprofile.eps_struct0;
            eps_spectral(:,it) = SIG(it).HRprofile.eps_spectral;
            pitch(it) = SIG(it).QC.pitch;
            roll(it) = SIG(it).QC.roll;
            pitchvar(it) = SIG(it).QC.pitchvar;
            rollvar(it) = SIG(it).QC.rollvar;            
        end
        avgu(:,oow) = [];
        avgv(:,oow) = [];
        avguerr(:,oow) = [];
        avgverr(:,oow) = [];
        avgw(:,oow) = [];
        avgwerr(:,oow) = [];
        hrw(:,oow) = [];
        hrwvar(:,oow) = [];
        eps_spectral(:,oow) = [];
        eps_struct(:,oow) = [];
        pitch(oow) = [];roll(oow) = [];pitchvar(oow) = [];rollvar(oow) = [];
        time(oow) = [];
        clear b
        figure('color','w','Name',SNprocess)
        MP = get(0,'monitorposition');
        set(gcf,'outerposition',MP(1,:).*[1 1 1 1]);
        % East-North Velocity
        subplot(4,3,1)
        imagesc(time,avgz,avgu);caxis([-0.5 0.5]);
        hold on;plot(xlim,max(hrz)*[1 1],'k')
        ylabel('Depth (m)');cmocean('balance');title('U')
        c = colorbar;c.Label.String = 'ms^{-1}';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        subplot(4,3,4)
        imagesc(time,avgz,avguerr);caxis([0.005 0.015]);
        hold on;plot(xlim,max(hrz)*[1 1],'k')
        ylabel('Depth (m)');title('\sigma_U')
        c = colorbar;c.Label.String = 'ms^{-1}';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        subplot(4,3,7)
        imagesc(time,avgz,avgv);caxis([-0.5 0.5]);
        hold on;plot(xlim,max(hrz)*[1 1],'k')
        ylabel('Depth (m)');cmocean('balance');title('V')
        c = colorbar;c.Label.String = 'ms^{-1}';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        subplot(4,3,10)
        imagesc(time,avgz,avgverr);caxis([0.005 0.015]);
        hold on;plot(xlim,max(hrz)*[1 1],'k')
        ylabel('Depth (m)');title('\sigma_V')
        c = colorbar;c.Label.String = 'ms^{-1}';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        %Vertical Velocity
        subplot(4,3,2)
        imagesc(time,avgz,avgw);caxis([-0.05 0.05]);
        hold on;plot(xlim,max(hrz)*[1 1],'k')
        cmocean('balance');cmocean('balance');ylabel('Depth (m)');title('W')
        c = colorbar;c.Label.String = 'ms^{-1}';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        subplot(4,3,5)
        imagesc(time,avgz,avgwerr);caxis([0.005 0.015]);
        hold on;plot(xlim,max(hrz)*[1 1],'k')
        ylabel('Depth (m)');title('\sigma_W')
        c = colorbar;c.Label.String = 'ms^{-1}';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        subplot(4,3,8)
        imagesc(time,hrz,hrw);caxis([-0.05 0.05])
        ylabel('Depth (m)');cmocean('balance');title('W_{HR}')
        c = colorbar;c.Label.String = 'ms^{-1}';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        subplot(4,3,11)
        imagesc(time,hrz,hrwvar);caxis([0.001 0.005]);
        ylabel('Depth (m)');title('\sigma_W_{HR}')
        c = colorbar;c.Label.String = 'ms^{-1}';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        %Dissipation
        subplot(4,3,3)
        imagesc(time,hrz,log10(eps_struct));caxis([-7.5 -4.5]);
        ylabel('Depth (m)');title('Structure \epsilon (Ar^{2/3})')
        c = colorbar;c.Label.String = 'log_{10}(m^3s^{-2})';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        subplot(4,3,6)
        imagesc(time,hrz,log10(eps_struct0));caxis([-7.5 -4.5]);
        ylabel('Depth (m)');title('Structure \epsilon (Ar^{2/3} + Br^2)')
        c = colorbar;c.Label.String = 'log_{10}(m^3s^{-2})';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        subplot(4,3,9)
        imagesc(time,hrz,log10(eps_spectral));caxis([-5 -2]);
        ylabel('Depth (m)');title('Spectral \epsilon')
        c = colorbar;c.Label.String = 'log_{10}(m^3s^{-2})';
        set(gca,'XTick',min(time):1/24:time(end));datetick('x','HH:MM','KeepLimits','KeepTicks')
        ax1 = gca;
        %Pitch + Roll
        subplot(4,3,12)
        yyaxis left
        plot(time,pitch,'-r','LineWidth',2);
        hold on
        plot(time,roll,'-b','LineWidth',2);
        ylim([-3 3])
        xlim([min(time) max(time)])
        plot(xlim,[0 0],':k')
        ylabel('\phi/\psi (^{\circ})')
        set(gca,'YColor','k')
        yyaxis right
        b(1) = bar(time,sqrt(pitchvar));
        hold on
        b(2) = bar(time,sqrt(rollvar));
        b(1).FaceColor = 'r';
        b(2).FaceColor = 'b';
        ylim([0 10])
        xlim([min(time) max(time)])
        set(b,'FaceAlpha',0.25,'EdgeColor',rgb('grey'))
        set(gca,'YColor',rgb('grey'))
        set(gca,'XTick',min(time):1/24:time(end));
        ylabel('\sigma_{\phi/\psi} (^{\circ})');title('Pitch/Roll')
        datetick('x','HH:MM','KeepLimits','KeepTicks')
        ax2 = gca;
        ax2.Position([3 4]) = ax1.Position([3 4]);
        if saveplots
            %Create mission folder if doesn't already exist
            if ~isfolder([savefigdir SNprocess])
                mkdir([savefigdir SNprocess])
            end
            figname = [savefigdir '\' get(gcf,'Name')];
            print(figname,'-dpng')
            close gcf
        end
    end
            
	%%%%%% Save SWIFT Structure %%%%%%%%
    if saveSWIFT
        if strcmp(structfile.name(end-6:end-4),'SBG')
            save([savestructdir SNprocess '_reprocessedSIGandSBG.mat'],'SWIFT')
        else
            save([savestructdir SNprocess '_reprocessedSIG.mat'],'SWIFT')
        end
    end
    
    %%%%%% Save SIG Structure %%%%%%%%
    if saveSIG
       save([savestructdir SNprocess '_burstavgSIG.mat'],'SIG')
    end
    
 % End mission loop
end
% clear all
