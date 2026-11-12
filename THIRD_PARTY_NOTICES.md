# Third-party software

## Offline notebook editor

The notebook editor embeds **Tiptap 3.33.1** (MIT) and its ProseMirror-based extensions. Tiptap was chosen in place of the initial Milkdown preference because its established extensions cover editable text color, highlighting, alignment, underline, sub/superscript, and merged table cells. The Markdown extension is beta; application roundtrip tests and controlled HTML fallback cover rich attributes that the default serializer cannot represent.

All JavaScript, CSS and language grammars are bundled into the application. There are no runtime CDNs, analytics, remote fonts or network editing services. Versions and integrity hashes are recorded in `Editor/package-lock.json`.

Runtime packages include Tiptap/ProseMirror/marked (MIT), lowlight and supporting hast utilities (MIT), highlight.js (BSD-3-Clause), and DOMPurify 3.4.17 (Apache-2.0 OR MPL-2.0; used under Apache-2.0). `Editor/build.mjs` extracts the license text of each package actually included in the bundle, failing the build if a package lacks its license. The complete 50-package license inventory and copyright notices ship in `Sources/WorkJournal/Resources/NotebookEditor/THIRD_PARTY_LICENSES.txt`. Additional retained source comments are in `editor.js.LEGAL.txt` alongside it.

Build/test tools, not shipped with the app, include esbuild (MIT) and jsdom (MIT) and their locked dependencies.

The full application also uses SwiftSoup; its license is retained in the pinned Swift package distribution.
