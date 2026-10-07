# Content provenance

The repository license covers original project work. It does not override another author's rights, a source website's terms, or the license of a book imported by a reader. Code, educational prose, source evidence, and artwork need separate provenance records.

## Included original material

| Material | Origin and license | Quality boundary |
| --- | --- | --- |
| `Resources/foundations.json` and public documentation | Original GenBooks explanatory content; MIT | Definitions and explicit product policies, not a validated learning-effect model |
| `Resources/Fixtures/physics_foundations.json` | Original GenBooks readings and questions, drafted and reviewed with AI against linked factual references; MIT for the original wording | Not independently reviewed by a human physics educator. Linked sources are not copied or relicensed |
| `Resources/Fixtures/argentina_minimal.json` | Original project manuscript constructed by `scripts/content/generate_argentina_manuscript.py`; MIT | Illustrative historical narrative and outline scaffold, not an authoritative textbook or another historian's published work |
| `Resources/Fixtures/friend_canon.epub` | Original two-chapter *Plaza Evening* import fixture; MIT. “A Friend” is the fixture's demo author label | Tests text preservation and import behavior; not a purchased or externally supplied book |
| Current app icons and book covers | Original geometric artwork reproducible with `scripts/generate_brand_assets.swift`; MIT | The generator uses no input image. Generic book-cover art does not license any corresponding book text |

The Argentina manuscript's aphorisms and scaffold passages are original narrative elements, not attributed quotations from historical figures. Its reference to a narrative style does not imply that prose from that author's books is included. Historical assertions still need better specific sourcing before presenting the sample as an educational authority.

## External material stays separate

The Physics course cites NIST, NASA, and OpenStax as factual references. It does not bundle their prose, question banks, tables, or figures. Reuse of those materials would require checking the exact source's terms and recording attribution. A citation is not permission to copy.

The public snapshot omits the exact Tanzil Pickthall translation download and the JSON generated from it. Tanzil's [translation terms](https://tanzil.net/trans/) restrict those downloads to noncommercial purposes unless the required permission is obtained. Its [Quran text license](https://tanzil.net/docs/text_license) concerns a different text resource and must not be substituted for the translation terms. A public-domain claim about an underlying historical edition does not establish the rights of this specific supplied digital file.

Optional-edition identifiers and tests retain a few short recognition excerpts to check the expected translation when separately supplied. These are attributed to the Pickthall edition, not presented as original GenBooks prose or included in the MIT grant. Generic clipboard and voice tests use original prose instead. The public repository does not include the full translation corpus.

The app may recognize a previously saved optional sample without distributing its source bytes. Omitting that sample from an app bundle must not delete an existing user's book. Tests of the absent translation explicitly skip; they do not fabricate verses or claim a content check passed.

With that edition absent, the resource-specific suite adds **10 unit-test skips and one UI-test skip**: seven `QuranFixtureTests`, the seed-specific Make Living check, two Quran-specific recovery checks, and the Quran Guide journey. Other live-service or isolated-fixture opt-in skips are counted separately. Generic ordering, protected identity, damaged-book handling, cover routing, and the empty Words journey still run using original fixtures or metadata. Present but malformed content must fail its normal assertions, not skip.

Runtime Wikipedia excerpts retain attribution, revision and license metadata. Imported books remain the reader's content with their original rights. The repository's MIT license does not grant rights to redistribute either category. SwiftSoup's separate notice is in [Third-party notices](../THIRD_PARTY_NOTICES.md).

## Adding or replacing content

Record the exact file, author or creator, source URL when applicable, license, modifications, and AI assistance. For generated images, preserve the creation record; for deterministic artwork, preserve the original generator. Do not inherit a rights claim from an old filename or a “public-domain style” label. Keep any new sample separate from personal reading data and test that adding it preserves existing books.
