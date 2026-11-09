#!/usr/bin/env python3
"""Validate, archive and extract the paired Markdown release notes."""
import argparse
import datetime
from pathlib import Path
import re
import sys


LANGUAGES = (
    ('CHANGELOG.md', 'Unreleased', ('Added', 'Improved', 'Fixed'), 'Maintenance release.'),
    ('CHANGELOG.zh-CN.md', '未发布', ('新增', '改进', '修复'), '维护更新。'),
)
TAG = r'v(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)'


def entry_counts(body, categories):
    counts = dict.fromkeys(categories, 0)
    seen = set()
    category = None
    in_entry = False
    for line in body.splitlines():
        if not line.strip():
            continue
        if line.startswith('### '):
            category = line[4:].strip()
            if category not in counts or category in seen:
                raise ValueError(f'未知或重复的分类：{category}')
            seen.add(category)
            in_entry = False
        elif line.startswith('- ') and line[2:].strip() and category:
            counts[category] += 1
            in_entry = True
        elif line.startswith('  ') and in_entry:
            continue
        else:
            raise ValueError(f'条目须放在分类下，以「- 」开头，续行缩进两格：{line}')
    return tuple(counts.values())


def parse(text, pending, categories):
    sections = re.split(r'(?m)^(?=## )', text)
    if len(sections) < 2 or sections[1].splitlines()[0] != f'## {pending}':
        raise ValueError(f'第一节必须为「## {pending}」')
    signatures = []
    seen = set()
    for index, section in enumerate(sections[1:]):
        heading, _, body = section.partition('\n')
        tag, date = '', ''
        if index:
            match = re.fullmatch(rf'## ({TAG}) · (\d{{4}}-\d{{2}}-\d{{2}})', heading)
            if not match:
                raise ValueError(f'无效的版本标题：{heading}')
            tag, date = match.groups()
            datetime.date.fromisoformat(date)
            if tag in seen:
                raise ValueError(f'重复版本：{tag}')
            seen.add(tag)
        counts = entry_counts(body, categories)
        if index and not any(counts):
            raise ValueError(f'{tag} 缺少更新说明')
        signatures.append((tag, date, counts))
    return sections, signatures


def maintain(root, command, tag=None):
    if command != 'check' and tag is None:
        raise ValueError('release 和 notes 必须指定 vX.Y.Z')
    if tag is not None and not re.fullmatch(TAG, tag):
        raise ValueError(f'无效的版本号：{tag}')
    files = []
    for filename, pending, categories, maintenance in LANGUAGES:
        path = root / filename
        try:
            sections, signatures = parse(path.read_text(encoding='utf-8'), pending, categories)
        except ValueError as error:
            raise ValueError(f'{filename}：{error}') from error
        files.append((path, sections, signatures, pending, categories, maintenance))
    if files[0][2] != files[1][2]:
        raise ValueError('中英文日志的版本、日期及各分类条目数量必须一致')
    tags = [signature[0] for signature in files[0][2]]
    if command == 'notes':
        if tag not in tags:
            raise ValueError(f'缺少 {tag} 的更新说明')
        index = tags.index(tag) + 1
        en, zh = [file[1][index].partition('\n')[2].strip() for file in files]
        return f'## 简体中文\n\n{zh}\n\n---\n\n## English\n\n{en}\n'
    if tag in tags:
        raise ValueError(f'已有 {tag}，不能重复归档')
    if command == 'release':
        today = datetime.date.today().isoformat()
        for path, sections, signatures, pending, categories, maintenance in files:
            notes = sections[1].partition('\n')[2].strip()
            if not any(signatures[0][2]):
                notes = f'### {categories[1]}\n\n- {maintenance}'
            sections[1] = f'## {pending}\n\n## {tag} · {today}\n\n{notes}\n\n'
            path.write_text(''.join(sections).rstrip() + '\n', encoding='utf-8')
    return ''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('check', 'release', 'notes'))
    parser.add_argument('tag', nargs='?', help='vX.Y.Z; optional for check')
    args = parser.parse_args()
    try:
        sys.stdout.write(maintain(Path(__file__).resolve().parents[1], args.command, args.tag))
    except (OSError, ValueError) as error:
        print(f'changelog: {error}', file=sys.stderr)
        sys.exit(1)


if __name__ == '__main__':
    main()
