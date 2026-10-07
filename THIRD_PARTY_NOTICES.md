# Third-party notices

The root MIT license covers original GenBooks software, documentation, and the original fixtures identified in [Content provenance](docs/content-provenance.md). Copyright remains with the respective contributors and third-party owners. A reference link is not a license grant. User-imported books and runtime source material retain their own rights.

## SwiftSoup

GenBooks uses [SwiftSoup](https://github.com/scinfu/SwiftSoup) for HTML parsing. The dependency is pinned in `project.yml` to revision `18b80329749eca5ea29fc50211dca5c7eff5bfec`. Its [upstream license](https://github.com/scinfu/SwiftSoup/blob/18b80329749eca5ea29fc50211dca5c7eff5bfec/LICENSE) is reproduced below.

```text
The MIT License

Copyright (c) 2009-2025 Jonathan Hedley <https://jsoup.org/>
Copyright (c) 2016-2025 Nabil Chatbi (Swift port)

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

## Runtime sources and imported books

Wikipedia-derived source previews retain the retrieved page URL, recorded revision, attribution, license metadata, and exact retained source text. Those records do not turn source content into MIT-licensed GenBooks content. Follow the recorded source's terms when redistributing a generated or adapted work.

The Physics course links to factual references from NIST, NASA, and OpenStax. Its original wording and original questions are project content; linked source prose, exercises, illustrations, and tables are not relicensed. In particular, an OpenStax link does not grant unrestricted reuse of that site's content.

Apple SDKs, platform fonts, and system symbols are used through the platform. Their ownership and applicable developer terms remain separate from this repository's MIT license.

## Original project artwork

The current app-icon and cover PNGs are original geometric renderings of `scripts/generate_brand_assets.swift`, included under the project MIT license. The generator uses no input images, external fonts, or third-party marks. This notice applies to those current generated assets; it does not clear earlier image masters or third-party book content.


## Web application

The web application preserves the component, framework and compression notices in [web/THIRD_PARTY_NOTICES.md](web/THIRD_PARTY_NOTICES.md). Its dependency lockfile and bundled licenses are included.
