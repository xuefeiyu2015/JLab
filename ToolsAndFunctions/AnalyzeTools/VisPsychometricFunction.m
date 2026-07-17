function [pse, threshold, psy] = VisPsychometricFunction(psymat, plot_flag)
% Compute and visualize Psychometric Function
% Xuefei Yu Mar 6, 2026
% Input:
% stimulus: the absolute value of the stimulus, e.g. temporal
% delay,coherence, et.al
% direction: left or right. -1 or +1
% choice_response: left or right, 0 or +1
% plot_flag, optional, 1:plot psychometric function, 0: do not plot
% Output:
% pse: the mu, bias
% threshold: the sd
% psy: everything the psychometric plot is drawn from, so a caller can draw
%      its own (several fits on one axes, say) without refitting:
%   .stim_levels - unique signed stimulus levels (stimulus .* direction)
%   .pRight      - proportion of rightward choices at each level
%   .n           - trials contributing to each level
%   .fit_x       - x of the fitted curve, spanning the data plus a margin
%   .fit_y       - y of the fitted curve at fit_x
%   .b0, .b1     - the fitted logistic coefficients
%   .separable   - true when the choices are perfectly separated by the
%                  stimulus. The logistic then has no finite ML slope: glmfit
%                  runs to its iteration limit and returns an arbitrarily steep
%                  one, so threshold means "nothing constrains this", not
%                  "exquisitely sensitive". Report it, do not trust it.
%   .nTrials     - total trials in the fit

    if nargin < 2
        plot_flag = 1;  % default
    end
    [stimulus, direction, choice_response] = deal(psymat(:,1), psymat(:,2), psymat(:,3));

    stimulus_dir = stimulus .* direction;

    [stim_levels, ~, idx] = unique(stimulus_dir);
    pRight = accumarray(idx, choice_response==1, [], @mean);
    nLevel = accumarray(idx, 1);

    % Fitting with logistic regression
    psy_tbl = table(stimulus_dir(:), choice_response(:), ...
            'VariableNames', {'stimulus_dir','response'});
    fitted_psy = fitglm(psy_tbl, 'response ~ stimulus_dir', 'Distribution', 'binomial');
    b0 = fitted_psy.Coefficients.Estimate(1);
    b1 = fitted_psy.Coefficients.Estimate(2);

    % Get bias and threshold
    pse = -b0 / b1;
    threshold = 1/b1;

    TotalTrials = size(psymat,1);

    % Fitted curve over the range the data actually covers, plus a margin. A
    % fixed range would only ever suit one kind of stimulus; this follows
    % whatever units the caller passed (ms, coherence, ...).
    span = max(stim_levels) - min(stim_levels);
    if span == 0
        pad = 1;
    else
        pad = 0.05 * span;
    end
    fit_x = linspace(min(stim_levels)-pad, max(stim_levels)+pad, 200);
    fit_y = 1./(1+exp(-(b0 + b1*fit_x)));

    psy = struct('stim_levels', stim_levels, 'pRight', pRight, 'n', nLevel, ...
                 'fit_x', fit_x, 'fit_y', fit_y, 'b0', b0, 'b1', b1, ...
                 'separable', isSeparable(pRight), 'nTrials', TotalTrials);

    %% Plot Psychometric function
    if plot_flag
    figure
    set(gcf,'color','w')
    plot(stim_levels,pRight,'.r','MarkerSize',20); %Raw data

    hold on
    plot(fit_x, fit_y, 'r-', 'LineWidth', 2);  % fitted line
    xlabel('Target Asychrony (ms)');
    ylabel('Proportion of rightward choices)');
    %title('Psychometric Function ');
    ylim([0 1]);
    yticks([0,0.5,1]);

    xlim([min(fit_x),max(fit_x)]);
    set(gca,'LineWidth',1,'FontSize',15);

    hold on
    plot([min(fit_x),max(fit_x)],[0.5,0.5],'--k');
    plot([0,0],[0,1],'--k');

    % get the range of current axis
    ax = gca;
    xlim_vals = ax.XLim;
    ylim_vals = ax.YLim;

    % setup the textbox location
    x_pos = xlim_vals(2) - 0.05*(xlim_vals(2)-xlim_vals(1));
    y_pos = ylim_vals(1) + 0.05*(ylim_vals(2)-ylim_vals(1));

    % add the text for bias and threshold
    if psy.separable
        txt = sprintf('PSE = %.2f\nThreshold = unreliable (separable)\nN=%d', pse, TotalTrials);
    else
        txt = sprintf('PSE = %.2f\nThreshold = %.2f\nN=%d', pse, threshold, TotalTrials);
    end
    text(x_pos, y_pos, txt, ...
    'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', 'FontSize', 12);


    box off;
    end



end


function tf = isSeparable(pRight)
% True when some stimulus value splits the choices perfectly, so the logistic
% has no finite maximum-likelihood slope.
    if numel(pRight) < 2
        tf = true;  return
    end
    % Every level all-one-way, and never switching back: a clean step.
    tf = all(pRight == 0 | pRight == 1) && issorted(pRight);
end
