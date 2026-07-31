# TgWsProxy iOS — локальный MTProto WebSocket прокси для Telegram

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

Локальный **MTProto ↔ WebSocket** прокси для **Telegram iOS** — без системного VPN / Packet Tunnel в этой сборке.

```text
Telegram iOS → 127.0.0.1:1443 → TgWsProxy → WSS/TCP → Telegram DC
```

**English:** [README.md](README.md)

> Bundle id: `com.mushroomSquad.tgwsproxy`

## Важно

- **[DISCLAIMER.md](DISCLAIMER.md)** и **[NOTICE.md](NOTICE.md)** (вайбкодинг).
- **[CREDITS.md](CREDITS.md)** — Flowseal + Android-порт MushroomSquad.

### Фон

Без Packet Tunnel iOS может убить listener в фоне. **Держите приложение открытым**, пока пользуетесь Telegram.

### Без платного Developer

Репозиторий — **исходники**. Собираете в Xcode на своём Mac с free Apple ID (~7 дней до переподписи). App Store / TestFlight здесь нет.

## Сборка (Mac + Xcode)

1. Xcode 15+.
2. Клонировать репо, открыть `TgWsProxy.xcodeproj`.
3. Signing → свой Team (free Apple ID).
4. Подключить iPhone → Run.
5. При необходимости доверить сертификат разработчика на устройстве.

Тесты ядра:

```bash
swift test
```

## Подключение Telegram

1. **Start** в TgWsProxy, не сворачивайте надолго.
2. **Open Telegram** / **Copy link**.
3. Настройки → Данные и память → Прокси.
4. Вручную: `127.0.0.1:1443`, secret из приложения (`dd` + 32 hex).

## Лицензия

[MIT](LICENSE).
