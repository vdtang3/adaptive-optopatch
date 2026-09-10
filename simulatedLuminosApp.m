function app=simulatedLuminosApp(varargin)
%SIMULATEDLUMINOSAPP Create a no-hardware Luminos-compatible test object.
app=adaptive_optopatch.testing.make_simulated_luminos(varargin{:});
end
