function CBPP_wholebrain(fc, y, conf, cv_ind, out_dir, options)
% CBPP_wholebrain(fc, y, conf, cv_ind, out_dir, options)
%
% This function runs Connectivity-based Psychometric Prediction (CBPP) using whole-brain 
% connectivity matrix (fc) to predict psychometric variables (y)
%
% Inputs:
%       - fc     :
%                 DxDxN matrix containing the DxD functional connectivity matrix (i.e. between 
%                 D parcels/voxels) from N subjects
%       - y      :
%                 NxP matrix containing P psychometric variables from N subjects
%       - conf   :
%                 NxC matrix containing C confounding variables from N subjects
%       - cv_ind : 
%                 NxM matrix containing cross-validation fold indices for M repeats on N subjects. 
%                 The indices should range from 1 to K, for a K-fold cross-validation scheme
%       - out_dir:
%                 Absolute path to output directory
%       - options:
%                 (Optional) see below for available settings
%
% Options:
%       - method  :
%                  Regression method to use. Available options: 'MLR' (multiple linear regression),
%                  'SVR' (Support Vector Regression), 'EN' (Elastic Nets)
%                  Default: 'SVR'
%       - prefix  :
%                  Prefix for output filename. If all setting are default, the output file will be 
%                  named with the prefix 'wbCBPP_SVR_standard_test'
%                  Default: 'test'
%       - conf_opt:
%                  Confound controlling approach. Available options:
%                  'standard' ('standard' approach): regress out confounding variables from training 
%                             subjects and apply to test subjects
%                  'str_conf' ('sex + brain size confounds' approach): similar to 'standard', but 
%                             noting that the confounding variables passed in are only those 
%                             correlated with strength (i.e. gender, brain size and ICV).
%                  'add_conf' ('confounds added as features' approach) normalise the confounding 
%                             variables and add them to features
%                  'no_conf' ('no confound' approach) don't use confounds
%                  Default: 'standard'
%
% Output:
%        One .mat file will be saved to out_dir, containing performance in training set (vairable 
%        'r_train') and validation set (variable 'r_test').
%
% Example:
% CBPP_wholebrain(fc, y, conf, cv_ind, '~/results')
%
% Jianxiao Wu, last edited on 06-Sept-2019

% usage
if nargin < 5
    disp('Usage: CBPP_wholebrain(fc, y, conf, cv_ind, out_dir, [options])');
    return
end

% add utility functions to path
my_path = fileparts(mfilename('fullpath'));
addpath([my_path '/utilities']);

% set default settings
if nargin < 6
    options = [];
    options.method = 'SVR';
    options.prefix = 'test';
    options.conf_opt = 'standard';
end
if ~isfield(options, 'method'); options.method = 'SVR'; end
if ~isfield(options, 'prefix'); options.prefix = 'test'; end
if ~isfield(options, 'conf_opt'); options.conf_opt = 'standard'; end

% set-up
yd = size(y, 2); % dimensionality of targets y == P
n = size(y, 1); % number of subjects == N
n_fold = max(cv_ind(:)); % number of folds for CV == K
n_repeat = size(cv_ind, 2); % number of repeats for CV == M

% only take the upper triangular nondiagonal portion of FC
xd = size(fc, 1) * (size(fc, 1) - 1) / 2; % actual dimensionality of features x now
x = zeros(n, xd);
for subject = 1:n
    upper_tri = triu(fc(:, :, subject), 1);
    x(subject, :) = upper_tri(upper_tri ~= 0);
end

% run cross-validation
r_train = zeros(n_repeat, n_fold, yd);
r_test = zeros(n_repeat, n_fold, yd);
t = zeros(n_repeat, n_fold);
% loop through M repeats
for repeat = 1:n_repeat 
    cv_ind_curr = cv_ind(:, repeat); % CV fold indices for the current repeat

    % loop through K folds
    for fold = 1:n_fold 
        disp(['Running repeat ' num2str(repeat) 'fold ' num2str(fold)]);
        tic
        
        % get indices for training and test sets
        % SVR/MLR: split into training and test set
        if strcmp(method, 'SVR') || strcmp(method, 'MLR')
            train_ind = double(cv_ind_curr ~= fold);
            test_ind = double(cv_ind_curr == fold);
        % EN: split into training, validation and test set
        elseif strcmp(method, 'EN')
            if fold == n_fold; fold_inner = 1; else; fold_inner = fold + 1; end
            train_ind = (cv_ind_curr ~= fold) .* (cv_ind_curr ~= fold_inner);
            val_ind = double(cv_ind_curr == fold_inner);
            test_ind = double(cv_ind_curr == fold);
        end
        
        % feature selection
        if strcmp(method, 'SVR') % no feature selection for SVR
            feature_sel = ones(xd, yd);
        elseif strcmp(method, 'MLR') % select top 500 FC edges
            feature_sel = select_feature_corr(x(train_ind==1, :), y(train_ind==1, :), 0, 500, 0);
        elseif strcmp(method, 'EN') % select top 50% FC edges
            feature_sel = select_feature_corr(x(train_ind==1, :), y(train_ind==1, :), 0, 0, 50);
        end
        
        % regress out confounds if specified
        y_curr = y;
        if strcmp(options.conf_opt, 'standard') || strcmp(options.conf_opt, 'str_conf')
            [y_curr(train_ind==1, :), reg_y] = regress_confounds_y(y_curr(train_ind==1, :), conf(train_ind==1, :));
            y_curr(test_ind==1, :) = regress_confounds_y(y_curr(test_ind==1, :), conf(test_ind==1, :), reg_y);
            if strcmp(method, 'EN') % also apply confounds removal to validation fold for EN
                y_curr(val_ind==1, :) = regress_confounds_y(y_curr(val_ind==1, :), conf(val_ind==1, :), reg_y);
            end
        end
        
        % loop through P targets
        for target_ind = 1:yd
            % get selected features
            x_sel = x(:, feature_sel(:, target_ind) == 1);

            % add confounds if specified
            if strcmp(options.conf_opt, 'add_conf'); x_sel = [x_sel, zscore(confounds)]; end
            
            % run regression
            reg_func = str2func([method '_one_fold']);
            [r_test_curr, r_train_curr] = reg_func(x_sel, y_curr(:, target_ind), cv_ind_curr, fold);
            
            % collect results
            r_train(repeat, fold, target_ind) = r_train_curr;
            r_test(repeat, fold, target_ind) = r_test_curr;
        end
        t(repeat, fold) = toc;
    end
end
disp(['Average time taken for one fold: ' num2str(mean(t(:)))]);

% save performance results
output_name = ['wbCBPP_' method '_' options.conf_opt '_' prefix ];
save([out_dir '/' output_name '.mat'], 'r_train', 'r_test');