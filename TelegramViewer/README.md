**Not for production.** Local tool to manage Melingo’s Telegram login in Firebase and browse exports.

## Firebase

If cloud restore fails with “rules block access”, update RTDB rules — see [`Packages/TelegramKit/firebase-database.rules.json`](../Packages/TelegramKit/firebase-database.rules.json).

## Session controls

Sidebar → **Cloud session (dev)**:

| Action | Effect |
|--------|--------|
| Check cloud | Read `tdlib_sessions/{key}/meta` |
| Restore from Firebase | Download TDLib DB → connect |
| Push local → Firebase | Upload this Mac’s session |
| Delete cloud session | Wipe remote `tdlib_sessions/{key}` |
| Clear local TDLib folder | Wipe `~/Documents/Melingo/Telegram/tdlib` |

Shared name must match Melingo (default `primary`).

## Run
