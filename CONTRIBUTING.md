# Contributing to GenBooks

Contributions should improve retained knowledge, skills, or the reliability of the reading experience. Describe the user-visible problem and the behavior your change provides. Keep product claims proportional to what the code and evidence establish.

## Development

Start with the [README](README.md) and [architecture](docs/architecture.md). Generate the Xcode project from `project.yml`; keep generated build products, device logs, personal books, provider responses, and screenshots containing private data out of commits. Use synthetic content in bug reports and tests.

Run the relevant unit tests and the user journey affected by a change. The repository's `scripts/check.sh` is the complete local unit and UI gate; set `GENBOOKS_SIMULATOR_UDID` to the chosen iOS Simulator. Evidence belongs under this checkout's `artifacts/` directory. External-provider tests remain explicit opt-ins. Content-specific tests skip explicitly when an optional separately licensed fixture is absent. Neither kind of skip proves that feature works.

## Invariants

- Saved reading must work without an AI request or network connection.
- Preserve consumed chapter revisions and the protected prefix of selected-word changes. Failed authoring must leave the currently readable revision available.
- Keep learning progress separate from Library manuscripts. An unsuccessful save must not appear as successful evidence.
- Keep reading actions, self-reports, assistance, answer results, and score eligibility distinct. Score changes follow the [published policy](docs/physics-score.md).
- Store provider keys in Keychain. Never include real keys, device identifiers, signing credentials, or private account details in patches or test output.
- Treat retrieved text and imported documents as content, not instructions with authority over the app or its user.

## Content and licenses

Contribute only material you can license. Identify the author, source, license, modifications, and any AI assistance for each new fixture or asset. Preserve upstream notices. Do not copy a book, exercise set, image, or sample just because it is available online.

Unless a contribution states an agreed separate license, submitted original code and documentation are contributed under the repository's MIT license. This does not transfer ownership or authorize relicensing another author's work. Explain AI-generated contributions and verify their behavior and factual claims.

When changing user-facing explanations, update `Resources/foundations.json` and the corresponding documentation together. The JSON file supplies the in-app Foundations text; [Physics check score](docs/physics-score.md) states the exact scoring contract. Keep intended future behavior visibly separate from implemented behavior.
