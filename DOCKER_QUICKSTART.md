# 🐳 Docker Quick Start

## 🚀 Schnellstart (Ein Befehl)

```powershell
.\build-and-start.ps1
```

Das Script führt automatisch aus:
1. Flutter Web Build (`flutter build web --release`)
2. Copy zu `server/web/`
3. Docker Image Build (`docker-compose build`)
4. Container Start (`docker-compose up -d`)

## 📋 Manuelle Schritte

### 1. Flutter bauen

```powershell
cd client
flutter build web --release
Copy-Item -Recurse -Force build/web/* ../server/web/
cd ..
```

### 2. Docker starten

```powershell
# Development
docker-compose up -d

# Production
docker-compose -f docker-compose.prod.yml up -d
```

## 🌐 Zugriff

- **Server**: http://localhost:3000
- **coturn**: localhost:3478 (STUN/TURN)
- **Monitoring**: http://localhost:9641 (optional mit `--profile monitoring`)

## 🔧 Nützliche Befehle

```powershell
# Status anzeigen
docker-compose ps

# Logs verfolgen
docker-compose logs -f

# Container stoppen
docker-compose down

# Nur Flutter neu bauen
.\rebuild-flutter.ps1
docker-compose restart peerwave-server

# Alles neu bauen
docker-compose up -d --build
```

## 🎯 VS Code Tasks

**Ctrl+Shift+B** → "Build & Start (Flutter + Docker)"

Verfügbare Tasks:
- `Build & Start (Flutter + Docker)` - Kompletter Build
- `Docker: Build All` - Nur Docker Image
- `Docker: Start` - Container starten
- `Docker: Stop` - Container stoppen
- `Docker: Logs` - Logs anzeigen
- `Flutter: Build Web` - Nur Flutter
- `Flutter: Rebuild` - Flutter + Copy

## ⚙️ Konfiguration

### Ports (überall 3000)

- Development: `3000:3000`
- Production: `3000:3000`
- Intern: Port `3000`

### Environment Variables

```yaml
# .env oder docker-compose.yml
PORT=3000
NODE_ENV=development  # oder production
TURN_SERVER_HOST=peerwave-coturn
TURN_SERVER_PORT=3478
TURN_SECRET=your-secret-key-here
```

## 🐛 Troubleshooting

### Port 3000 bereits belegt?

```powershell
# Prozess finden
netstat -ano | findstr :3000

# Prozess beenden
Stop-Process -Id <PID>
```

### Container startet nicht?

```powershell
# Logs prüfen
docker-compose logs peerwave-server

# Status prüfen
docker-compose ps

# Neu starten
docker-compose restart
```

### Flutter Änderungen nicht sichtbar?

```powershell
# Flutter neu bauen + Docker neu starten
.\rebuild-flutter.ps1
docker-compose up -d --build
```
