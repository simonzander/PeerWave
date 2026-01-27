# Script to exclude Firebase from Windows build
# Run this before building: .\windows\exclude-firebase.ps1

$generated = "windows\flutter\generated_plugins.cmake"

if (Test-Path $generated) {
    Write-Host "Removing firebase_core from generated_plugins.cmake..."
    $content = Get-Content $generated
    $content = $content -replace '^\s*firebase_core\s*$', '  # firebase_core # EXCLUDED: Causes linker errors on Windows'
    $content | Set-Content $generated
    Write-Host "Done! firebase_core excluded from Windows build."
} else {
    Write-Host "Error: $generated not found. Run 'flutter pub get' first."
}
