function footprint=draw_manual_footprint(image,options)
%DRAW_MANUAL_FOOTPRINT Shared interaction behind the manual footprint modes.
%   Opens the snap, lets the operator draw one ROI, lets them adjust it, and
%   turns what they accepted into a mask. The only things that differ between a
%   rectangle and a polygon are the drawing call, one line of instructions and
%   the name the vertices are recorded under, so those are arguments and the
%   rest of the flow lives here once.
%
%   Private to the package: the entry points are manual_rectangle_mask and
%   manual_polygon_mask, which own their own position validation.
arguments
    image {mustBeNumeric,mustBeNonempty}
    % Recorded on the footprint, e.g. "manual-rectangle".
    options.Mode (1,1) string
    % First title line, e.g. "Draw a rectangle around ...".
    options.Instruction (1,1) string
    % @(ax) -> roi. Blocks until the operator has drawn one.
    options.DrawNew function_handle
    % @(ax,position) -> roi. Does not block; used when a footprint is supplied.
    options.DrawAt function_handle
    % Field the accepted geometry is stored under, e.g. "rectangle_position".
    options.GeometryField (1,1) string
    % Already validated by the caller. Empty means draw it interactively.
    options.Position double = []
    options.Visible (1,1) string ...
        {mustBeMember(options.Visible,["on","off"])} = "on"
end

im=double(image(:,:,1));

if ~isempty(options.Position)
    footprint=mask_from_position(im,options.Position,options);
    return
end

% Drawing needs a window. Without this the call would block forever on a figure
% nobody can see, which is a far worse failure than saying so.
if options.Visible=="off"
    error("adaptive_optopatch:ManualSelectionNeedsVisibleFigure", ...
        "Manual footprint selection needs a visible figure. Supply the " + ...
        "footprint geometry to select one without drawing it.");
end

accepted=false;
figureHandle=open_selection_figure(im,options.Instruction);
restoreFigure=onCleanup(@() delete_if_valid(figureHandle));

% The draw call blocks until the operator has finished one shape. Closing the
% window instead leaves nothing valid behind, which is the cancel path.
try
    roi=options.DrawNew(figureHandle.CurrentAxes);
catch
    roi=[];
end
if isempty(roi) || ~isvalid(roi) || isempty(roi.Position)
    cancel();
end

% Now it can be moved and reshaped until accepted. Double-click and Enter both
% accept, because either is the obvious thing to try.
clickListener=addlistener(roi,"ROIClicked",@on_roi_clicked);
figureHandle.KeyPressFcn=@on_key_press;
figureHandle.CloseRequestFcn=@on_close_request;
uiwait(figureHandle);
delete(clickListener);

if ~accepted || ~isvalid(roi)
    cancel();
end

% createMask rather than arithmetic on the vertices, so the mask is exactly the
% pixels the operator saw enclosed.
footprint=package_footprint(createMask(roi),roi.Position,options);
clear restoreFigure

    function on_roi_clicked(~,event)
        if strcmp(event.SelectionType,"double")
            accepted=true;
            uiresume(figureHandle);
        end
    end

    function on_key_press(~,event)
        if any(strcmp(event.Key,{'return','enter'}))
            accepted=true;
            uiresume(figureHandle);
        end
    end

    function on_close_request(~,~)
        % Leaves accepted false, so the caller takes the cancel path.
        uiresume(figureHandle);
    end
end


function cancel()
error("adaptive_optopatch:ManualFootprintCanceled", ...
    "Manual footprint selection was canceled.");
end


function figureHandle=open_selection_figure(im,instruction)
% Big enough to draw on comfortably, and scaled so a dim patch is still
% visible: the operator has to be able to see the edge they are enclosing.
figureHandle=figure("Name","Draw the illuminated footprint", ...
    "NumberTitle","off","Visible","on");
figureHandle.Position(3:4)=[900 700];
movegui(figureHandle,"center");

ax=axes(figureHandle);
imagesc(ax,im);
colormap(ax,gray);
axis(ax,"image");
colorbar(ax);
title(ax,{instruction, ...
    "Double-click inside the shape or press Enter to accept.", ...
    "Close the window to cancel."});
xlabel(ax,"camera column (px)");
ylabel(ax,"camera row (px)");
drawnow;
end


% Same createMask path as the interactive case, on an offscreen figure, so a
% supplied footprint and a drawn one cannot disagree.
function footprint=mask_from_position(im,position,options)
figureHandle=figure("Visible","off");
cleanup=onCleanup(@() delete_if_valid(figureHandle));
ax=axes(figureHandle);
imagesc(ax,im);
axis(ax,"image");
roi=options.DrawAt(ax,position);
footprint=package_footprint(createMask(roi),roi.Position,options);
clear cleanup
end


function footprint=package_footprint(mask,position,options)
if ~any(mask,"all")
    error("adaptive_optopatch:EmptyManualFootprint", ...
        "The shape enclosed no pixels, so it has no area. Draw it over the " + ...
        "illuminated patch.");
end
details=struct();
details.(options.GeometryField)=double(position);
footprint=struct( ...
    "mask",logical(mask), ...
    "mode",options.Mode, ...
    "details",details);
end


function delete_if_valid(figureHandle)
if ~isempty(figureHandle) && isvalid(figureHandle)
    delete(figureHandle);
end
end
