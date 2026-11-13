# Journal Inspect

Journal Inspect is a native macOS app for browsing Apple Journal entries and asking questions about them using local models. It opens the Journal database read-only and keeps its own index, retrieval cache and optional saved memories on your Mac.

## Build and test

Use macOS 14 or later and a full Xcode installation with its command-line tools selected.

```sh
Scripts/setup-llama.sh
swift test
xcodebuild -project JournalInspect.xcodeproj -scheme JournalInspectApp CODE_SIGNING_ALLOWED=NO build
```

The build and default tests require the pinned llama.cpp framework. Model weights are only needed for inference and opt-in model tests. The shared Xcode project is generated from `project.yml`. After changing target configuration or source file membership, run `xcodegen generate` and commit the resulting project changes.

## Run the app

Download the embedding and generation models (about 3.5 GB total). The generation setup uses Python 3.

```sh
Scripts/setup-embeddings.sh
Scripts/setup-generation.sh
```

Open `JournalInspect.xcodeproj`, choose the `JournalInspectApp` scheme, and run. The project defaults to ad hoc signing. To use an Apple Development identity, add the following to your ignored `Config/Signing.local.xcconfig`:

```xcconfig
CODE_SIGN_IDENTITY = Apple Development
DEVELOPMENT_TEAM = YOUR_TEAM_ID
```

Grant Full Disk Access to the app if macOS blocks access to the Journal database. If the app's signing identity changes, macOS may require granting access again.

See the [documentation](docs/README.md) for usage, storage, model provenance and opt-in checks.
