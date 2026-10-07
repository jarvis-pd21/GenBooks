# Design

This page describes the native iPhone app. For the public web app and its separate account storage, see the [web documentation](../web/README.md).

GenBooks organizes reading and learning around three jobs: choose something to read, continue a learning path, and revisit saved material. The interface makes the next action easy to find while keeping explanations, sources, and settings reachable. These are design intentions, not measured improvements in learning or enjoyment.

## Navigation and hierarchy

The native tab bar contains **Library**, **Learning**, and **Notebook**, in that order. Each destination has its own navigation stack, so switching tabs can preserve a detail page. Library opens locally saved books; Learning holds the fixed Physics course; Notebook groups saved Words and Notes behind one search field. A Settings gear on each destination opens the same settings surface. This uses familiar platform navigation and follows [Apple’s tab-bar guidance](https://developer.apple.com/design/human-interface-guidelines/tab-bars).

Learning uses a compact native navigation title, **Learning**, and a separate serif **Physics** heading within the page. The two labels identify the destination and its course. Library and Notebook use large native navigation titles. Native navigation containers manage content insets around the bars.

The Learning home presents one suggested next activity with **Read** or **Review concept** as its primary action. The Physics check score follows, then grouped Readings and links to Concepts, Sources and authorship, and Foundations. All six readings remain directly selectable. Grouping related rows and moving long explanations into detail pages apply [Apple’s guidance on hierarchy and progressive disclosure](https://developer.apple.com/news/?id=s8sl4tpa): show the useful entry point first, then let the reader open its explanation.

## Reading and honest feedback

Lessons put the opening question and reading before optional practice. **Finish reading** records reading completion; it does not award check points. Selecting an answer does not submit it. **Save my answer** records the response, while **Skip** leaves no submitted answer. Opening the explanation first records help used.

The **Physics check score** summarizes results on ten designated multiple-choice checks. It is not a percentage of everything someone knows. Unchecked slots remain distinguishable from counted incorrect answers, and practice-only responses explain why they do not change the score. Reading completion, self-reports, and question results remain separate. See the [exact score policy](physics-score.md).

Sources and authorship are available from Learning, with further references inside Foundations. These links make provenance inspectable; their presence does not establish that every claim or generated reply is correct. BookBot replies are not independently source-verified.

## Appearance and explanation

The shared palette names colors by their role—text, background, surface, accent—and supplies light and dark variants. This follows [Apple’s Dark Mode guidance](https://developer.apple.com/design/human-interface-guidelines/dark-mode). Serif headings and lesson text distinguish reading from controls and supporting information. Scalable text styles and scrolling accommodate larger text; at accessibility sizes, Notebook uses a menu for its collection picker and New Book uses a menu for its mode selector. [Apple’s Larger Text criteria](https://developer.apple.com/help/app-store-connect/manage-app-accessibility/larger-text-evaluation-criteria) guide evaluation of overlap, truncation, and access to complete content.

Settings groups appearance, learning preferences, optional BookBot configuration, and app information. Foundations starts with the mission and vision, followed by Definitions and How it works. Short summaries lead to full explanations and sources rather than squeezing the reference material onto the home screen.

## Offline baseline and verification

Saved books, the bundled Physics course, and saved learning progress work offline. Opening a saved book does not call AI. New AI replies, generation, retrieved sources, and uncached narration require a network and the relevant provider.

Interface changes must be visually inspected in four cases: light and dark appearance, each at standard text size and Accessibility XXXL. Exercise the affected navigation and actions through native interface tests as well. Layout and interaction evidence does not establish that GenBooks improves durable learning or sustained enjoyment. Those outcomes require separate evaluation.
