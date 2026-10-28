# Development

Building from source, the development copy, tests and CI, releasing a version, the code layout and the README images. The other notes under `docs/` are in Chinese.

## Build and run

You need Xcode 16 or later (the code is Swift 6) and [XcodeGen](https://github.com/yonaskolb/XcodeGen). The Xcode project is not in git; it is generated from `project.yml`.

```sh
brew install xcodegen
make dev        # generate the project, build the Debug configuration, open "GetNewWord Dev"
make test       # run the unit tests (see "Tests and CI" below)
make generate   # only regenerate GetNewWord.xcodeproj (after adding or removing files, or editing project.yml)
make clean      # delete GetNewWord.xcodeproj and build/
```

The build goes to `build/DerivedData`. `GetNewWord/Info.plist` is written by XcodeGen from the `info` section of `project.yml`: change the keys there, not in the plist.

Without the maintainer's signing certificate, sign the build locally (ad hoc):

```sh
xcodegen generate
xcodebuild -project GetNewWord.xcodeproj -scheme GetNewWord -configuration Debug \
  -derivedDataPath build/DerivedData CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= build
```

An ad-hoc signed app changes its signature on every build, so macOS may ask for Screen Recording permission again after each rebuild.

### The development copy

The Debug configuration builds **GetNewWord Dev** (bundle id `com.getnewword.app.dev`). It keeps everything apart from the installed app, so you can test from the welcome screen without touching your own word library:

| | Installed app | GetNewWord Dev |
|---|---|---|
| Settings | `com.getnewword.app` | `com.getnewword.app.dev` |
| Library, screenshots, audio, backups, `app.log` | `~/Library/Application Support/GetNewWord/` | `~/Library/Application Support/GetNewWord Dev/` |
| API keys (Keychain service) | `com.getnewword.app` | `com.getnewword.app.dev` |
| Anki root deck and note types | `GetNewWord` | `GetNewWord Dev` |
| Automatic updates | on | off |

Any bundle id ending in `.dev` counts as a development copy, and one other than `com.getnewword.app.dev` gets its own folder, `GetNewWord Dev (<bundle id>)`. To run a second copy next to the first, add `PRODUCT_BUNDLE_IDENTIFIER=com.getnewword.app.<name>.dev` to the `xcodebuild` command.

Both copies register the same global shortcuts (`⇧⌘A` capture, `⌃⌘A` point), so quit the installed app while you test, or both will react.

The log is `app.log` in the data folder (`tail -f` it while you test). It records each lookup, the AI request times and errors.

## Tests and CI

`make test` builds an unsigned development copy in `build/Test` (the one from `make dev` stays as it is) and runs the unit tests in `GetNewWordTests/` inside it, with Swift Testing. They cover the parts that do not need the interface: reading the AI's answer (`ZhipuService.parseAnalysis`, truncated replies), sorting providers' errors into the error panels (`ZhipuServiceError.from`, `LookupFailure.from`), the merge rule of library sync (`CloudSyncService.pullAction`), the Anki cards (field names against the note type, media through `storeMediaFile`, restoring cards into the library) against a fake AnkiConnect, export and import, the red box of the context image, saving and merging words, and the string catalogs: every entry has English and German, and every string the code uses is in a catalog (checked against the `.stringsdata` files the build extracts).

While the tests run, the app starts as an empty process: no windows, no shortcuts, no library. It uses the bundle id `com.getnewword.app.tests.dev`, so its settings and Keychain are separate from the development copy, and its data folder is a temporary folder that is deleted afterwards. Nothing talks to a real Anki or an AI provider.

`--selftest <file.json>` starts a built app without opening anything, checks that it launches with Sparkle embedded, has its resources and the English and German string tables, and can create a library (in a temporary folder), writes the result to the file and quits with exit code 0 when everything passed:

```sh
build/DerivedData/Build/Products/Release/GetNewWord.app/Contents/MacOS/GetNewWord --selftest selftest.json
arch -x86_64 build/DerivedData/Build/Products/Release/GetNewWord.app/Contents/MacOS/GetNewWord --selftest selftest-intel.json   # the Intel half, through Rosetta
```

`.github/workflows/build.yml` runs on every push to `main`, every `v*` tag and every pull request: `make test`, an unsigned Release build for Apple silicon and Intel, `lipo` to check that both architectures are in the app and in Sparkle, and `--selftest` on both. GitHub charges macOS minutes of private repositories at ten times the rate, so while the repository is private the job is skipped; start it by hand with **Run workflow** on the Actions page. `scripts/release.sh` first runs `scripts/require-ci.sh`, which stops the release unless `HEAD` has passed this workflow; while the repository is private it only prints a note.

## Releasing a version

Only the maintainer can release: it needs the signing certificate and secrets that are not in the repository.

Releases are signed with Developer ID but not notarized. The first time someone opens the app, macOS stops it; the README, the website and the release notes tell people to open **System Settings › Privacy & Security** and click **Open Anyway**. Updates installed by Sparkle are not stopped again.

What you need:

- The **Developer ID Application** certificate for team `3H5S5NXPXS` in the login keychain.
- The **Sparkle EdDSA private key** in the login keychain under the account `getnewword` (created once with `generate_keys --account getnewword`), or in a file passed as `SPARKLE_KEY_FILE=<file>`. Installed copies only accept updates signed with this key; its public half is `SUPublicEDKey` in `project.yml`. If the key is lost, existing users can no longer update automatically, so keep a backup.
- `gh`, signed in with push access to the repository.
- Python 3 (comes with Xcode). The first run creates `build/release-tools` and installs the versions pinned in `scripts/release-requirements.txt`: `dmgbuild`, which lays out the DMG window by writing its `.DS_Store` directly (no Finder scripting, no Automation permission), and `Markdown`, which turns the release notes into HTML for the Sparkle update window.

Steps:

1. Raise `MARKETING_VERSION` (the version people see) and `CURRENT_PROJECT_VERSION` (the build number; Sparkle compares this one, so it must grow with every release) in `project.yml`, run `make generate`, then commit and push to `main`.
2. Write the release notes in `release/<version>/notes.md` (`release/` is not in git). Follow `docs/release-notes/1.2.0.md`: one sentence on what changed, a download table, what people on older versions have to do, then the changes by area. Leave an empty line before every list, because the same file becomes the text in the Sparkle update window and the GitHub release.
3. Build and check: `scripts/release.sh`. It stops before building unless the working tree is clean, `HEAD` is on `origin/main`, there is no GitHub release `v<version>` yet, a tag `v<version>` (if any) points at `HEAD`, the notes exist and mention the version, and the build number is greater than the latest release's (read from its `appcast.xml`, or from its tag's `Info.plist` when it has none). When there is no release on GitHub, or the latest one has no `appcast.xml` and its tag is not in your clone, it cannot read that number and stops; give it as `PREV_BUILD=<build number> scripts/release.sh` (1.1.2 was build 4). Then it deletes the old Release build products, builds for Apple silicon and Intel (and stops if the build fails), signs Sparkle's helpers and the app with Developer ID and the hardened runtime, makes the DMG (background with an arrow, icon positions, volume icon, volume name `GetNewWord <version>`), mounts it read-only to check it, signs the DMG, and writes the Sparkle feed with the notes embedded. Along the way it checks:
   - in the app: version and build number, both architectures (`lipo -archs`), team ID and Developer ID (`codesign -dvv`) and the hardened runtime;
   - in the DMG: volume name, the app and the `Applications` link, background, volume icon and window layout in `.DS_Store`, and the same checks on the app inside;
   - in `appcast.xml`: download URL, file size, both versions, the embedded notes and the EdDSA signature, verified against `SUPublicEDKey` from the app.

   Everything lands in `release/<version>/`: `GetNewWord-<version>.dmg`, a copy named `GetNewWord.dmg`, `appcast.xml`, `release-body.md` (the notes plus the DMG's SHA-256), the record of what was checked (`checked.json`, `checked.sha256`) and the logs. Open the DMG and the app once before you go on.
4. Publish: `scripts/release.sh --publish`. It runs the same checks on the repository, makes sure `release/<version>/` was checked for this `HEAD` and has not changed since (files and notes), tags `HEAD` as `v<version>` and pushes the tag, then runs `gh release create --verify-tag` with the title `GetNewWord <version>`, `release-body.md` as the text and the three files. Nothing is built again.

The website's download button and the README link to `releases/latest/download/GetNewWord.dmg`, and installed copies read `releases/latest/download/appcast.xml` (`SUFeedURL`), so these file names must stay the same. While the repository is private, both return 404 to anyone not signed in to GitHub.

## Code layout

- `GetNewWord/GetNewWordApp.swift`: app entry, menu bar menu, main and settings windows.
- `GetNewWord/Models/`: SwiftData models: `WordEntry` (one per word and language), `WordContext` (each sentence the word was met in), `KnowledgeSnippet`, `Category`.
- `GetNewWord/ViewModels/AnalysisViewModel.swift`: the look-up pipeline from shortcut to saved word (capture or point, local OCR, AI requests in parallel, auto-save, undo, Anki sync).
- `GetNewWord/Services/`:
  - `ScreenshotService`, `HoverWordCapture`, `AnalysisService`: capturing a region or the word under the pointer, local Vision OCR, the library cache hit.
  - `ZhipuService`: every AI provider (`APIProvider`: Zhipu, DeepSeek, Qwen, Kimi, Doubao, OpenAI, Gemini, Claude, OpenRouter, any OpenAI-compatible service), the prompts and response parsing.
  - `AnkiService`, `AnkiInstaller`: AnkiConnect, decks and note types, one-click install of Anki and AnkiConnect.
  - `AudioService`: pronunciation (Youdao, Wiktionary recordings, Google TTS, system voice).
  - `SupabaseAuth`, `SupabaseConfig`, `CloudSyncService`, `CloudRealtime`: optional sign-in and library sync between Macs (design in `docs/sync-design.md`, database in `supabase/`).
  - `ImportExportService`, `DatabaseManager`, `AppUpdater` (Sparkle).
- `GetNewWord/Views/`: `Screenshot/` (selection overlay, look-up panel, error panels), `Settings/` (settings window, onboarding, pricing), the main window (`MainView`, `Sidebar/`, `WordList/`, `Detail/`, `Dashboard/`) and `Theme.swift` (colours, fonts, shared controls).
- `GetNewWord/Utilities/`: global shortcuts (Carbon, no Accessibility permission needed), Keychain, permissions, `AppVariant` (installed app or development copy), interface language, log, the context image with the red box.
- `GetNewWordTests/`: the unit tests (`make test`). `GetNewWord/Utilities/SelfTest.swift`: the `--selftest` launch check. `.github/workflows/build.yml`: CI. `scripts/require-ci.sh`: the CI check that `scripts/release.sh` runs first.
- `GetNewWord/Resources/`: `Assets.xcassets` (app icon, AI provider logos), string catalogs `Localizable.xcstrings`, `InfoPlist.xcstrings` and `Categories.xcstrings` (keys are the Simplified Chinese source text, with English and German translations), `DefaultCategories.json`.
- `website/`: the static website (Chinese, English, German). `scripts/release.sh`: the release script; `scripts/dmg/`: the DMG window (`build.py` runs dmgbuild with `settings.py`; `background.swift` draws the background).

## README images

The animations and screenshots in `docs/readme/en/` and `docs/readme/zh/` are made by two scripts; re-run them when the website demo or the interface changes.

The two animations (`capture.webp`, `point.webp`) are recorded from the demo stage on the website, so they need no app:

```sh
node scripts/readme-assets.mjs                     # both languages, website/ served locally
node scripts/readme-assets.mjs --lang en --only capture
```

They are animated WebP, 1680 px wide (shown at 840), with transparent corners so one file suits GitHub's light and dark themes. The script needs Google Chrome, Playwright (global install), `img2webp` and ImageMagick (`brew install webp imagemagick`).

The screenshots of the real app (`lookup.png`, `main-light.png`, `main-dark.png` and `anki-card.png`) come from a copy of the app that frames words by itself:

```sh
GNW_DEMO_KEY=<DeepSeek API key> node scripts/readme-shots.mjs     # both languages, about 4 minutes each
```

It builds a Debug copy named GetNewWord with the bundle id `com.getnewword.app.readme.dev` (its own data folder and settings) into `build/Readme`, renders the demo pages in the script (an article and a video subtitle per language) as full-screen images, and starts the copy with `GNW_DEMO`. In Debug builds `DemoMode.swift` then replaces the screen capture with those images and the drag with the rectangle of each marked word, one after another; local OCR, the DeepSeek request, the panel, saving and the Anki sync are the normal code. The cards go into a throwaway Anki profile with AnkiConnect copied from your Anki, so quit your own Anki first; `anki-card.png` is the HTML Anki renders for the card (AnkiConnect `cardsInfo`) drawn in Chrome at reviewer width, because Anki's own window stays blank while the screen is locked. Windows are captured with `screencapture -l`, which records nothing else on the screen and also works while the screen is locked. Afterwards the copy's data folder, its settings and the Anki profile are deleted. The key is only passed to the copy as an environment variable and is never saved.
