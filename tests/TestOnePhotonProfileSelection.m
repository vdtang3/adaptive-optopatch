classdef TestOnePhotonProfileSelection < matlab.unittest.TestCase
    % Which 1P hardware profile a Luminos rig gets, and what an operator is
    % told when its rig initializer does not name a supported rig.

    methods (Test)
        function virtualUprightSelectsItsProfile(testCase)
            profile=adaptive_optopatch.one_photon_profile_for_rig( ...
                app_named("Virtual_Upright"));
            testCase.verifyEqual(profile.profile_id,"virtual_upright_488_dmd_blue");
        end

        function undeclaredRignameSaysHowToFixIt(testCase)
            % A rig JSON without "rigname" leaves Rig_Initializer.rigname as
            % [], which used to surface as "Formatted arguments must be scalar".
            for value={[],"",["Virtual_Upright" "Spinning_Upright"]}
                app=app_named(value{1});
                testCase.verifyError( ...
                    @() adaptive_optopatch.one_photon_profile_for_rig(app), ...
                    "adaptive_optopatch:UnknownRig");
            end
            try
                adaptive_optopatch.one_photon_profile_for_rig(app_named([]));
            catch failure
                testCase.verifySubstring(failure.message,"0x0");
                testCase.verifySubstring(failure.message,"""rigname""");
            end
        end

        function unsupportedRigIsNamed(testCase)
            app=app_named("Cokecan");
            testCase.verifyError( ...
                @() adaptive_optopatch.one_photon_profile_for_rig(app), ...
                "adaptive_optopatch:UnsupportedRig");
            try
                adaptive_optopatch.one_photon_profile_for_rig(app);
            catch failure
                testCase.verifySubstring(failure.message,"'Cokecan'");
            end
        end
    end
end

function app=app_named(rigName)
app=adaptive_optopatch.testing.SimulatedLuminosApp( ...
    adaptive_optopatch.testing.SimulatedLuminosDevice.empty,struct(),tempdir,rigName);
end
