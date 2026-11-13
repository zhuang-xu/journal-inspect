# Journal Inspect

Journal Inspect helps you revisit and reflect on what you’ve written in Apple Journal. Browse and filter your entries, or ask a question such as “What have I written about feeling more focused at work?” The app searches for relevant passages by meaning, uses them to draft an answer, and shows the excerpts it used so you can read them in context.

Journal Inspect opens your Apple Journal database read-only. Search and answer generation run on your Mac, where the app also keeps its index, search cache and optional saved memories.

## Architecture

| Module | Responsibility |
| --- | --- |
| `App` | SwiftUI screens, settings and progress. The app wires up the feature view models and gives them a shared memory store and retrieval cache per window. |
| `JournalCore` | Read-only SQLite access to Apple Journal, metadata sync, passage ranking, prompt preparation and local stores. Core is independent of SwiftUI and llama.cpp. |
| `JournalEmbeddings` | Runs the local embedding model to turn questions and journal passages into vectors for similarity search. |
| `JournalGeneration` | Runs the local answer model, fits retrieved excerpts and optional saved background into its context, and streams the answer. It also supports extracting saved background. |
| `JournalLlama` | Initializes the shared llama.cpp backend used by both model modules. |

When you ask a question, the app refreshes its metadata index, ranks passages by similarity to the question and reopens the selected originals. With the cache enabled, it reuses vectors for unchanged passages. It releases the embedding model before loading the generation model, then streams the answer and shows the excerpts used.

The app persists a metadata-only index, a vector cache and optional saved memories in separate local stores. Retrieved entry text, prompts and answers stay in memory during use. See the [architecture notes](docs/ARCHITECTURE.md) for module boundaries, storage and the full question-to-answer flow.

## Build and test

Use macOS 14 or later and a full Xcode installation with its command-line tools selected.

```sh
Scripts/setup-llama.sh
swift test
xcodebuild -project JournalInspect.xcodeproj -scheme JournalInspectApp CODE_SIGNING_ALLOWED=NO build
```

The build and default tests require the pinned llama.cpp framework. Model weights are only needed for inference and opt-in model tests. The shared Xcode project is generated from `project.yml`. After changing target configuration or source file membership, run `xcodegen generate` and commit the resulting project changes.

## Run the app

You can browse entries without model weights. Asking questions requires both local models:

| Model | What it does | Download and verify |
| --- | --- | --- |
| Qwen3-Embedding-0.6B Q8_0 | Finds journal passages that match your question by meaning | `Scripts/setup-embeddings.sh` |
| Qwen3-4B-Instruct-2507 Q5_K_M | Writes answers using the retrieved passages | `Scripts/setup-generation.sh` |

The scripts save the models in the local `Models/` folder (about 3.5 GB total). The generation script requires Python 3. From the project root, run:

```sh
Scripts/setup-llama.sh
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

## TODO

- [Multimedia support](docs/plans/ROADMAP.md#5-multimedia-support)
