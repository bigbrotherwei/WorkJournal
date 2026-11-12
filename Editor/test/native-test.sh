#!/bin/zsh
set -eu
cd "${0:A:h}/../.."
TEST_DIR=$(mktemp -d /private/tmp/workjournal-native-editor.XXXXXX)
trap 'rm -rf "$TEST_DIR"' EXIT
python3 - "$TEST_DIR" "$PWD" <<'PY'
import pathlib,sys
out,root=map(pathlib.Path,sys.argv[1:])
source=(root/'Sources/WorkJournal/NotebookEditor.swift').read_text().replace('import JournalCore','')
resource=str(root/'Sources/WorkJournal/Resources/NotebookEditor/index.html').replace('\\','\\\\').replace('"','\\"')
source=source.replace('Bundle.module.url(forResource: "index", withExtension: "html", subdirectory: "NotebookEditor")', 'URL(fileURLWithPath: "'+resource+'")')
source+='\n'+(root/'Editor/test/native-harness.swift').read_text()
(out/'Controller.swift').write_text(source)
PY
swiftc -parse-as-library -swift-version 5 -module-cache-path "$PWD/.build/module-cache" Sources/JournalCore/NotebookModels.swift "$TEST_DIR/Controller.swift" -o "$TEST_DIR/harness"
"$TEST_DIR/harness"
