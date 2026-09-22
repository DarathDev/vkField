function LoadLibraries(debug, reload)
arguments
    debug(1,1) logical = false
    reload(1,1) logical = false
end

persistent mexLoaded
if isempty(mexLoaded)
    mexLoaded = false;
end

if mexLoaded && ~reload
    return
elseif mexLoaded
    clear("ekhosMex");
    mexLoaded = false;
end

packageFolder = fileparts(mfilename("fullpath"));
matlabFolder = fileparts(packageFolder);
sourcePath = fullfile(matlabFolder, "ekhosLib.cpp");
outputPath = fullfile(matlabFolder, "ekhosMex");

if ispc
    libraryPath = fullfile(matlabFolder, "ekhosLib.lib");
elseif isunix && ~ismac
    libraryPath = fullfile(matlabFolder, "EkhosLib.a");
else
    error("Ekhos:UnsupportedPlatform", "Unsupported platform for Ekhos MEX libraries.");
end

mexArguments = {sourcePath, libraryPath, "-R2018a", "-output", outputPath};
if debug
    mexArguments = [mexArguments, {"-g"}];
else
    mexArguments = [mexArguments, {"-O"}];
end
mex(mexArguments{:});
mexLoaded = true;
end
