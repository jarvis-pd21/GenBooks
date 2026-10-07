# GenBooks for the web

**Mission: Increase retained knowledge and skills.**

**Vision:** A personal library that helps you reason from first principles, connect ideas across systems, and use what you learn later.

[Open GenBooks](https://genbooks.agi-jarvis.com) · [Source and full foundations](https://github.com/jarvis-pd21/GenBooks)

Read the original six-part Physics course freely. Sign in with ChatGPT to keep private imported books, notes, reading positions and learning evidence across browsers using the same account. Library, Learning and Notebook are the three main destinations; Settings contains Foundations, privacy and data export.

## What this version does

- Comfortable chapter reading, saved passage anchors, light/dark appearance and adjustable type.
- Private DRM-free EPUB, plain text and Markdown imports. Text and chapters are retained; images, original layout and equation formatting are not. No PDF, scanning or protected-book import.
- Passage notes, a Words category, notebook search, editing and confirmed deletion.
- Six original Physics readings, five concepts, optional questions and source links.
- A transparent 0–100 Physics check score based on ten designated questions. Reading, self-reported learning and time spent earn no points. This is not an intelligence rating or a measure of all retained knowledge and skills.
- Account-scoped persistence, visible save failures, cross-browser refresh and a JSON export containing account records and imported book text.

Opening a reading records teaching exposure for a signed-in learner. Delayed review questions can count after the published spacing rules; a correct eligible answer contributes 10 points for that question, an incorrect eligible answer contributes 0. The latest eligible answer replaces that question's previous result. Time alone removes no points. The precise policy lives in `lib/learning.ts`, with 34 deterministic regression cases in `tests/learning.test.mjs`.

## Daily process

1. Choose a short reading in Library or Learning.
2. Save an interesting passage or your own explanation in Notebook.
3. Finish the Physics reading and optionally answer a question. Immediate practice does not earn check points.
4. Return later to a concept review. The question says whether it can count and why.
5. Inspect the score's question-by-question evidence. Marking a concept learned is your label, not a tested result.

You can skip practice or stop at any time. Session-length preferences and enjoyment feedback are saved, but this initial web release does not use them to personalize lesson selection. Next suggests the earliest due concept, then the first unfinished reading. It is a simple policy, not a trained recommendation system.

## Architecture and trust boundary

React runs the interface. Vinext builds the Next-style application into a Cloudflare Worker. Sites handles production ChatGPT sign-in before the Worker and supplies verified identity headers. D1 stores one revisioned JSON account record per authenticated Site user; R2 stores imported books under an owner-hashed, content-hashed key.

The browser never selects the authenticated owner. Every private operation resolves that owner on the server. An additional account header prevents a stale tab from writing its old draft into a newly signed-in account. Mutations require the same origin and JSON, validate bounded inputs and compare account revisions before committing. A conflict retries against fresh data up to four times; note versions protect against stale replacement or resurrection after deletion. Duplicate answer submissions return the original receipt. The browser accepts only nondecreasing revisions for its initial account.

Sync refreshes on page focus and every 30 seconds while visible. This is not a live collaborative editor. Reading positions use the server request-arrival timestamp; a later-arriving request takes precedence even if an older request finishes afterward. Requests arriving in the same millisecond use commit order. Appearance stays in each browser. New books, notes and learning data require a connection to save. Unsaved drafts are in memory, so copy them before reloading or changing accounts.

**Do not expose a raw Worker directly and trust caller-supplied identity headers.** The hosted deployment requires the Sites authentication boundary. Running a separate deployment requires replacing that boundary with independently verified authentication and supplying DB/BUCKET bindings.

## Run locally

Use Node.js 22.13+ with built-in TypeScript stripping enabled for the policy suite. The development server is loopback-only. The starter's local sign-in uses the single test account `local_seedy`; it is never a production login.

```sh
npm run install:ci
npm run build
npx wrangler d1 migrations apply DB --local --config dist/server/wrangler.json --persist-to .wrangler/state
npm run dev -- --host 127.0.0.1 --port 5173
```

Open the printed local URL. Use Sign in to sync for the local test identity. D1 and R2 development data stay in ignored `.wrangler/state`. Do not commit this folder, browser sessions, environment files or exported user data.

```sh
npm run typecheck
npm run test:learning
npm run build
```

The fixed course's source links and rights are in `content/physics.json`. Its prose is original AI-drafted material, not a reproduced Feynman book or an educator-validated course. `content/argentina.json` is an original illustrative sample with later outlines, not a vetted textbook.

## Publishing

The maintained app uses Sites. A fork must register its own Site, retain its returned project ID locally, declare D1 as `DB` and R2 as `BUCKET`, then publish through Sites' source/version/deployment workflow. The public manifest deliberately contains no production project ID. Sites applies the migrations in `drizzle/`. Keep authentication at the platform boundary; do not deploy the local mock-auth middleware to production.

## Privacy and current limits

Private account records are separated by server-authenticated owner. They are **not end-to-end encrypted**: the service operator and hosting provider can technically access stored data. No advertising trackers or AI-provider calls are added to this release. Public source contains no learner records. Contact `jarvis@agi-jarvis.com` for account deletion or a privacy issue.

Imports allow 40 books, 8 MB per input file, 100 chapters, and 1.5 MB of extracted structured text per book. EPUB extraction also bounds expanded text to 8 MB. Notes support 1,000 entries; the total account-record limit is 1.5 MB. If a cap or save failure occurs, the app explains it and preserves existing stored records. Export streams book objects one at a time.

This web account does not sync with the native iPhone app. Native AI generation, rewriting, BookBot, narration, revision history and offline storage remain native capabilities. There is no public AI generation endpoint or paid-provider key in the web bundle. The native App Store checklist remains separate.

## License

Original GenBooks code and content use the repository's MIT license. Framework, component and compression libraries retain their own licenses. Preserve `THIRD_PARTY_NOTICES.md` and bundled license files. Imported books are not relicensed by importing them.
