# Device verification checklist

This environment cannot run Xcode. On a Mac with Xcode and a free Apple ID:

1. Open `TgWsProxy.xcodeproj`, set Signing Team, Run on a physical iPhone.
2. Start the proxy in the app; confirm logs show `Listening on 127.0.0.1:1443` and `Crypto self-test OK`.
3. Open Telegram via the in-app button (or paste `tg://proxy?...`).
4. Enable the MTProto proxy in Telegram; confirm status becomes available / connected.
5. Send a message and open a photo (media path / TCP fallback).
6. Background TgWsProxy for 30–60s, return to Telegram — note whether the proxy drops (expected limitation without Packet Tunnel).
7. Share logs from the app if something fails.

Protocol unit tests (no device): `swift test` on macOS with Swift toolchain.
