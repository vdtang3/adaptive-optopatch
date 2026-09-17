classdef TestIlluminationIrradiance < matlab.unittest.TestCase
    % The computational pieces behind measure_illumination_irradiance.
    %
    % File picker, dialog and figures are deliberately not exercised here: they
    % are the parts that need a person. Everything that turns pixels and
    % power-meter readings into numbers is a package helper precisely so it can
    % be tested without either, and the one end-to-end case drives the utility
    % with explicit arguments and Visible="off".

    properties (Constant)
        % The task's worked example: anisotropic and sheared, so an area taken
        % from any single scalar would be wrong.
        J_SHEARED = [0.40, 0.03; 0.01, 0.46];
        TOL = 1e-12;
    end

    methods (Static)
        % A synthetic snap: uniform background with one bright rectangle.
        % The patch is a large fraction of the frame so the default 80th
        % percentile lands inside it - see smallPatchFailsClearly for what
        % happens when it does not.
        function [image, patchRows, patchColumns] = syntheticPatch(background, signal)
            image = background * ones(100, 120);
            patchRows = 21:80;        % 60 rows
            patchColumns = 31:110;    % 80 columns
            image(patchRows, patchColumns) = signal;
        end

        % A frame with one centred square bright patch covering the requested
        % fraction of it, plus noise on both levels so the percentile estimates
        % are exercised the way a real snap exercises them.
        function [image, side, coverage] = patchImage(frame, coverage)
            rng(3);
            side = round(sqrt(coverage * frame^2));
            image = 100 + 6 * randn(frame, frame);
            span = round(frame / 2 - side / 2) + (1:side);
            image(span, span) = 1100 + 25 * randn(side, side);
            coverage = side^2 / frame^2;
        end

        function path = writeSnap(folder, name, fields)
            snap = fields;
            path = fullfile(folder, name);
            save(path, 'snap');
        end
    end

    methods (Test)

        %% --- A. determinant-based area --------------------------------

        function areaUsesTheDeterminant(testCase)
            J = [0.4, 0; 0, 0.5];
            mask = true(1, 1000);

            area = adaptive_optopatch.calculate_illuminated_area(J, mask);

            testCase.verifyEqual(area.pixel_area_um2, 0.2, 'AbsTol', testCase.TOL);
            testCase.verifyEqual(area.illuminated_pixels, 1000);
            testCase.verifyEqual(area.area_um2, 200, 'AbsTol', testCase.TOL);
            testCase.verifyEqual(area.area_mm2, 0.0002, 'AbsTol', testCase.TOL);
            testCase.verifyEqual(area.equivalent_square_side_um, sqrt(200), ...
                'AbsTol', testCase.TOL);
        end

        %% --- B. sheared / anisotropic transform -----------------------

        function shearedTransformUsesDeterminantNotADiagonalOrAverage(testCase)
            J = testCase.J_SHEARED;
            mask = true(10, 10);        % 100 px

            area = adaptive_optopatch.calculate_illuminated_area(J, mask);

            testCase.verifyEqual(area.pixel_area_um2, abs(det(J)), ...
                'AbsTol', testCase.TOL);

            % And explicitly not any of the tempting scalar shortcuts.
            testCase.verifyNotEqual(area.pixel_area_um2, J(1, 1)^2);
            testCase.verifyNotEqual(area.pixel_area_um2, J(2, 2)^2);
            testCase.verifyNotEqual(area.pixel_area_um2, J(1, 1) * J(2, 2));
            testCase.verifyNotEqual(area.pixel_area_um2, mean([J(1, 1), J(2, 2)])^2);
        end

        function boundingBoxUsesTheTransformAndIsNotTheArea(testCase)
            J = testCase.J_SHEARED;
            mask = false(50, 80);
            mask(11:30, 21:60) = true;        % 20 rows x 40 columns = 800 px

            area = adaptive_optopatch.calculate_illuminated_area(J, mask);

            testCase.verifyEqual(area.bounding_width_px, 40);
            testCase.verifyEqual(area.bounding_height_px, 20);
            testCase.verifyEqual(area.bounding_width_um, norm(J * [40; 0]), ...
                'AbsTol', testCase.TOL);
            testCase.verifyEqual(area.bounding_height_um, norm(J * [0; 20]), ...
                'AbsTol', testCase.TOL);

            % The box is a sanity check, not the measurement: width*height
            % differs from the authoritative determinant-based area.
            testCase.verifyNotEqual( ...
                area.bounding_width_um * area.bounding_height_um, area.area_um2);
            testCase.verifyEqual(area.area_um2, 800 * abs(det(J)), ...
                'AbsTol', testCase.TOL);
        end

        function singularTransformIsRejected(testCase)
            testCase.verifyError(@() adaptive_optopatch.calculate_illuminated_area( ...
                [0.4, 0.4; 0.4, 0.4], true(4, 4)), ...
                'adaptive_optopatch:SingularPhysicalCalibration');
        end

        %% --- C. power conversion --------------------------------------

        function powerConvertsToIrradiance(testCase)
            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                1, 0.02, 0.0002);

            testCase.verifyEqual(summary.irradiance_mW_mm2, 100, ...
                'AbsTol', testCase.TOL);
            testCase.verifyEqual(summary.mean_irradiance_mW_mm2, 100, ...
                'AbsTol', testCase.TOL);
        end

        function everyIndividualReadingIsPreserved(testCase)
            voltage = [1 1 1 2 2];
            power = [0.1 0.2 0.3 0.4 0.5];

            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                voltage, power, 0.01);

            testCase.verifyEqual(summary.power_mW, power(:), 'AbsTol', testCase.TOL);
            testCase.verifyEqual(summary.irradiance_mW_mm2, power(:) / 0.01, ...
                'AbsTol', 1e-9);
        end

        %% --- D. input validation --------------------------------------

        function mismatchedVectorLengthsAreRejected(testCase)
            testCase.verifyError(@() adaptive_optopatch.summarize_aotf_calibration( ...
                [1 2 3], [0.1 0.2], 0.01), ...
                'adaptive_optopatch:AotfMeasurementLengthMismatch');
        end

        function missingOneVectorIsRejected(testCase)
            testCase.verifyError(@() adaptive_optopatch.summarize_aotf_calibration( ...
                [1 2 3], [], 0.01), ...
                'adaptive_optopatch:IncompleteAotfMeasurements');
            testCase.verifyError(@() adaptive_optopatch.summarize_aotf_calibration( ...
                [], [0.1 0.2], 0.01), ...
                'adaptive_optopatch:IncompleteAotfMeasurements');
        end

        function nonFiniteMeasurementsAreRejected(testCase)
            testCase.verifyError(@() adaptive_optopatch.summarize_aotf_calibration( ...
                [1 NaN], [0.1 0.2], 0.01), ...
                'adaptive_optopatch:NonFiniteAotfVoltage');
            testCase.verifyError(@() adaptive_optopatch.summarize_aotf_calibration( ...
                [1 Inf], [0.1 0.2], 0.01), ...
                'adaptive_optopatch:NonFiniteAotfVoltage');
            testCase.verifyError(@() adaptive_optopatch.summarize_aotf_calibration( ...
                [1 2], [0.1 NaN], 0.01), ...
                'adaptive_optopatch:NonFiniteAotfPower');
            testCase.verifyError(@() adaptive_optopatch.summarize_aotf_calibration( ...
                [1 2], [0.1 Inf], 0.01), ...
                'adaptive_optopatch:NonFiniteAotfPower');
        end

        function negativePowerIsRejected(testCase)
            testCase.verifyError(@() adaptive_optopatch.summarize_aotf_calibration( ...
                [1 2], [0.1 -0.2], 0.01), ...
                'adaptive_optopatch:NegativeAotfPower');
        end

        function bothVectorsEmptyReturnsAnEmptySummary(testCase)
            summary = adaptive_optopatch.summarize_aotf_calibration([], [], 0.01);

            testCase.verifyFalse(summary.available);
            testCase.verifyEmpty(summary.voltage_V);
            testCase.verifyEmpty(summary.irradiance_at_voltage);
            testCase.verifyEmpty(summary.voltage_for_irradiance);
        end

        %% --- E / F / G. grouping, statistics, sorting ------------------

        function repeatedVoltagesAreGrouped(testCase)
            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                [0.5 0.5 0.5 1 1 1 1.5 1.5 1.5], ...
                [0.12 0.13 0.12 0.41 0.40 0.42 0.89 0.91 0.90], 0.010220);

            testCase.verifyEqual(summary.voltage_V, [0.5; 1; 1.5], ...
                'AbsTol', testCase.TOL);
            testCase.verifyEqual(summary.n_per_voltage, [3; 3; 3]);
            testCase.verifyEqual(height(summary.calibration_table), 3);
            testCase.verifyEqual(summary.calibration_table.Properties.VariableNames, ...
                {'AOTF_V', 'N', 'MeanPower_mW', 'SDPower_mW', ...
                 'MeanIrradiance_mW_mm2', 'SDIrradiance_mW_mm2'});
        end

        function meanAndSampleStandardDeviationAreCorrect(testCase)
            power = [0.12 0.13 0.12];
            area_mm2 = 0.010220;

            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                [0.5 0.5 0.5], power, area_mm2);

            testCase.verifyEqual(summary.mean_power_mW, mean(power), ...
                'AbsTol', testCase.TOL);
            % Sample SD, i.e. the N-1 normalisation MATLAB's std uses by default.
            testCase.verifyEqual(summary.std_power_mW, std(power), ...
                'AbsTol', testCase.TOL);
            testCase.verifyEqual(summary.std_power_mW, ...
                sqrt(sum((power - mean(power)).^2) / (numel(power) - 1)), ...
                'AbsTol', testCase.TOL);
            testCase.verifyEqual(summary.mean_irradiance_mW_mm2, ...
                mean(power / area_mm2), 'AbsTol', 1e-9);
            testCase.verifyEqual(summary.std_irradiance_mW_mm2, ...
                std(power / area_mm2), 'AbsTol', 1e-9);
        end

        function standardDeviationIsNaNForASingleReading(testCase)
            % One reading says nothing about reproducibility. Reporting 0 would
            % claim that it does.
            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                [1 2 2], [0.1 0.2 0.22], 0.01);

            testCase.verifyEqual(summary.n_per_voltage, [1; 2]);
            testCase.verifyTrue(isnan(summary.std_power_mW(1)));
            testCase.verifyTrue(isnan(summary.std_irradiance_mW_mm2(1)));
            testCase.verifyFalse(isnan(summary.std_power_mW(2)));
        end

        function calibrationTableSortsByIncreasingVoltage(testCase)
            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                [1.5 0.5 1 0.5 1.5 1], [0.9 0.12 0.4 0.13 0.91 0.41], 0.01);

            testCase.verifyEqual(summary.calibration_table.AOTF_V, [0.5; 1; 1.5], ...
                'AbsTol', testCase.TOL);
            testCase.verifyTrue(all(diff(summary.calibration_table.AOTF_V) > 0));
        end

        function zeroVoltIsTreatedLikeAnyOtherPoint(testCase)
            % Leakage is real, so a measured 0 V reading is data, and an
            % unmeasured 0 V point must not be invented.
            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                [0 0 1 1], [0.005 0.006 0.4 0.41], 0.01);

            testCase.verifyEqual(summary.voltage_V, [0; 1], 'AbsTol', testCase.TOL);
            testCase.verifyGreaterThan(summary.mean_irradiance_mW_mm2(1), 0);

            withoutZero = adaptive_optopatch.summarize_aotf_calibration( ...
                [1 1 2 2], [0.4 0.41 0.8 0.82], 0.01);
            testCase.verifyEqual(withoutZero.voltage_V, [1; 2], ...
                'AbsTol', testCase.TOL);
            testCase.verifyTrue(isnan(withoutZero.irradiance_at_voltage(0)));
        end

        %% --- H. nonlinear response ------------------------------------

        function nonlinearResponseIsNotForcedLinear(testCase)
            voltage = [0, 0.5, 1, 1.5, 2];
            power = 0.001 + 0.5 * voltage.^3;      % strongly convex

            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                voltage, power, 0.01);

            % The interpolant passes through every measured mean exactly.
            testCase.verifyEqual( ...
                summary.irradiance_at_voltage(voltage(:)), ...
                summary.mean_irradiance_mW_mm2, 'AbsTol', 1e-9);

            % A straight line cannot, which is what "not forced linear" means.
            line = polyval(polyfit(voltage, summary.mean_irradiance_mW_mm2', 1), ...
                voltage)';
            lineResidual = max(abs(line - summary.mean_irradiance_mW_mm2));
            testCase.verifyGreaterThan(lineResidual, ...
                0.05 * max(summary.mean_irradiance_mW_mm2));
        end

        %% --- I / J. forward interpolation and no extrapolation --------

        function forwardInterpolationIsShapePreservingPchip(testCase)
            voltage = [0.5 1 1.5 2];
            power = [0.12 0.41 0.89 1.9];

            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                voltage, power, 0.01);

            query = [0.75, 1.25, 1.75];
            expected = interp1(summary.voltage_V, ...
                summary.mean_irradiance_mW_mm2, query, "pchip", NaN);

            testCase.verifyEqual(summary.irradiance_at_voltage(query), ...
                expected, 'AbsTol', 1e-9);

            % Distinct from linear interpolation on this convex curve, so the
            % method is genuinely pchip and not a linear stand-in.
            linear = interp1(summary.voltage_V, ...
                summary.mean_irradiance_mW_mm2, query, "linear", NaN);
            testCase.verifyGreaterThan(max(abs(expected - linear)), 1e-6);
        end

        function queriesOutsideTheCalibratedRangeReturnNaN(testCase)
            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                [0.5 1 1.5], [0.12 0.41 0.89], 0.01);

            testCase.verifyTrue(isnan(summary.irradiance_at_voltage(0.49)));
            testCase.verifyTrue(isnan(summary.irradiance_at_voltage(1.51)));
            testCase.verifyTrue(isnan(summary.irradiance_at_voltage(-1)));
            testCase.verifyTrue(isnan(summary.irradiance_at_voltage(100)));

            % Endpoints themselves are in range.
            testCase.verifyFalse(isnan(summary.irradiance_at_voltage(0.5)));
            testCase.verifyFalse(isnan(summary.irradiance_at_voltage(1.5)));
        end

        function oneVoltageGivesNoInterpolators(testCase)
            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                [1 1 1], [0.4 0.41 0.39], 0.01);

            testCase.verifyTrue(summary.available);
            testCase.verifyEmpty(summary.irradiance_at_voltage);
            testCase.verifyEmpty(summary.voltage_for_irradiance);
        end

        %% --- K / L. inverse lookup ------------------------------------

        function inverseLookupWorksForAMonotonicCalibration(testCase)
            voltage = [0.5 1 1.5];
            power = [0.12 0.41 0.89];
            area_mm2 = 0.01;

            summary = adaptive_optopatch.summarize_aotf_calibration( ...
                voltage, power, area_mm2);

            testCase.verifyTrue(summary.monotonic);
            testCase.verifyNotEmpty(summary.voltage_for_irradiance);

            % Round trip: a voltage's irradiance maps back to that voltage.
            for v = voltage
                I = summary.irradiance_at_voltage(v);
                testCase.verifyEqual(summary.voltage_for_irradiance(I), v, ...
                    'AbsTol', 1e-9);
            end

            % And no extrapolation on the way back either.
            testCase.verifyTrue(isnan(summary.voltage_for_irradiance(1e6)));
            testCase.verifyTrue(isnan(summary.voltage_for_irradiance(0)));
        end

        function nonMonotonicCalibrationDisablesInverseAndWarns(testCase)
            % Mean irradiance dips in the middle.
            voltage = [0.5 1 1.5];
            power = [0.5 0.2 0.9];

            summary = testCase.verifyWarning(@() ...
                adaptive_optopatch.summarize_aotf_calibration( ...
                    voltage, power, 0.01), ...
                'adaptive_optopatch:NonMonotonicAotfCalibration');

            testCase.verifyFalse(summary.monotonic);
            testCase.verifyEmpty(summary.voltage_for_irradiance);

            % Raw data preserved, and nothing re-sorted to hide the dip.
            testCase.verifyEqual(summary.power_mW, power(:), 'AbsTol', testCase.TOL);
            testCase.verifyEqual(summary.voltage_V, voltage(:), ...
                'AbsTol', testCase.TOL);
            testCase.verifyNotEmpty(summary.irradiance_at_voltage);
            testCase.verifyNotEmpty(summary.monotonicity_note);
        end

        function flatCalibrationIsNotStrictlyMonotonic(testCase)
            % Equal means are not invertible either, so "strictly" matters.
            summary = testCase.verifyWarning(@() ...
                adaptive_optopatch.summarize_aotf_calibration( ...
                    [1 2], [0.4 0.4], 0.01), ...
                'adaptive_optopatch:NonMonotonicAotfCalibration');

            testCase.verifyFalse(summary.monotonic);
            testCase.verifyEmpty(summary.voltage_for_irradiance);
        end

        %% --- M. missing physical calibration --------------------------

        function snapWithoutPhysicalCalibrationFailsClearly(testCase)
            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;

            % An old snap: img and bin, but no pixel_to_sample_um at all.
            path = testCase.writeSnap(folder, 'old_snap.mat', ...
                struct('img', ones(8, 8), 'bin', 1, 'name', 'Old Camera'));

            testCase.verifyError( ...
                @() adaptive_optopatch.load_calibration_snap(path), ...
                'adaptive_optopatch:SnapHasNoPhysicalCalibration');
        end

        function snapWithEmptyCalibrationFailsTheSameWay(testCase)
            % An uncalibrated camera: the field exists but is empty. Same answer
            % as absent, because both mean "no measurement".
            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            path = testCase.writeSnap(folder, 'uncalibrated.mat', ...
                struct('img', ones(8, 8), 'pixel_to_sample_um', []));

            testCase.verifyError( ...
                @() adaptive_optopatch.load_calibration_snap(path), ...
                'adaptive_optopatch:SnapHasNoPhysicalCalibration');
        end

        function malformedOrSingularCalibrationIsRejected(testCase)
            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;

            wrongSize = testCase.writeSnap(folder, 'wrong_size.mat', ...
                struct('img', ones(8, 8), 'pixel_to_sample_um', [0.4 0 0]));
            testCase.verifyError( ...
                @() adaptive_optopatch.load_calibration_snap(wrongSize), ...
                'adaptive_optopatch:BadSnapPhysicalCalibration');

            notFinite = testCase.writeSnap(folder, 'not_finite.mat', ...
                struct('img', ones(8, 8), ...
                       'pixel_to_sample_um', [0.4 0; 0 NaN]));
            testCase.verifyError( ...
                @() adaptive_optopatch.load_calibration_snap(notFinite), ...
                'adaptive_optopatch:BadSnapPhysicalCalibration');

            singular = testCase.writeSnap(folder, 'singular.mat', ...
                struct('img', ones(8, 8), ...
                       'pixel_to_sample_um', [0.4 0.4; 0.4 0.4]));
            testCase.verifyError( ...
                @() adaptive_optopatch.load_calibration_snap(singular), ...
                'adaptive_optopatch:SingularSnapPhysicalCalibration');
        end

        function missingFileAndWrongExtensionAreRejected(testCase)
            testCase.verifyError(@() adaptive_optopatch.load_calibration_snap( ...
                "no_such_snap_anywhere.mat"), ...
                'adaptive_optopatch:MissingCalibrationSnap');

            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            tiff = fullfile(folder, 'snap.tiff');
            imwrite(uint8(zeros(4, 4)), tiff);
            testCase.verifyError( ...
                @() adaptive_optopatch.load_calibration_snap(tiff), ...
                'adaptive_optopatch:CalibrationSnapMatRequired');
        end

        %% --- segmentation ---------------------------------------------

        function segmentationFindsTheHalfContrastFootprint(testCase)
            [image, rows, columns] = testCase.syntheticPatch(100, 1100);

            segmentation = adaptive_optopatch.segment_illumination_patch(image);

            % Background 100, plateau 1100, so the 50% level is 600.
            testCase.verifyEqual(segmentation.background_level, 100, ...
                'AbsTol', testCase.TOL);
            testCase.verifyEqual(segmentation.plateau_level, 1100, ...
                'AbsTol', testCase.TOL);
            testCase.verifyEqual(segmentation.threshold_value, 600, ...
                'AbsTol', testCase.TOL);

            expected = false(size(image));
            expected(rows, columns) = true;
            testCase.verifyEqual(segmentation.mask, expected);
            testCase.verifyEqual(nnz(segmentation.mask), ...
                numel(rows) * numel(columns));
        end

        function thresholdFractionMovesTheEdge(testCase)
            % A linear ramp inside the patch, so a lower fraction must include
            % strictly more pixels.
            image = 100 * ones(100, 120);
            image(21:80, 31:110) = repmat(linspace(200, 1100, 80), 60, 1);

            loose = adaptive_optopatch.segment_illumination_patch(image, ...
                ThresholdFraction=0.4);
            tight = adaptive_optopatch.segment_illumination_patch(image, ...
                ThresholdFraction=0.6);

            testCase.verifyEqual(loose.threshold_fraction, 0.4);
            testCase.verifyGreaterThan(nnz(loose.mask), nnz(tight.mask));
            testCase.verifyLessThan(loose.threshold_value, tight.threshold_value);
        end

        function thresholdFractionIsRangeChecked(testCase)
            image = testCase.syntheticPatch(100, 1100);

            testCase.verifyError(@() adaptive_optopatch.segment_illumination_patch( ...
                image, ThresholdFraction=0), 'MATLAB:validators:mustBeGreaterThan');
            testCase.verifyError(@() adaptive_optopatch.segment_illumination_patch( ...
                image, ThresholdFraction=1), 'MATLAB:validators:mustBeLessThan');
        end

        function segmentationKeepsOneComponentAndFillsHoles(testCase)
            [image, rows, columns] = testCase.syntheticPatch(100, 1100);
            image(40:45, 50:55) = 100;     % interior dropout, must be filled
            image(5, 5) = 1100;            % stray bright speck, must be dropped

            segmentation = adaptive_optopatch.segment_illumination_patch(image);

            expected = false(size(image));
            expected(rows, columns) = true;
            testCase.verifyEqual(segmentation.mask, expected);
        end

        function uniformImageWithNoContrastFailsClearly(testCase)
            testCase.verifyError(@() adaptive_optopatch.segment_illumination_patch( ...
                500 * ones(50, 50)), 'adaptive_optopatch:NoIlluminationContrast');
        end

        %% --- plateau percentile vs patch coverage ---------------------
        % signal is the median of the pixels above PlateauPercentile, so that
        % set must lie inside the patch, which needs coverage above (100-P)%.
        % The default of 99 therefore covers anything above about 1%. These
        % tests pin both the working range and where it gives out.

        function defaultHandlesASmallPatchAroundFivePercentCoverage(testCase)
            % The primary use case: a compact ~100 um patch in a large frame.
            % At the old default of 80 this returned signal == background and
            % refused a perfectly good snap.
            [image, side, coverage] = testCase.patchImage(512, 0.06);
            testCase.verifyGreaterThan(coverage, 0.05);
            testCase.verifyLessThan(coverage, 0.10);

            segmentation = adaptive_optopatch.segment_illumination_patch(image);

            testCase.verifyEqual(segmentation.plateau_percentile, 99);
            testCase.verifyGreaterThan(segmentation.plateau_level, ...
                segmentation.background_level);
            % Plateau found inside the patch, not in the background.
            testCase.verifyGreaterThan(segmentation.plateau_level, 1000);
            % Area within one pixel row/column of the true patch.
            testCase.verifyEqual(nnz(segmentation.mask), side^2, ...
                'AbsTol', 2 * side);
        end

        function defaultStillHandlesAVerySmallPatchAtOneToTwoPercent(testCase)
            % The documented floor. 1% is exactly where the top percentile
            % stops being entirely inside the patch, so it is the tightest
            % case the default is claimed to handle.
            for coverage = [0.02, 0.015, 0.01]
                [image, side] = testCase.patchImage(512, coverage);

                segmentation = adaptive_optopatch.segment_illumination_patch(image);

                testCase.verifyGreaterThan(segmentation.plateau_level, 1000, ...
                    sprintf('coverage %.1f%%: plateau fell into background', ...
                        100 * coverage));
                testCase.verifyEqual(nnz(segmentation.mask), side^2, ...
                    'AbsTol', 2 * side, sprintf('coverage %.1f%%', 100 * coverage));
            end
        end

        function defaultStillHandlesALargePatch(testCase)
            % Raising the percentile must not break the case the old default
            % was chosen for.
            for coverage = [0.30, 0.50]
                [image, side] = testCase.patchImage(512, coverage);

                segmentation = adaptive_optopatch.segment_illumination_patch(image);

                testCase.verifyGreaterThan(segmentation.plateau_level, 1000);
                testCase.verifyEqual(nnz(segmentation.mask), side^2, ...
                    'AbsTol', 2 * side, sprintf('coverage %.0f%%', 100 * coverage));
            end
        end

        function plateauPercentileOverrideStillApplies(testCase)
            % 0.4% coverage sits below the default's floor but above 99.5's, so
            % the override is what makes the difference here.
            [image, side] = testCase.patchImage(512, 0.004);

            usingDefault = adaptive_optopatch.segment_illumination_patch(image);
            overridden = adaptive_optopatch.segment_illumination_patch(image, ...
                PlateauPercentile=99.5);

            testCase.verifyEqual(usingDefault.plateau_percentile, 99);
            testCase.verifyEqual(overridden.plateau_percentile, 99.5);

            % The override puts the plateau estimate inside the patch; the
            % default's is still a blend with background.
            testCase.verifyGreaterThan(overridden.plateau_level, 1000);
            testCase.verifyLessThan(usingDefault.plateau_level, 200);

            % And only the override recovers the footprint exactly.
            testCase.verifyEqual(nnz(overridden.mask), side^2);
            testCase.verifyGreaterThan(nnz(usingDefault.mask), side^2);
        end

        function overrideReachesThroughTheTopLevelUtility(testCase)
            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            [image, side] = testCase.patchImage(512, 0.004);
            J = testCase.J_SHEARED;
            path = testCase.writeSnap(folder, 'tiny_patch.mat', ...
                struct('img', image, 'pixel_to_sample_um', J));

            overridden = measure_illumination_irradiance(string(path), ...
                PlateauPercentile=99.5, Visible="off");
            usingDefault = measure_illumination_irradiance(string(path), ...
                Visible="off");
            close all force

            testCase.verifyEqual(overridden.illuminated_pixels, side^2);
            testCase.verifyGreaterThan(usingDefault.illuminated_pixels, side^2);

            % The area still comes from the determinant either way - only the
            % pixel count the override changed differs.
            testCase.verifyEqual(overridden.pixel_area_um2, abs(det(J)), ...
                'AbsTol', testCase.TOL);
            testCase.verifyEqual(overridden.area_mm2, ...
                side^2 * abs(det(J)) / 1e6, 'AbsTol', testCase.TOL);
        end

        function coverageBelowTheFloorOverestimatesQuietlyAndIsADocumentedLimit(testCase)
            % KNOWN LIMITATION, pinned so that a future change which fixes it
            % fails here and gets the documentation updated with it.
            %
            % Below about (100-P)/2 percent coverage the plateau estimate is a
            % blend of patch and background. That puts the threshold just above
            % background, so the mask comes out a few percent too large and no
            % error is raised. The contrast guard only catches the case where
            % the two levels are not separated AT ALL.
            [image, side] = testCase.patchImage(512, 0.002);

            segmentation = adaptive_optopatch.segment_illumination_patch(image);

            % Plateau contaminated rather than inside the patch.
            testCase.verifyLessThan(segmentation.plateau_level, 200);
            testCase.verifyGreaterThan(segmentation.plateau_level, ...
                segmentation.background_level);

            % Quietly too large, and modestly so - not garbage, which is
            % exactly what makes it worth documenting.
            overestimate = nnz(segmentation.mask) / side^2;
            testCase.verifyGreaterThan(overestimate, 1);
            testCase.verifyLessThan(overestimate, 1.5);

            % 99.5 does not rescue this coverage either; the floor moves, it
            % does not vanish.
            tighter = adaptive_optopatch.segment_illumination_patch(image, ...
                PlateauPercentile=99.5);
            testCase.verifyLessThan(tighter.plateau_level, 200);
        end

        function contrastGuardStillFiresWhenLevelsAreNotSeparated(testCase)
            % The actionable error is unchanged by the new default, and its
            % message still says what to do.
            testCase.verifyError(@() adaptive_optopatch.segment_illumination_patch( ...
                500 * ones(64, 64)), 'adaptive_optopatch:NoIlluminationContrast');

            try
                adaptive_optopatch.segment_illumination_patch(500 * ones(64, 64));
                testCase.verifyFail('expected a contrast error');
            catch err
                testCase.verifySubstring(err.message, 'PlateauPercentile');
                testCase.verifySubstring(err.message, 'crop the snap');
            end
        end

        %% --- N. one end-to-end pass, no dialogs ----------------------

        function endToEndWithExplicitArgumentsAndNoFigures(testCase)
            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            [image, rows, columns] = testCase.syntheticPatch(100, 1100);
            J = testCase.J_SHEARED;
            path = testCase.writeSnap(folder, '143022_power_calibration.mat', ...
                struct('img', image, 'bin', 1, 'name', 'Kinetix', ...
                       'pixel_to_sample_um', J));

            result = testCase.verifyWarningFree(@() measure_illumination_irradiance( ...
                string(path), ...
                AOTF_V=[0.5 0.5 0.5 1 1 1 1.5 1.5 1.5], ...
                Power_mW=[0.12 0.13 0.12 0.41 0.40 0.42 0.89 0.91 0.90], ...
                Visible="off"));
            close all force

            expectedPixels = numel(rows) * numel(columns);
            testCase.verifyEqual(result.illuminated_pixels, expectedPixels);
            testCase.verifyEqual(result.pixel_area_um2, abs(det(J)), ...
                'AbsTol', testCase.TOL);
            testCase.verifyEqual(result.area_mm2, ...
                expectedPixels * abs(det(J)) / 1e6, 'AbsTol', testCase.TOL);

            % Irradiance is power over that area, per reading.
            testCase.verifyEqual(result.irradiance_mW_mm2(1), ...
                0.12 / result.area_mm2, 'AbsTol', 1e-9);

            testCase.verifyEqual(result.voltage_V, [0.5; 1; 1.5], ...
                'AbsTol', testCase.TOL);
            testCase.verifyTrue(result.monotonic);
            testCase.verifyNotEmpty(result.irradiance_at_voltage);
            testCase.verifyNotEmpty(result.voltage_for_irradiance);
            testCase.verifyEqual(result.snap_path, string(path));
        end

        function areaOnlyCallReturnsEmptyCalibrationFields(testCase)
            folder = testCase.applyFixture( ...
                matlab.unittest.fixtures.TemporaryFolderFixture).Folder;
            image = testCase.syntheticPatch(100, 1100);
            path = testCase.writeSnap(folder, 'area_only.mat', ...
                struct('img', image, 'pixel_to_sample_um', testCase.J_SHEARED));

            result = measure_illumination_irradiance(string(path), Visible="off");
            close all force

            testCase.verifyGreaterThan(result.area_mm2, 0);
            testCase.verifyEmpty(result.aotf_voltage_V);
            testCase.verifyEmpty(result.power_mW);
            testCase.verifyEmpty(result.irradiance_mW_mm2);
            testCase.verifyEmpty(result.voltage_V);
            testCase.verifyEmpty(result.irradiance_at_voltage);
            testCase.verifyEmpty(result.voltage_for_irradiance);
        end
    end
end
