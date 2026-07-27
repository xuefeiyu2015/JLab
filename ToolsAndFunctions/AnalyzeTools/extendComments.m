function ex = extendComments(comments,varargin);
% Extend comments with one or more tables that have the same number of rows.
% Example:
%   ex = extendComments(comments, more1, more2, more3);
ex = comments;

    for k = 1:numel(varargin)

        more = varargin{k};

        if height(ex) ~= height(more)

            error('Table %d has %d rows, expected %d.',k, height(more), height(ex));

        end

        % Exclude the trial column, as it's already in comments.
        if ismember("Trial", more.Properties.VariableNames)
            more(:, "Trial") = [];

        end

        ex = [ex, more];

    end

end