# App Store readiness

This page describes the native iPhone app. For the public web app and its separate account storage, see the [web documentation](../web/README.md).

GenBooks is a development project. A public source repository, a successful simulator test, and a development install are different milestones from App Store submission or approval. This page lists concrete remaining release work; it does not claim completion or Apple endorsement.

## Release work

| Work | Completion evidence |
| --- | --- |
| Reproducible release build | Clean checkout builds with the distributor's app, extension, shared-container identifiers and signing configuration; generated files contain no private machine assumptions |
| Physical-device acceptance | Reader navigation, import, audio, microphone permissions, interrupted authoring, offline relaunch, large text, VoiceOver, and data preservation exercised on supported devices |
| Third-party AI disclosure and consent | Review every outbound path in [Privacy](privacy.md), explain the provider and transmitted context before sharing personal data, and verify the consent behavior of the release build |
| Published privacy policy and support | Public contact and policy URLs that describe real collection, sharing, retention, deletion, and the distributor's responsibilities; accessible from the app |
| Privacy manifest and store disclosures | Audit the compiled app and dependencies, include required-reason API declarations that match actual use, and complete accurate App Store Connect privacy answers |
| Content rights | A file-level record for every bundled book, image, icon, and screenshot; preserve applicable notices and exclude unresolved material |
| Complete metadata and review access | Accurate screenshots, age-rating answers, feature description, support URL, review instructions, and a usable way to examine optional AI features |
| Distribution and commercial design | Choose the supported territories, provider/key experience, and any payment model; review the requirements that apply to that exact design before submission |

Apple requires a privacy-policy link both in the app and store metadata, explicit permission before sharing personal data with third-party AI, and appropriate rights for included content. It also expects complete, tested submissions and accurate metadata. These are release obligations, not evidence that this repository already satisfies them. [App Review Guidelines, sections 2.1, 2.3, 5.1, and 5.2](https://developer.apple.com/app-store/review/guidelines/).

The bundled `Resources/PrivacyInfo.xcprivacy` declares app-only UserDefaults access with reason CA92.1. Audit the release archive and included dependencies for any additional applicable categories; this declaration is not a completed release privacy audit. Apple's required-reason API rules apply to the app and included third-party code. [Required-reason API documentation](https://developer.apple.com/documentation/bundleresources/describing-use-of-required-reason-api).

Local-first architecture alone does not determine the App Store privacy label. Account for optional online workflows and provider handling using Apple's data definitions and exceptions. [App privacy details](https://developer.apple.com/app-store/app-privacy-details/).

## Product claims to preserve

- The Physics check score is a ten-question product policy, not measured mastery or proven retention improvement.
- The Physics course is fixed original content, with disclosed AI assistance and reference links.
- Ordinary BookBot replies are not independently source-verified.
- Source-backed authoring currently covers an opening preview and a limited selected-word continuation, not a fully verified generated textbook.
- New PDF imports retain the exact supplied PDF. Original pages displays its tables, figures, equations and layout, with zoom, contents, text-layer search and a separate saved page position. Text view is an extracted reading alternative and may omit these visual details. No OCR or image enhancement is performed.
- EPUB imports currently extract text; their illustrations and layout are not preserved. There is no in-app tool to attach a PDF to an older text-only import. Import its PDF as a new book to gain Original pages; existing notes stay on the earlier text copy.
- The native app has no account or cross-device sync. The separately deployed web app has its own account storage; native and web libraries do not synchronize.

Review these statements against the actual release before publishing store copy. Do not label simulator-only or skipped-provider evidence as a physical-device or live-service pass.
