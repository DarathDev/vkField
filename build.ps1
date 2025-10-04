param(
    [string]$Configuration = "Release"
)

# Set the make command based on OS
if ($IsWindows) {
    $makeCmd = "nmake"
}
else {
    $makeCmd = "make"
}

Write-Host "Running $makeCmd with configuration: $Configuration"

# Run make with the specified configuration
if ($Configuration -eq "Release") {
    if (-not (Test-Path -Path "bin/release")) {
        New-Item -ItemType Directory -Path "bin/release" | Out-Null
    }
    & $makeCmd bin/release/vkField.lib
    Copy-Item -Path "bin/release/vkField.lib" -Destination "matlab/vkField_lib.lib" -Force
}
elseif ($Configuration -eq "Debug") {
    if (-not (Test-Path -Path "bin/debug")) {
        New-Item -ItemType Directory -Path "bin/debug" | Out-Null
    }
    & $makeCmd bin/debug/vkField.lib
    Copy-Item -Path "bin/debug/vkField.lib" -Destination "matlab/vkField_lib.lib" -Force
}
else {
    Write-Error "Invalid Configuration"
    return
}


if ($LASTEXITCODE -ne 0) {
    Write-Error "Build failed with exit code $LASTEXITCODE"
    exit $LASTEXITCODE
}
else {
    Write-Host "Build succeeded."
}
