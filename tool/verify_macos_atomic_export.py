"""Exercise the production writer with write access to one selected file only.

Run on macOS: python3 tool/verify_macos_atomic_export.py
Uses temporary fixtures, Swift and sandbox-exec; no existing documents or UI.
This verifies file-scoped permissions, not NSSavePanel interaction automation.
"""
import pathlib
import subprocess
import tempfile

root = pathlib.Path(__file__).resolve().parents[1]
source = (root / 'macos/Runner/MainFlutterWindow.swift').read_text()
with tempfile.TemporaryDirectory(prefix='sillydraft-save-sandbox-') as temporary:
    directory = pathlib.Path(temporary).resolve()
    selected = directory / 'selected'
    selected.mkdir()
    target = selected / 'novel.txt'
    swift = directory / 'probe.swift'
    executable = directory / 'probe'
    swift.write_text('import Foundation\n' + source[source.index('enum AtomicFileExport'):] + '''
let target = URL(fileURLWithPath: CommandLine.arguments[1])
let bytes = Data(CommandLine.arguments[2].utf8)
if CommandLine.arguments.count > 3 {
  do {
    try bytes.write(to: URL(fileURLWithPath: target.path + ".sibling.tmp"))
  } catch { exit(23) }
} else {
  try AtomicFileExport.write(bytes, to: target)
}
''')
    subprocess.run(['xcrun', 'swiftc', str(swift), '-o', str(executable)], check=True)
    profile = (
        '(version 1)(allow default)(deny file-write* (subpath "' + str(selected)
        + '"))(allow file-write* (literal "' + str(target) + '"))'
    )

    def run(value, sibling=False):
        return subprocess.run(
            ['/usr/bin/sandbox-exec', '-p', profile, str(executable), str(target), value]
            + (['sibling'] if sibling else []), capture_output=True, text=True,
        )

    assert run('bad', sibling=True).returncode == 23, 'Sibling must be denied'
    for value in ['new export', 'replacement export']:
        result = run(value)
        assert result.returncode == 0, result.stderr
        assert target.read_text() == value
    assert list(selected.iterdir()) == [target], 'No sibling artifacts should remain'
    print('PASS: file-only sandbox denied sibling temp; Foundation created and replaced selected file.')
