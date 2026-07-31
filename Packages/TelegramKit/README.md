# Telegram export (Melingo)

Export public Telegram channels to structured JSON + local media, browse them in a Telegram-like view, and reuse the same TDLib session on another Mac via Firebase Realtime Database (no custom server).

## Flow

1. In Melingo sidebar → **Telegram**
2. Enter `api_id` / `api_hash` from [my.telegram.org](https://my.telegram.org)
3. **Start / Connect** → phone → code → 2FA if needed
4. Session is uploaded to Firebase under `tdlib_sessions/{sessionKey}` (default key: `primary`)
5. Enter `@channel` → **Export & open** → posts open in a Telegram-styled browser; files land in `~/Documents/Melingo/Telegram/Exports/<channel>/`

## Firebase

Database URL:

`https://telegram-f549b-default-rtdb.europe-west1.firebasedatabase.app`

Rules must allow read/write for the `tdlib_sessions` path (or use a locked-down secret later). The TDLib folder is zip-chunked into RTDB.

## Remote CLI (another Mac)

Same package, no Melingo UI:

```bash
cd Packages/TelegramKit
swift run telegram-export pull-session --key primary
swift run telegram-export export --channel @durov
```

Optional push from the machine that already has a session:

```bash
swift run telegram-export push-session --key primary
```

JSON schema: `channel.json` with `channel` meta + `posts[]` (`id`, `date`, `text`, `attachments[]`, …) and a `media/` folder.
