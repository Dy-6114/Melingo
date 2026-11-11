# Melingo Subtitles — IINA plugin

Makes subtitles in IINA selectable and sends the selection to Melingo.

- **Click** a word, or **drag** across a phrase, in the subtitle line.
- The video **pauses** as soon as you press the mouse button.
- Melingo shows a lookup panel next to the pointer (translation, pronunciation,
  definition, **Add card**). It also appears over full-screen video.
- The video **resumes** when the panel closes: click anywhere outside it, press
  its close button, or just press play in IINA. If the video was already paused
  before you selected, it stays paused.

Written for IINA 1.5 (it uses the plugin API introduced in 1.4). Melingo must be
running; the menu-bar agent is enough.

## Install (development link)

```bash
/Applications/IINA.app/Contents/MacOS/iina-plugin link \
  "$(pwd)/IINAPlugin/melingo-subtitles.iinaplugin"
```

Then quit and reopen IINA, open **Settings → Plugins**, and enable
**Melingo Subtitles**. To switch it off, disable it in the same place.

After editing plugin files, restart IINA to reload them.

## How it works

| Piece | Where | Role |
|---|---|---|
| `main.js` | IINA plugin script | Reads `sub-text` from mpv every 100 ms, hides IINA's own subtitle rendering, turns mouse presses and drags in the player window into a word selection, pauses/resumes, talks to Melingo |
| `overlay.html` | IINA overlay web view | Draws the line with one `<span>` per word, reports where each word is, highlights the selection. It never receives mouse events |
| `IINABridgeController.swift` | Melingo | Loopback HTTP listener on `127.0.0.1:51730`; detects the line's language; opens the panel |
| `SubtitleLookupPanel.swift` | Melingo | Non-activating floating panel hosting the standard word lookup |

Bridge protocol (GET, header `X-Melingo-Bridge: 1` required):

| Endpoint | Returns |
|---|---|
| `/ping` | `{ ok, app, ready }` |
| `/lookup?text&context&title&position&trackLang` | `{ id, source, target }` |
| `/status?id` | `{ state: "open" \| "closed" }` — the plugin polls this and resumes on `closed` |
| `/dismiss?id` | `{ ok }` — sent when you press play yourself |

Languages: the translation target is **Settings → Languages → Explanation
language** in Melingo. The source language is detected per subtitle line, then
falls back to the subtitle track's language tag, then to **Content language**.

### Why the overlay is not clickable

IINA lets an overlay take mouse events (`overlay.setClickable(true)`), and the
first version of this plugin used that. In IINA 1.5.1 a clickable overlay runs a
nested run loop inside every hit test, and IINA crashed when macOS requested a
hit test during a display update (it happened while dragging the Position slider
in the Subtitles panel). The plugin therefore uses `iina.input` instead:

- `onMouseDown` / `onMouseUp` report clicks in window points from the bottom-left corner.
- `onMouseDrag` fires continuously during a drag, but IINA sends no mouse-up
  afterwards, so a drag counts as finished once the pointer rests for 350 ms.
- Returning `true` from the mouse-down handler keeps IINA from treating the press
  as its own (window drag, click-to-pause).

## Size and position

The selectable line follows IINA's own subtitle settings (Subtitles panel),
read from mpv and laid out the way mpv does it:

- **Position**: `sub-pos` — 100 puts the line at the bottom margin; lower values move it up.
- **Scale**: `sub-scale` — also Subtitles → Scale Up / Scale Down / Reset Subtitle Scale.
- **Font size**: `sub-font-size`.

Font family, colour, border and shadow are fixed in `overlay.html`.

## Limits

- Text subtitles only (SRT, ASS, WebVTT…). Bitmap subtitles (Blu-ray PGS,
  DVD VobSub) and burned-in subtitles are left to IINA and are not selectable.
- ASS styling and positioning are not reproduced; every line is drawn bottom-centre.
- While the plugin is enabled it keeps IINA's own subtitle rendering switched
  off for text tracks. To see subtitles drawn by IINA again, disable the plugin
  and toggle subtitle visibility once.
- Cards are saved with the language pair from Melingo's Settings, even when the
  line was detected as another language.

## Tests

```bash
node IINAPlugin/tests/overlay.test.js IINAPlugin/melingo-subtitles.iinaplugin
node IINAPlugin/tests/plugin.test.js  IINAPlugin/melingo-subtitles.iinaplugin
```
