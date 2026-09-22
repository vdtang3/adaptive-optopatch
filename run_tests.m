function results = run_tests(tier)
%RUN_TESTS Run the Adaptive Optopatch MATLAB tests, by tier.
%
%   run_tests("core")          fast tests that gate ordinary development
%   run_tests("extended")      slower or less frequently touched science
%   run_tests("legacy")        the MATLAB-only GUI, still supported
%   run_tests("performance")   benchmarks, kept apart from correctness
%   run_tests("all")           everything, which is also run_tests()
%
%   WHY TIERS
%   The suite grew across several architectural generations and running all
%   of it after every edit costs minutes, most of it spent on simulated
%   acquisitions and MATLAB figures that a React-side or controller-side
%   change cannot possibly have broken. CORE is what to run after a normal
%   edit; it is deliberately the tier that owns hardware safety, DMD
%   targeting, execution ownership and failure cleanup, because those are
%   the failures that are expensive to discover later.
%
%   Nothing is excluded from "all". A tier says how often a suite is worth
%   running, never whether it is worth keeping.
%
%   ADDING A SUITE
%   Every class under tests/ must appear in exactly one tier below, and
%   run_tests errors if one does not. That is deliberate: a new suite that
%   nobody assigned would otherwise silently never run in CI.
arguments
    tier (1,1) string {mustBeMember(tier, ...
        ["core","extended","legacy","performance","all"])} = "all"
end

root = fileparts(mfilename("fullpath"));
testFolder = fullfile(root,"tests");
originalPath = path;
cleanup = onCleanup(@()path(originalPath)); %#ok<NASGU>
addpath(root,testFolder);

suite = testsuite(testFolder);
tiers = tier_manifest();
verify_every_suite_is_assigned(testFolder,tiers);

if tier ~= "all"
    wanted = tiers.(tier);
    classNames = arrayfun(@suite_class_name,suite);
    suite = suite(ismember(classNames,wanted));
end

fprintf("Adaptive Optopatch tests: %s (%d tests)\n",tier,numel(suite));
results = run(suite);
assertSuccess(results);
end

% -----------------------------------------------------------------------
% The manifest
% -----------------------------------------------------------------------
function tiers = tier_manifest()
%TIER_MANIFEST Which tier each suite belongs to, and why.

% CORE - run this after a normal edit.
%   The controller/action contract a frontend depends on, the plan and
%   reference lifecycle, and every suite that protects the rig: DMD
%   targeting and ownership, waveform ownership, output suppression,
%   modality isolation, independent accounting, and cleanup after a
%   failure. Plus one inexpensive end-to-end simulation smoke test.
tiers.core = [ ...
    % Controller, actions and the React-facing boundary
    "TestAdaptiveOptopatchController"
    "TestAdaptiveOptopatchActions"
    "TestAdaptiveOptopatchPlanWorkflow"
    "TestLuminosSharedController"
    "TestAdaptiveOptopatchReferenceChooser"
    "TestAdaptiveOptopatchReferenceTransport"
    "TestNewFovLifecycle"
    "TestAdaptiveOptopatchPreviews"
    "TestRunProgressObservability"
    "TestSpatialPreviewGeometry"
    "TestCellDecisionDraft"
    "TestBlueVoltageCalibration"
    "TestReferenceSnapshotIngest"
    % Protocol semantics, cheap and depended on by everything below
    "TestProtocolResolution"
    "TestLuminosWaveformConfiguration"
    "TestLuminosHardwareResolution"
    "TestCameraFrameCadence"
    % DMD targeting: mask construction, programming, execution state,
    % ownership across acquisition startup, calibration identity, and what
    % the archive records about the pattern that was programmed.
    % These are layered on purpose; see Phase 3 of docs/notebook.md.
    "TestDmdCameraMaskRemapping"
    "TestDmdFlutExecution"
    "TestDmdStaticTargetExecutionState"
    "TestDmdOwnershipAcrossAcquisition"
    "TestDmdCalibrationIdentity"
    "TestDmdProgrammedMaskProvenance"
    "TestBlueMaskAdjustment"
    "TestBlueMaskEventExecutability"
    "TestBlueDmdAdvisoryPolicy"
    "TestTargetSelectionAuthority"
    % Hardware safety, four independent layers
    "TestWaveformOwnershipRegressions"
    "TestOnePhotonOutputSuppression"
    "TestOnePhotonModalityIsolation"
    "TestStimulationAccounting"
    "TestStimulationSafetyCleanup"
    "TestCanonicalTerminalIdentity"
    "TestFrozenExecutionInvariants"
    % One cheap end-to-end smoke test
    "TestSimulationWorkflow"
    ];

% EXTENDED - scientifically important, but slower or rarely touched.
%   Simulated acquisitions dominate the runtime here. The two constrained
%   schedulers, the 2P scanner and its calibration, the protocol
%   generators, irradiance, and offline analysis.
tiers.extended = [ ...
    "TestManifestExecution"
    "TestFrozenRunLifecycle"
    "TestExecutionBatchWorkflow"
    "TestConstrainedRoundRobinProtocol"
    "TestStpScreenProtocol"
    "TestPulseProtocolGenerators"
    "TestMixedStimulationTimeline"
    "TestTwoPhotonPockelsVoltage"
    "TestTwoPhotonScannerCalibration"
    "TestTwoPhotonSpiralWaveforms"
    "TestIlluminationIrradiance"
    "TestInspectAcquisition"
    "TestConnectivityAnalysis"
    ];

% LEGACY UI - the MATLAB planning window, still intentionally supported.
%   Kept and kept green, but React-side work should not wait on figures
%   being constructed. TestFovWorkflowCleanup is here because every test
%   in it now drives AdaptiveOptopatchApp; its two file-format tests
%   (rejectsObsoleteFovSchema, persistsCanonicalFovAndIndependentDerived-
%   Masks) would belong in core if they were ever split out.
tiers.legacy = [ ...
    "TestGuiPanelPresentation"
    "TestPersistentSomaDrawing"
    "TestFovWorkflowCleanup"
    ];

% PERFORMANCE - benchmarks and sparse-representation regressions.
%   Separate from correctness so that a slow machine never reads as a
%   broken waveform.
tiers.performance = [ ...
    "TestEventWaveformPerformance"
    ];
end

% -----------------------------------------------------------------------
% Helpers
% -----------------------------------------------------------------------
function name = suite_class_name(test)
name = string(extractBefore(test.Name + "/","/"));
end

function verify_every_suite_is_assigned(testFolder,tiers)
listing = dir(fullfile(testFolder,"Test*.m"));
onDisk = string(erase({listing.name},".m"));
assigned = [tiers.core; tiers.extended; tiers.legacy; tiers.performance];

unassigned = setdiff(onDisk,assigned);
if ~isempty(unassigned)
    error("adaptive_optopatch:UnassignedTestSuite", ...
        "These suites are not in any tier in run_tests.m: %s. " + ...
        "Add each to core, extended, legacy or performance.", ...
        strjoin(unassigned,", "));
end

missing = setdiff(assigned,onDisk);
if ~isempty(missing)
    error("adaptive_optopatch:MissingTestSuite", ...
        "run_tests.m names suites that no longer exist: %s.", ...
        strjoin(missing,", "));
end

[names,~,index] = unique(assigned);
duplicated = names(accumarray(index,1) > 1);
if ~isempty(duplicated)
    error("adaptive_optopatch:DuplicateTestSuite", ...
        "These suites appear in more than one tier: %s.", ...
        strjoin(duplicated,", "));
end
end
