# Keeping the fork in sync with the original Melingo

How to pull in updates from the original project (`upstream`, timurverevkin/Melingo) without losing the IINA integration or bringing back the Telegram module.

Run everything from `~/Dev_Workplace/Melingo`. The fork is `origin`; the branch is `main`.

## Before the first sync (once)

- Everything must be committed: the Telegram removal and the IINA integration, as two commits. `git status` should show nothing to commit.
- Turn on git's memory for conflict resolutions, so a conflict you resolve once is resolved automatically next time:
  ```bash
  git config rerere.enabled true
  ```

## Each sync

### 1. Back up your data
Quit Melingo, then copy `~/Documents/Melingo` somewhere safe. Cards and library live there, and a new upstream version may change the data format.

### 2. Fetch and look before merging
```bash
git fetch upstream
git log --oneline main..upstream/main            # what is new
git diff --stat main...upstream/main             # which files changed
git diff --stat main...upstream/main | grep -i telegram   # is the removed feature being touched?
```
If the first command prints nothing, there is nothing to sync.

### 3. Merge on a separate branch
```bash
git switch -c sync-upstream main
git merge upstream/main
```
`main` stays untouched until the result has been checked. If the merge reports no conflicts, go to step 5.

### 4. Resolve conflicts
`git status` lists them. There are three kinds:

- **"deleted by us"** — upstream edited a file you removed (Telegram). Keep it removed:
  ```bash
  git status --porcelain | awk '$1=="DU"{print $2}' | xargs git rm
  ```
- **"both modified" in files you edited for the removal** (for example `AppLibraryStore.swift`, `LibraryView.swift`, `AppL10n.swift`, the Xcode project file). Open the file, keep upstream's new code, and delete the Telegram parts again. Then `git add <file>`.
- **"both modified" in the two files that carry IINA hooks.** Keep both sides. The lines that must survive are:
  - `App/MelingoMacApp.swift`: `IINABridgeController.shared.store = store` and `IINABridgeController.shared.bootstrap()`
  - `App/Features/Reader/WordLookupPopover.swift`: the `languagePairOverride` property and the `activePair` helper that uses it

When `git status` shows no unresolved files:
```bash
git commit
```
To give up instead: `git merge --abort`.

### 5. Check that nothing removed came back
New upstream files never conflict, so they merge in silently, and this project compiles everything under `App/` automatically.
```bash
grep -ril telegram App Packages Package.swift MelingoMac.xcodeproj
ls App/Features Packages
```
Anything Telegram-related that reappears: `git rm -r <path>`, remove remaining references, and commit ("Remove Telegram again after upstream merge").

### 6. Check that the custom features still work
```bash
grep -n IINABridgeController App/MelingoMacApp.swift                         # expect 2 lines
grep -n languagePairOverride App/Features/Reader/WordLookupPopover.swift     # expect 2 or more lines
node IINAPlugin/tests/overlay.test.js IINAPlugin/melingo-subtitles.iinaplugin   # needs Node installed
node IINAPlugin/tests/plugin.test.js  IINAPlugin/melingo-subtitles.iinaplugin
```
Then build and run from Xcode, and test by hand:
- Standalone: open the library, read something, look up a word, review a card.
- IINA: play a video with text subtitles, click a word, drag across a phrase, close the pop-up and confirm playback resumes.

If the build fails inside `App/Services/IINABridge` or `App/Features/IINABridge`, upstream changed something the integration relies on. The integration uses these parts of Melingo: `WordLookupPopover`, `AppLibraryStore` (`profile`, `vocabulary`, `createManualCard`), `TextSegment`, `LanguagePair`, `TranslationService`, `ThemeTokens`, `OKRadius`.

### 7. Finish
```bash
git switch main
git merge --ff-only sync-upstream
git push origin main
git branch -d sync-upstream
```
If the checks in steps 5–6 failed and you would rather start over, delete the branch instead (`git switch main && git branch -D sync-upstream`); `main` was never changed.

### 8. Rebuild the app you use
The app in Applications is a snapshot. Rebuild it from the updated code and replace the old copy. The IINA plugin is linked to this folder, so it picks up plugin changes after IINA is restarted.

## Habits that keep syncing easy
- Sync often. Small merges conflict less than one large one.
- Keep custom features in their own files, with as few lines as possible added to upstream's files.
- Do not use GitHub's "Sync fork" button for this: it cannot resolve conflicts, and one of its options discards your commits.
