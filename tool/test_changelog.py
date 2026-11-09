"""Exercise bilingual changelog maintenance."""
import datetime
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest


SOURCE = Path(__file__).resolve().parents[1]
EN = """# Changelog

## Unreleased

### Added

- Read comics offline.
  Includes exported images.

### Fixed

- Show available updates.

## v1.0.0 · 2026-10-01

### Added

- First release.
"""
ZH = """# 更新日志

## 未发布

### 新增

- 离线阅读漫画。
  包含导出的图片。

### 修复

- 显示可用更新。

## v1.0.0 · 2026-10-01

### 新增

- 首次发布。
"""


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / 'tool').mkdir()
        shutil.copy(SOURCE / 'tool/changelog.py', self.root / 'tool')
        self.en = self.root / 'CHANGELOG.md'
        self.zh = self.root / 'CHANGELOG.zh-CN.md'
        self.en.write_text(EN, encoding='utf-8')
        self.zh.write_text(ZH, encoding='utf-8')

    def run_changelog(self, *args):
        return subprocess.run(
            [sys.executable, str(self.root / 'tool/changelog.py'), *args],
            cwd=self.root, capture_output=True, text=True,
        )

    def test_archive_keeps_history_and_notes_select_only_requested_version(self):
        result = self.run_changelog('release', 'v1.1.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        today = datetime.date.today().isoformat()
        for path, pending, original in [
            (self.en, 'Unreleased', EN), (self.zh, '未发布', ZH),
        ]:
            archived = path.read_text(encoding='utf-8')
            self.assertIn(f'## {pending}\n\n## v1.1.0 · {today}\n', archived)
            self.assertEqual(archived.split('## v1.0.0')[1], original.split('## v1.0.0')[1])
        result = self.run_changelog('notes', 'v1.1.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, """## 简体中文

### 新增

- 离线阅读漫画。
  包含导出的图片。

### 修复

- 显示可用更新。

---

## English

### Added

- Read comics offline.
  Includes exported images.

### Fixed

- Show available updates.
""")
        self.assertNotEqual(self.run_changelog('notes', 'v9.9.9').returncode, 0)

    def test_invalid_pair_never_partially_archives(self):
        for invalid in [
            ZH.replace('- 显示可用更新。', ''),
            ZH.replace('### 修复', '### 改进'),
            ZH.replace('## 未发布', '## 待发布'),
            ZH + '\n## 未发布\n',
            ZH.replace('2026-10-01', '2026-10-02'),
            ZH.replace('2026-10-01', '2026-13-01'),
            ZH.replace('### 新增', '### 自定义'),
            ZH.replace('- 显示可用更新。', 'TODO'),
            ZH + '\n## v1.0.0 · 2026-10-01\n\n### 新增\n\n- 重复。\n',
        ]:
            with self.subTest(invalid=invalid):
                self.zh.write_text(invalid, encoding='utf-8')
                result = self.run_changelog('release', 'v1.1.0')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.en.read_text(encoding='utf-8'), EN)
                self.assertEqual(self.zh.read_text(encoding='utf-8'), invalid)

    def test_duplicate_or_invalid_target_does_not_change_files(self):
        for tag in ['v1.0.0', '1.1.0', 'v1.1', 'v1.1.0\n', 'v01.1.0']:
            for command in ['check', 'release']:
                with self.subTest(tag=tag, command=command):
                    self.assertNotEqual(self.run_changelog(command, tag).returncode, 0)
                    self.assertEqual(self.en.read_text(encoding='utf-8'), EN)
                    self.assertEqual(self.zh.read_text(encoding='utf-8'), ZH)

    def test_empty_pending_sections_get_bilingual_maintenance_notes(self):
        self.en.write_text('# Changelog\n\n## Unreleased\n\n### Added\n', encoding='utf-8')
        self.zh.write_text('# 更新日志\n\n## 未发布\n', encoding='utf-8')
        self.assertEqual(self.run_changelog('check').returncode, 0)
        result = self.run_changelog('release', 'v1.1.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        result = self.run_changelog('notes', 'v1.1.0')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn('- 维护更新。', result.stdout)
        self.assertIn('- Maintenance release.', result.stdout)
        self.assertEqual(self.run_changelog('check').returncode, 0)


if __name__ == '__main__':
    unittest.main()
