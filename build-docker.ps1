# ============================================
# PeerWave Docker Build Script (PowerShell)
# ============================================
# This script builds the Flutter web client and
# Docker image with the embedded web client
#
# Usage:
#   .\build-docker.ps1 [version] [-Push]
#
# Example:
#   .\build-docker.ps1 v1.0.0
#   .\build-docker.ps1 v1.0.0 -Push

param(
    [string]$Version = "",
    [switch]$Push = $false
)

# Enable strict mode
$ErrorActionPreference = "Stop"

# Colors for output
function Write-Color {
    param([string]$Message, [string]$Color = "White")
    Write-Host $Message -ForegroundColor $Color
}

# Script paths
$ScriptDir = $PSScriptRoot
$ClientDir = Join-Path $ScriptDir "client"
$ServerDir = Join-Path $ScriptDir "server"
$WebOutputDir = Join-Path $ServerDir "web"
$VersionConfigFile = Join-Path $ScriptDir "version_config.yaml"

# Get version from argument or version_config.yaml
if ([string]::IsNullOrEmpty($Version)) {
    if (Test-Path $VersionConfigFile) {
        $VersionLine = Get-Content $VersionConfigFile | Select-String 'version:\s*"([^"]+)"'
        if ($VersionLine) {
            $Version = $VersionLine.Matches.Groups[1].Value
        } else {
            $Version = "latest"
        }
    } else {
        $Version = "latest"
    }
}

Write-Color "============================================" "Blue"
Write-Color "PeerWave Docker Build Script" "Blue"
Write-Color "============================================" "Blue"
Write-Color "Version: $Version" "Green"
Write-Host ""

# Check prerequisites
Write-Color "Checking prerequisites..." "Yellow"

if (-not (Get-Command flutter -ErrorAction SilentlyContinue)) {
    Write-Color "ERROR: Flutter is not installed or not in PATH" "Red"
    exit 1
}

if (-not (Get-Command docker -ErrorAction SilentlyContinue)) {
    Write-Color "ERROR: Docker is not installed or not in PATH" "Red"
    exit 1
}

Write-Color "✓ Prerequisites OK" "Green"
Write-Host ""

# Step 1: Build Flutter Web Client
Write-Color "Step 1/4: Building Flutter web client..." "Yellow"
Set-Location $ClientDir

Write-Host "Running flutter pub get..."
flutter pub get

Write-Host "Generating version info..."
Set-Location $ScriptDir
dart run tools/generate_version.dart

Set-Location $ClientDir
Write-Host "Building web client (release mode)..."
flutter build web --release --web-renderer canvaskit

$WebBuildDir = Join-Path $ClientDir "build\web"
if (-not (Test-Path $WebBuildDir)) {
    Write-Color "ERROR: Flutter web build failed - build/web directory not found" "Red"
    exit 1
}

Write-Color "✓ Flutter web build complete" "Green"
Write-Host ""

# Step 2: Copy web build to server
Write-Color "Step 2/4: Copying web client to server..." "Yellow"

# Remove old web files
if (Test-Path $WebOutputDir) {
    Write-Host "Removing old web files..."
    Remove-Item -Path $WebOutputDir -Recurse -Force
}

# Copy new web files
Write-Host "Copying build/web to server/web..."
Copy-Item -Path $WebBuildDir -Destination $WebOutputDir -Recurse

Write-Color "✓ Web client copied to server/web" "Green"
Write-Host ""

# Step 3: Build Docker Image
Write-Color "Step 3/4: Building Docker image..." "Yellow"
Set-Location $ServerDir

$DockerImage = "simonzander/peerwave:$Version"
$DockerImageLatest = "simonzander/peerwave:latest"

Write-Host "Building Docker image: $DockerImage"
docker build -t $DockerImage -t $DockerImageLatest .

if ($LASTEXITCODE -ne 0) {
    Write-Color "ERROR: Docker build failed" "Red"
    exit 1
}

Write-Color "✓ Docker image built successfully" "Green"
Write-Color "  Tagged as: $DockerImage" "Green"
Write-Color "  Tagged as: $DockerImageLatest" "Green"
Write-Host ""

# Step 4: Push to Docker Hub (optional)
if ($Push) {
    Write-Color "Step 4/4: Pushing to Docker Hub..." "Yellow"
    
    Write-Host "Pushing $DockerImage..."
    docker push $DockerImage
    
    Write-Host "Pushing $DockerImageLatest..."
    docker push $DockerImageLatest
    
    if ($LASTEXITCODE -ne 0) {
        Write-Color "ERROR: Docker push failed" "Red"
        Write-Color "Make sure you're logged in: docker login" "Yellow"
        exit 1
    }
    
    Write-Color "✓ Images pushed to Docker Hub" "Green"
} else {
    Write-Color "Step 4/4: Skipping Docker Hub push" "Yellow"
    Write-Color "  (Use '.\build-docker.ps1 $Version -Push' to push)" "Yellow"
}

Write-Host ""
Write-Color "============================================" "Blue"
Write-Color "✓ Build Complete!" "Green"
Write-Color "============================================" "Blue"
Write-Host ""
Write-Color "Docker Image: $DockerImage" "Green"
Write-Host ""
Write-Color "To run locally:" "Yellow"
Write-Host "  docker-compose up -d"
Write-Host ""
Write-Color "To test the image:" "Yellow"
Write-Host "  docker run -d -p 3000:3000 $DockerImage"
Write-Host ""

# Return to original directory
Set-Location $ScriptDir
