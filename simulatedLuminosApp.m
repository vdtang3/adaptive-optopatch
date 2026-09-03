function app=simulatedLuminosApp(varargin)
%SIMULATEDLUMINOSAPP Construct the no-hardware Luminos-compatible test app.
%   app = simulatedLuminosApp() returns the simulator used by the normal
%   Adaptive Optopatch runner interfaces. Name-value options are forwarded
%   to adaptive_optopatch.testing.make_simulated_luminos.
app=adaptive_optopatch.testing.make_simulated_luminos(varargin{:});
end
