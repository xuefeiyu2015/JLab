function [pse,threshold] = VisPsychometricFunction(psymat,plot_flag);
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

    if nargin < 4
        plot_flag = 1;  % default
    end
    [stimulus, direction, choice_response] = deal(psymat(:,1), psymat(:,2), psymat(:,3));
    
    stimulus_dir = stimulus .* direction;
    
    [stim_levels, ~, idx] = unique(stimulus_dir);   
    pRight = accumarray(idx, choice_response==1, [], @mean);

    % Fitting with logistic regression
    psy = table(stimulus_dir(:), choice_response(:), ...
            'VariableNames', {'stimulus_dir','response'});
    fitted_psy = fitglm(psy, 'response ~ stimulus_dir', 'Distribution', 'binomial');
    b0 = fitted_psy.Coefficients.Estimate(1);
    b1 = fitted_psy.Coefficients.Estimate(2);

    % Get bias and threshold
    pse = -b0 / b1;
    threshold = pi/(b1*sqrt(3));

    TotalTrials = size(psymat,1);
    %% Plot Psychometric function  
    if plot_flag
    figure
    set(gcf,'color','w')
    plot(stim_levels,pRight,'.r','MarkerSize',20); %Raw data

   % xx = linspace(min(psy(:,1)), max(psy(:,1)), 100);  % plotting range
    xx = linspace(-200, 200, 100); 
    yy = 1./(1+exp(-(b0 + b1*xx)));      % fitted psy

    hold on 
    plot(xx, yy, 'r-', 'LineWidth', 2);  % fitted line
    xlabel('Target Asychrony (ms)');
    ylabel('Proportion of rightward choices)');
    %title('Psychometric Function ');
    ylim([0 1]);
    yticks([0,0.5,1]);
    
    xlim([min(stimulus_dir)-10,max(stimulus_dir)+10]);
    set(gca,'LineWidth',1,'FontSize',15);
    
    hold on 
    plot([min(xx),max(xx)],[0.5,0.5],'--k');
    plot([0,0],[0,1],'--k');

    % get the range of current axis
    ax = gca;
    xlim_vals = ax.XLim;
    ylim_vals = ax.YLim;

    % setup the textbox location
    x_pos = xlim_vals(2) - 0.05*(xlim_vals(2)-xlim_vals(1));
    y_pos = ylim_vals(1) + 0.05*(ylim_vals(2)-ylim_vals(1));

    % add the text for bias and threshold
    text(x_pos, y_pos, sprintf('PSE = %.2f\nThreshold = %.2f\nN=%d', pse, threshold,TotalTrials), ...
    'HorizontalAlignment', 'right', 'VerticalAlignment', 'bottom', 'FontSize', 12);


    box off;
    end



end