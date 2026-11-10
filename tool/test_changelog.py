"""Exercise changelog maintenance and releases in disposable repositories."""
import datetime
import os
from pathlib import Path
import shlex
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
            [sys.executable, '-X', 'utf8', str(self.root / 'tool/changelog.py'), *args],
            cwd=self.root, capture_output=True, text=True, encoding='utf-8',
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


class ReleaseTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        base = Path(self.temp.name)
        self.root = base / 'checkout'
        self.root.mkdir()
        self.remote = base / 'origin.git'
        self.env = dict(os.environ, PYTHONUTF8='1', GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1',
                        GIT_AUTHOR_NAME='Release Test', GIT_AUTHOR_EMAIL='test@example.invalid',
                        GIT_COMMITTER_NAME='Release Test', GIT_COMMITTER_EMAIL='test@example.invalid')
        self.git('init', '--bare', str(self.remote))
        self.git('init', '-b', 'main')
        (self.root / 'tool').mkdir()
        shutil.copy(SOURCE / 'release.sh', self.root)
        shutil.copy(SOURCE / 'tool/changelog.py', self.root / 'tool')
        (self.root / 'pubspec.yaml').write_text('name: sillydraft\nversion: 1.0.0+1\n')
        (self.root / 'CHANGELOG.md').write_text(EN, encoding='utf-8')
        (self.root / 'CHANGELOG.zh-CN.md').write_text(ZH, encoding='utf-8')
        (self.root / 'unrelated.txt').write_text('original\n')
        self.git('add', 'release.sh', 'tool/changelog.py', 'pubspec.yaml',
                 'CHANGELOG.md', 'CHANGELOG.zh-CN.md', 'unrelated.txt')
        self.git('commit', '-m', 'initial')
        self.git('remote', 'add', 'origin', str(self.remote))
        self.git('push', '-u', 'origin', 'main')
        self.before = self.git('rev-parse', 'HEAD')

    def git(self, *args):
        return subprocess.check_output(['git', *args], cwd=self.root, env=self.env,
                                       stderr=subprocess.PIPE, text=True, encoding='utf-8').strip()

    def release(self, *args, answer='y\n', kind='patch'):
        command = ['bash', 'release.sh', *args]
        if kind is not None:
            command.append(kind)
        # Binary stdin preserves the LF that Git Bash's read expects on Windows.
        result = subprocess.run(command, cwd=self.root, env=self.env,
                                input=answer.encode('utf-8'), capture_output=True)
        result.stdout = result.stdout.decode('utf-8')
        result.stderr = result.stderr.decode('utf-8')
        return result

    def python_commands(self, available):
        commands = Path(self.temp.name) / 'commands with spaces'
        commands.mkdir()
        for name in ('python3', 'python', 'py'):
            script = '#!/bin/bash\n'
            if name == available:
                if name == 'py':
                    script += '[[ $1 == -3 ]] || exit 2\nshift\n'
                script += f'exec {shlex.quote(Path(sys.executable).as_posix())} "$@"\n'
            else:
                # Reproduce the silent failure of a Windows app execution alias.
                script += 'exit 49\n'
            path = commands / name
            path.write_text(script, encoding='utf-8', newline='\n')
            path.chmod(0o755)
        self.env['PATH'] = str(commands) + os.pathsep + self.env['PATH']

    def hook(self, path):
        path.write_text('#!/bin/sh\nexit 1\n')
        path.chmod(0o755)

    def test_release_commits_and_pushes_only_version_and_changelogs(self):
        (self.root / 'unrelated.txt').write_text('staged\n')
        self.git('add', 'unrelated.txt')
        (self.root / 'unrelated.txt').write_text('unstaged\n')
        result = self.release('--allow-dirty')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git('diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD'),
                         'CHANGELOG.md\nCHANGELOG.zh-CN.md\npubspec.yaml')
        self.assertEqual(self.git('status', '--porcelain'), 'MM unrelated.txt')
        self.assertEqual(self.git('show', ':unrelated.txt'), 'staged')
        self.assertEqual((self.root / 'unrelated.txt').read_text(), 'unstaged\n')
        self.assertEqual(self.git('show', 'v1.0.1:pubspec.yaml'), 'name: sillydraft\nversion: 1.0.1+2')
        self.assertIn('## v1.0.1 · ', self.git('show', 'v1.0.1:CHANGELOG.zh-CN.md'))
        self.assertEqual(self.git('--git-dir', str(self.remote), 'rev-parse', 'main'),
                         self.git('rev-parse', 'v1.0.1^{}'))

    def test_interactive_release_falls_back_when_python3_alias_cannot_run(self):
        self.python_commands('python')
        result = self.release(kind=None, answer='1\ny\n')
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git('show', 'v1.0.1:pubspec.yaml'), 'name: sillydraft\nversion: 1.0.1+2')
        self.assertIn('## v1.0.1 · ', self.git('show', 'v1.0.1:CHANGELOG.zh-CN.md'))
        self.assertEqual(self.git('--git-dir', str(self.remote), 'rev-parse', 'main'),
                         self.git('rev-parse', 'v1.0.1^{}'))

    def test_release_uses_py_launcher_when_python_commands_cannot_run(self):
        self.python_commands('py')
        result = self.release()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.git('show', 'v1.0.1:pubspec.yaml'), 'name: sillydraft\nversion: 1.0.1+2')
        self.assertEqual(self.git('--git-dir', str(self.remote), 'rev-parse', 'main'),
                         self.git('rev-parse', 'v1.0.1^{}'))

    def test_unavailable_python_reports_problem_without_release_changes(self):
        self.python_commands(None)
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('Python 3', result.stderr)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.before)
        self.assertEqual(self.git('tag'), '')
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual(self.git('--git-dir', str(self.remote), 'rev-parse', 'main'), self.before)

    def test_dirty_release_files_are_rejected_even_when_allowed(self):
        for name in ['pubspec.yaml', 'CHANGELOG.md', 'CHANGELOG.zh-CN.md']:
            with self.subTest(name=name):
                path = self.root / name
                original = path.read_text(encoding='utf-8')
                path.write_text(original + '\n', encoding='utf-8')
                result = self.release('--allow-dirty')
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(path.read_text(encoding='utf-8'), original + '\n')
                self.assertEqual(self.git('rev-parse', 'HEAD'), self.before)
                self.assertEqual(self.git('tag'), '')
                path.write_text(original, encoding='utf-8')

    def test_invalid_translation_and_cancellation_leave_no_release_changes(self):
        result = self.release(answer='n\n')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git('status', '--porcelain'), '')
        (self.root / 'CHANGELOG.zh-CN.md').write_text(ZH.replace('- 显示可用更新。', ''), encoding='utf-8')
        self.git('add', 'CHANGELOG.zh-CN.md')
        self.git('commit', '-m', 'incomplete translation')
        before = self.git('rev-parse', 'HEAD')
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git('rev-parse', 'HEAD'), before)
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertEqual(self.git('tag'), '')

    def test_commit_failure_restores_release_files_and_preserves_staging(self):
        (self.root / 'unrelated.txt').write_text('staged\n')
        self.git('add', 'unrelated.txt')
        self.hook(self.root / '.git/hooks/pre-commit')
        result = self.release('--allow-dirty')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.before)
        self.assertEqual(self.git('status', '--porcelain'), 'M  unrelated.txt')
        self.assertEqual(self.git('tag'), '')

    def test_push_failure_keeps_complete_local_release_for_retry(self):
        self.hook(self.remote / 'hooks/pre-receive')
        result = self.release()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('git push --atomic', result.stderr)
        self.assertNotEqual(self.git('rev-parse', 'HEAD'), self.before)
        self.assertEqual(self.git('rev-parse', 'HEAD'), self.git('rev-parse', 'v1.0.1^{}'))
        self.assertEqual(self.git('status', '--porcelain'), '')
        self.assertIn('## v1.0.1 · ', self.git('show', 'HEAD:CHANGELOG.md'))
        self.assertEqual(self.git('--git-dir', str(self.remote), 'rev-parse', 'main'), self.before)


if __name__ == '__main__':
    unittest.main()
