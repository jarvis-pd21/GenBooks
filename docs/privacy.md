# Data flow and privacy

This page describes the current source architecture. It is not a claim of App Store approval, a completed legal privacy policy, or a promise about an external provider's retention. A distributor must publish a policy for the exact build and services it ships.

## Local data

Books, revisions, reading checkpoints, bookmarks, notes, saved words, authoring drafts, cached narration, and learning records live in app-owned local storage. Learning progress is separate from Library manuscripts. Display settings use UserDefaults. Optional provider keys use iOS Keychain. The Share extension stages supported files in an app-group container so the app can import them.

GenBooks has no user account or shared sync backend. This does not mean a device's operating-system backup settings cannot copy app data. Do not describe local storage as a guarantee that no copy can ever leave the device.

## Actions that can send data

| Action | Destination and data |
| --- | --- |
| Ask BookBot or request optional AI word help | OpenAI: the submitted prompt plus the reading context assembled for that request, which can include selected/surrounding text, chapter excerpts, notes, and supplied preferences |
| Generate or adapt a book | OpenAI: the brief, relevant manuscript context, preferences, and available research or source records needed for the request |
| Create a source-backed preview | Wikipedia: the requested topic/title and normal request metadata; OpenAI: the retained source excerpt and authoring/review prompts |
| Play or download uncached narration | OpenAI: the text chunks to synthesize; generated audio is cached locally |
| Dictate a question | Apple's Speech framework: on-device recognition is requested where supported; recognition can use Apple's network service otherwise. The resulting submitted question follows BookBot's data path |

A configured key authenticates OpenAI requests. The key is not a book attribute or learning score field. The app has no independent source-verification service for ordinary BookBot replies. Their disclosure describes evidence quality, not an exemption from privacy requirements.

Saved reading, notes, words, the fixed Physics course, and local learning checks do not need a provider request. If authoring or chat fails, saved reading stays available. Cached narration can play without generating new audio.

## Retention and controls

Records persist locally across normal launches. Archiving a book keeps it and its associated reading material; it is not erasure. Removing a local record does not revoke a provider key or erase an external provider's earlier records. Removing the app is not a verified provider-side deletion mechanism, and Keychain lifetime must not be assumed to match app-file lifetime.

Before public distribution, verify the controls for deleting local records, clearing cached audio, removing a configured key, and explaining what remains in device backups or at providers. The release policy must state the actual scope and contact route. See [App Store readiness](app-store-readiness.md).

## Development evidence

Do not publish private manuscripts, live model prompts, answers, account details, device logs, or unreviewed screenshots. Test attachments can contain screen text even when a separate screenshot file was not written. Public examples should use original or cleared synthetic content.
