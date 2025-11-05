# PeerWave Build and Start Script
# Usage:
#   .\build-and-start.ps1           -> Full build (Flutter + Docker)
#   .\build-and-start.ps1 -quick    -> Quick update (Flutter only, hot copy to container)
#   .\build-and-start.ps1 -flutter  -> Flutter build only (no Docker)
#   .\build-and-start.ps1 -docker   -> Docker rebuild only (no Flutter)

param(
    [switch]$quick,
    [switch]$flutter,
    [switch]$docker
)

Write-Host "========================================" -ForegroundColor Cyan
Write-Host " PeerWave Build & Start" -ForegroundColor Cyan
Write-Host "========================================" -ForegroundColor Cyan
Write-Host ""

# Determine build mode
$mode = "full"
if ($quick) { $mode = "quick" }
elseif ($flutter) { $mode = "flutter" }
elseif ($docker) { $mode = "docker" }

Write-Host " Mode: $mode" -ForegroundColor Yellow
Write-Host ""

# ===========================================
# QUICK MODE: Flutter build + hot copy
# ===========================================
if ($mode -eq "quick") {
    Write-Host " [1/3] Building Flutter Web..." -ForegroundColor Yellow
    Set-Location client
    flutter build web --debug --no-wasm-dry-run
    if ($LASTEXITCODE -ne 0) {
        Write-Host " Flutter build failed!" -ForegroundColor Red
        Set-Location ..
        exit 1
    }
    Set-Location ..
    Write-Host " Flutter built" -ForegroundColor Green
    
    Write-Host ""
    Write-Host " [2/3] Hot-copying to container..." -ForegroundColor Yellow
    
    # Check if container exists
    $containerExists = docker ps -a --filter "name=peerwave-server" --format "{{.Names}}"
    if (-not $containerExists) {
        Write-Host " Container doesn't exist! Starting..." -ForegroundColor Yellow
        docker-compose up -d
        Start-Sleep -Seconds 3
    } else {
        # Stop container to avoid file locking issues
        Write-Host "   Stopping container..." -ForegroundColor Gray
        docker-compose stop peerwave-server | Out-Null
        Start-Sleep -Seconds 1
    }
    
    # Delete old web folder in container
    Write-Host "   Deleting old web folder..." -ForegroundColor Gray
    docker exec peerwave-server rm -rf /app/web 2>$null
    
    # Add cache-busting timestamp to index.html
    Write-Host "   Adding cache-busting..." -ForegroundColor Gray
    $timestamp = (Get-Date).Ticks
    $indexPath = "client/build/web/index.html"
    $content = Get-Content $indexPath -Raw
    $content = $content -replace '(main\.dart\.js)', "`$1?v=$timestamp"
    $content | Set-Content $indexPath -NoNewline
    
    # Copy new build to container
    Write-Host "   Copying new build..." -ForegroundColor Gray
    docker cp client/build/web peerwave-server:/app/
    
    if ($LASTEXITCODE -ne 0) {
        Write-Host " Copy failed!" -ForegroundColor Red
        exit 1
    }
    
    Write-Host " Hot-copy complete" -ForegroundColor Green
    
    Write-Host ""
    Write-Host " [3/3] Starting container..." -ForegroundColor Yellow
    docker-compose up -d peerwave-server
    
    Write-Host ""
    Write-Host " QUICK UPDATE DONE!" -ForegroundColor Green
    Write-Host " http://localhost:3000" -ForegroundColor Cyan
    Write-Host ""
    
    Start-Sleep -Seconds 2
    docker-compose ps
    exit 0
}

# ===========================================
# FLUTTER MODE: Build Flutter only
# ===========================================
if ($mode -eq "flutter" -or $mode -eq "full") {
    Write-Host " [FLUTTER] Building Flutter Web..." -ForegroundColor Yellow
    Set-Location client
    flutter clean | Out-Null
    flutter build web --debug --no-wasm-dry-run
    if ($LASTEXITCODE -ne 0) {
        Write-Host " Flutter build failed!" -ForegroundColor Red
        Set-Location ..
        exit 1
    }
    Set-Location ..

    if (-not (Test-Path "client/build/web/index.html")) {
        Write-Host " Build incomplete!" -ForegroundColor Red
        exit 1
    }
    Write-Host " Flutter built" -ForegroundColor Green
    
    Write-Host ""
    Write-Host " [FLUTTER] Copying to server/web..." -ForegroundColor Yellow
    if (Test-Path "server/web") {
        Remove-Item -Recurse -Force server/web/*
    }
    New-Item -ItemType Directory -Force -Path server/web | Out-Null
    Copy-Item -Recurse -Force client/build/web/* server/web/

    if (-not (Test-Path "server/web/index.html")) {
        Write-Host " Copy failed!" -ForegroundColor Red
        exit 1
    }

    # Add cache-busting timestamp to index.html
    $timestamp = (Get-Date).Ticks
    $indexPath = "server/web/index.html"
    $content = Get-Content $indexPath -Raw
    $content = $content -replace '(main\.dart\.js)', "`$1?v=$timestamp"
    $content | Set-Content $indexPath -NoNewline

    Write-Host " Files copied" -ForegroundColor Green
}

# Exit here if flutter-only mode
if ($mode -eq "flutter") {
    Write-Host ""
    Write-Host " FLUTTER BUILD DONE!" -ForegroundColor Green
    Write-Host " Files ready in server/web/" -ForegroundColor Cyan
    Write-Host ""
    exit 0
}

# ===========================================
# DOCKER MODE: Build and start containers
# ===========================================
if ($mode -eq "docker" -or $mode -eq "full") {
    Write-Host ""
    Write-Host " [DOCKER] Building Docker image..." -ForegroundColor Yellow
    docker-compose build
    if ($LASTEXITCODE -ne 0) {
        Write-Host " Docker build failed!" -ForegroundColor Red
        exit 1
    }
    Write-Host " Docker built" -ForegroundColor Green

    Write-Host ""
    Write-Host " [DOCKER] Starting containers..." -ForegroundColor Yellow
    docker-compose up -d
    if ($LASTEXITCODE -ne 0) {
        Write-Host " Start failed!" -ForegroundColor Red
        exit 1
    }
}

Write-Host ""
Write-Host "========================================" -ForegroundColor Green
Write-Host " DONE!" -ForegroundColor Green
Write-Host "========================================" -ForegroundColor Green
Write-Host " http://localhost:3000" -ForegroundColor Cyan
Write-Host ""

Start-Sleep -Seconds 3
docker-compose ps
