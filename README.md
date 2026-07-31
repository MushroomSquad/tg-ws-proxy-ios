# TgWsProxy iOS — Telegram MTProto WebSocket Proxy (no root, no VPN)

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Keywords:** Telegram iOS proxy · MTProto · WebSocket · local proxy · no VPN · SwiftUI · sideload Xcode

Local **MTProto ↔ WebSocket** proxy for **Telegram iOS** — no Network Extension / system VPN in this build.

```text
Telegram iOS → 127.0.0.1:1443 → TgWsProxy → WSS/TCP → Telegram DC
```

**Русская версия:** [README.ru.md](README.ru.md)

> Bundle id: `com.mushroomSquad.tgwsproxy`  
> Home: [MushroomSquad/tg-ws-proxy-ios](https://github.com/MushroomSquad/tg-ws-proxy-ios)

## Important

- Read **[DISCLAIMER.md](DISCLAIMER.md)** before installing.
- Read **[NOTICE.md](NOTICE.md)** — largely vibe-coded with LLM assistants.
- Credits: **[CREDITS.md](CREDITS.md)** → [Flowseal/tg-ws-proxy](https://github.com/Flowseal/tg-ws-proxy) and [tg-ws-proxy-android](https://github.com/MushroomSquad/tg-ws-proxy-android).

### Background limit (read this)

Without Packet Tunnel, **iOS may suspend the listener** when the app is backgrounded. Keep TgWsProxy open while using Telegram. This is weaker than Android’s foreground service.

### No paid Apple Developer account

This repo ships **source**. Build with Xcode on your Mac using a free Apple ID (device installs expire about every 7 days). There is no App Store / TestFlight pipeline here.

## Build & install (Mac + Xcode)

1. Install Xcode 15+ from the App Store.
2. Clone this repo.
3. Open `TgWsProxy.xcodeproj`.
4. Select your Team (free Apple ID) under Signing & Capabilities for target **TgWsProxy**.
5. Connect an iPhone, trust the computer, select the device as run destination.
6. Product → Run (⌘R).
7. On device: Settings → General → VPN & Device Management → trust your developer certificate if prompted.

Optional core tests (Mac):

```bash
swift test
```

(Requires Swift toolchain; crypto/protocol tests do not need a device.)

## Connect Telegram

1. Open **TgWsProxy** → **Start** (keep the app in the foreground).
2. **Open Telegram** or **Copy link**.
3. Telegram: **Settings → Data and Storage → Proxy** — enable.
4. Manual MTProto:
   - Server: `127.0.0.1`
   - Port: `1443`
   - Secret: from the app (`dd` + 32 hex)

## Settings tips

- **DC IP**: default DC2+DC4 → `149.154.167.220`.
- **Refresh CF**: pulls Cloudflare proxy domain list from upstream GitHub raw.
- **Share logs**: for bug reports.

## Layout

| Path | Role |
|------|------|
| `Sources/TgWsProxyCore/` | Protocol stack (handshake, AES-CTR, WS, fallbacks) |
| `App/TgWsProxy/` | SwiftUI shell |
| `Tests/` | Unit tests |

## Related searches

telegram proxy ios · mtproto websocket · tg ws proxy · local mtproto · xcode sideload telegram

## License

[MIT](LICENSE) — © Flowseal (upstream) and MushroomSquad (iOS port).
