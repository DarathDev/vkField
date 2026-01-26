simulation = vkField.Simulation();

simulation.TransmitElements(1).Position = [0, 0, 0];
simulation.TransmitElements(2).Position = [0, 0, 1e-3];
simulation.TransmitElements(3).Position = [0, 0, 2e-3];

% mex("matlab\vkField_lib.cpp9", "matlab\vkField_lib.lib", "-g", "-R2018a", "-output", "matlab\vkField_mex");
vkField_mex(simulation);