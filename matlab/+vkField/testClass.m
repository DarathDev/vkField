simulation = vkField.Simulation();

simulation.Elements.Count = uint32(3);
simulation.Elements.Positions = single([0, 0, 0; 0, 0, 1e-3; 0, 0, 2e-3]');
simulation.Elements.Normals = single(repmat([0; 0; 1], 1, 3));
simulation.Elements.Sizes = single(repmat([2.2e-4; 2.2e-4], 1, 3));
simulation.Elements.Apodizations = single(ones(1, 3));
simulation.Elements.Delays = single(zeros(1, 3));

tx = vkField.Transmission();
tx.Count = uint32(3);
tx.Indices = int32([1, 2, 3]);
tx.Apodizations = single([1, 1, 1]);
tx.Delays = single([0, 0, 0]);
simulation.Transmissions = tx;

rx = vkField.ReceiveChannel();
rx.Count = uint32(1);
rx.Indices = int32(2);
rx.Apodizations = single(1);
rx.Delays = single(0);
simulation.ReceiveChannels = rx;

simulation.Scatters.Count = uint32(1);
simulation.Scatters.Positions = single([0; 0; 20e-3]);
simulation.Scatters.Amplitudes = single(1);

% mex("matlab\vkField_lib.cpp9", "matlab\vkField_lib.lib", "-g", "-R2018a", "-output", "matlab\vkField_mex");
vkField_mex(simulation);
