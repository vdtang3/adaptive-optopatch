function mask = draw_null_roi(referenceImage)
%DRAW_NULL_ROI Draw one experimenter-defined background/null polygon.
arguments
    referenceImage (:,:) {mustBeNumeric}
end
fig=figure("Name","Draw null/background ROI");
ax=axes(fig); imagesc(ax,referenceImage); axis(ax,"image"); colormap(ax,"gray");
title(ax,"Draw background ROI; double-click to finish");
roi=drawpolygon(ax);
wait(roi);
if isempty(roi.Position)
    mask=false(size(referenceImage));
else
    p=roi.Position;
    mask=poly2mask(p(:,1),p(:,2),size(referenceImage,1),size(referenceImage,2));
end
close(fig);
end
