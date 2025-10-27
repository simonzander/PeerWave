#!/usr/bin/env pwsh
# PeerWave - Rebuild Flutter only (without Docker restart)
# Usage: .\rebuild-flutter.ps1

Write-Host "🔄 Rebuilding Flutter Web..." -ForegroundColor Cyan

# Build Flutter
Push-Location client
try {
    flutter build web --release
    if ($LASTEXITCODE -ne 0) {
        Write-Host "❌ Flutter build failed!" -ForegroundColor Red
        exit 1
    }
} finally {
    Pop-Location
}

# Copy to server/web
Write-Host "📋 Copying to server/web..." -ForegroundColor Yellow
Copy-Item -Recurse -Force client/build/web/* server/web/

Write-Host ""
Write-Host "✅ Flutter rebuild complete!" -ForegroundColor Green
Write-Host ""
Write-Host "Note: Docker containers are still running with old files." -ForegroundColor Yellow
Write-Host "      Refresh browser to see changes (Ctrl+Shift+R)" -ForegroundColor Yellow
Write-Host ""
Write-Host "To restart containers: docker-compose restart peerwave-server" -ForegroundColor Cyan
