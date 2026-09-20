function plot_element_geometry(fieldIITransmit, fieldIIReceive, vkTransmitPositions, vkTransmitSizes, vkReceivePositions, vkReceiveSizes, plotTitle)
if nargin < 7
    plotTitle = 'Physical element geometry';
end
figure('Name', plotTitle);
hold on;
plot_rectangles(fieldIITransmit, [0.1, 0.45, 0.85], [0.1, 0.25, 0.65], 'Field II transmit');
plot_rectangles(fieldIIReceive, [0.95, 0.55, 0.1], [0.75, 0.3, 0.05], 'Field II receive');
plot_rectangles(vkTransmitPositions, vkTransmitSizes, [0.2, 0.75, 0.3], [0.1, 0.45, 0.15], 'Ekhos transmit');
plot_rectangles(vkReceivePositions, vkReceiveSizes, [0.8, 0.25, 0.8], [0.5, 0.1, 0.55], 'Ekhos receive');
axis equal;
view(3);
grid on;
xlabel('x (mm)');
ylabel('y (mm)');
zlabel('z (mm)');
title(plotTitle);
legend('Location', 'best');
end

function plot_rectangles(positionsOrRectData, sizesOrFaceColor, faceColorOrEdgeColor, edgeColorOrLabel, label)
if nargin == 4
    faceColor = sizesOrFaceColor;
    edgeColor = faceColorOrEdgeColor;
    label = edgeColorOrLabel;
    if isa(positionsOrRectData, 'ekhos.RectangularElementSet')
        plot_position_rectangles(positionsOrRectData.Positions, positionsOrRectData.Sizes, ...
            faceColor, edgeColor);
    else
        rectData = positionsOrRectData;
        for elementIndex = 1:size(rectData, 2)
            corners = reshape(rectData(11:22, elementIndex), 3, 4);
            patch(corners(1, :) * 1e3, corners(2, :) * 1e3, corners(3, :) * 1e3, ...
                faceColor, 'FaceAlpha', 0.2, 'EdgeColor', edgeColor, 'LineWidth', 0.5, ...
                'HandleVisibility', 'off');
        end
    end
else
    positions = positionsOrRectData;
    sizes = sizesOrFaceColor;
    faceColor = faceColorOrEdgeColor;
    edgeColor = edgeColorOrLabel;
    plot_position_rectangles(positions, sizes, faceColor, edgeColor);
end
plot3(nan, nan, nan, 's', 'Color', edgeColor, 'MarkerFaceColor', faceColor, ...
    'DisplayName', label);
end

function plot_position_rectangles(positions, sizes, faceColor, edgeColor)
for elementIndex = 1:size(positions, 2)
    halfWidth = sizes(1, elementIndex) / 2;
    halfHeight = sizes(2, elementIndex) / 2;
    x = positions(1, elementIndex);
    y = positions(2, elementIndex);
    z = positions(3, elementIndex);
    patch([x - halfWidth, x - halfWidth, x + halfWidth, x + halfWidth] * 1e3, ...
        [y - halfHeight, y + halfHeight, y + halfHeight, y - halfHeight] * 1e3, ...
        [z, z, z, z] * 1e3, faceColor, 'FaceAlpha', 0.2, ...
        'EdgeColor', edgeColor, 'LineWidth', 0.5, 'HandleVisibility', 'off');
end
end
