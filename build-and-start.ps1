# PeerWave Build and Start Script
Write-Host " PeerWave Build & Start" -ForegroundColor Cyan
Write-Host ""

# Step 1: Build Flutter
Write-Host " Building Flutter Web..." -ForegroundColor Yellow
Set-Location client
flutter clean | Out-Null
flutter build web --release
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

# Step 2: Copy files
Write-Host ""
Write-Host " Copying to server/web..." -ForegroundColor Yellow
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

# Step 3: Build Docker
Write-Host ""
Write-Host " Building Docker image..." -ForegroundColor Yellow
docker-compose build
if ($LASTEXITCODE -ne 0) {
    Write-Host " Docker build failed!" -ForegroundColor Red
    exit 1
}
Write-Host " Docker built" -ForegroundColor Green

# Step 4: Start containers
Write-Host ""
Write-Host " Starting containers..." -ForegroundColor Yellow
docker-compose up -d
if ($LASTEXITCODE -ne 0) {
    Write-Host " Start failed!" -ForegroundColor Red
    exit 1
}

Write-Host ""
Write-Host " Done!" -ForegroundColor Green
Write-Host " http://localhost:3000" -ForegroundColor Cyan
Write-Host ""

Start-Sleep -Seconds 3
docker-compose ps
