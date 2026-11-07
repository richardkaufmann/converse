#!/usr/bin/env python3
"""Check README indexing without network access or external packages."""
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path
import unittest
from unittest import mock

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_help", root / "scripts/build-help.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class HelpContentTests(unittest.TestCase):
    def test_native_onboarding_links_have_real_help_destinations(self):
        source = (root / 'README.md').read_text()
        topics = {topic['id'] for topic in generator.build_book(source)['topics']}
        swift = (root / 'Sources/AppSupport.swift').read_text()
        csharp = (root / 'windows/src/Converse.Core/AppSupport.cs').read_text()
        # Extract the actual routing tables, so renaming a README topic cannot
        # silently break a welcome link while a text-search fallback hides it.
        swift_routes = re.search(r'static let guideTopics = (\[[^\n]+\])', swift).group(1)
        cs_routes = re.search(r'Topics = new\(\)\s*\{(.*?)\};', csharp, re.S).group(1)
        destinations = re.findall(r':\s*"([a-z-]+)"', swift_routes)
        destinations += re.findall(r'\]\s*=\s*"([a-z-]+)"', cs_routes)
        destinations += re.findall(r'helpController.show\(topic: "([a-z-]+)"', swift)
        for destination in destinations:
            with self.subTest(topic=destination):
                self.assertIn(destination, topics)

    def test_walkthrough_local_links_resolve(self):
        source = (root / 'README.md').read_text()
        headings = re.findall(r'^#{1,6}\s+(.+)$', source, re.M)
        anchors = {re.sub(r'[^a-z0-9 -]', '', heading.lower()).replace(' ', '-') for heading in headings}
        for target in re.findall(r'\]\(([^\s)]+)\)', source):
            if '://' in target:
                continue
            with self.subTest(target=target):
                if target.startswith('#'):
                    self.assertIn(target[1:], anchors)
                else:
                    self.assertTrue((root / target.split('#')[0]).exists())

    def test_code_fences_do_not_create_help_topics(self):
        source = '# Converse\nIntro.\n## Sending\n```converse\n## This is code\n{"command":"list-sessions"}\n```\n### Detail\nKeep this.\n## Accounts\nLog in.\n'
        book = generator.build_book(source)
        self.assertEqual([topic['id'] for topic in book['topics']], ['overview', 'sending', 'accounts'])
        self.assertIn('## This is code', book['topics'][1]['markdown'])
        self.assertIn('### Detail', book['topics'][1]['markdown'])

    def test_relative_links_are_readable_outside_the_repository(self):
        book = generator.build_book('## Build\n[Signing](docs/signed-releases.md)\n[Accounts](#accounts)\n')
        content = book['topics'][0]['markdown']
        self.assertIn('https://github.com/richardkaufmann/converse/blob/main/docs/signed-releases.md', content)
        self.assertIn(generator.SOURCE_URL + '#accounts', content)

    def test_duplicate_headings_keep_distinct_stable_topic_ids(self):
        book = generator.build_book('## Setup\nOne.\n## Setup\nTwo.\n')
        self.assertEqual([topic['id'] for topic in book['topics']], ['setup', 'setup-2'])

    def test_readme_provenance_and_decorative_html(self):
        source = '<p align="center">\n<img src="logo.png">\n</p>\n# Converse\nActual help.\n'
        book = generator.build_book(source)
        self.assertEqual(book['sourceSHA256'], hashlib.sha256(source.encode()).hexdigest())
        self.assertNotIn('<img', book['topics'][0]['markdown'])
        self.assertIn('Actual help.', book['topics'][0]['markdown'])

    def test_source_commit_without_git_is_unknown(self):
        with mock.patch.object(generator.subprocess, 'run', side_effect=FileNotFoundError('git')):
            self.assertEqual(generator.source_commit(root), 'unknown')
        with mock.patch.object(generator.subprocess, 'run', side_effect=PermissionError('git')):
            self.assertEqual(generator.source_commit(root), 'unknown')

    def test_readme_scoreboard_and_caption_are_excluded_from_help(self):
        source = (root / 'README.md').read_text()
        self.assertIn('docs/converse-status.jpg', source)
        book = generator.build_book(source)
        markdown = '\n'.join(topic['markdown'] for topic in book['topics'])
        plain = '\n'.join(topic['plainText'] for topic in book['topics'])
        for rendered in (markdown, plain):
            self.assertNotIn('converse-status.jpg', rendered)
            self.assertNotIn("Muse's pictoral representation", rendered)
            self.assertNotIn('readme-only:', rendered)
            self.assertIn('It talks to the outside world.', rendered)
            self.assertIn('It has polish.', rendered)

    def test_readme_only_blocks_preserve_surrounding_prose_and_code_examples(self):
        source = '# App\nBefore\n<!-- readme-only:start -->\n![Art](docs/art.jpg)\n\n*Caption*\n<!-- readme-only:end -->\nAfter\n```html\n<!-- readme-only:start -->\nExample\n<!-- readme-only:end -->\n```\n'
        markdown = generator.build_book(source)['topics'][0]['markdown']
        self.assertNotIn('docs/art.jpg', markdown)
        self.assertNotIn('*Caption*', markdown)
        self.assertIn('Before\nAfter', markdown)
        self.assertIn('<!-- readme-only:start -->\nExample', markdown)

    def test_help_builds_on_a_machine_without_git(self):
        with tempfile.TemporaryDirectory() as directory:
            directory = Path(directory)
            (directory / 'README.md').write_text('# Converse\nIntro.\n## Sending\nType and press Return.\n')
            shutil.copy(root / 'VERSION.json', directory / 'VERSION.json')
            output = directory / 'Content.json'
            empty_path = directory / 'empty-bin'
            empty_path.mkdir()
            result = subprocess.run(
                [sys.executable, str(root / 'scripts/build-help.py'), str(directory / 'README.md'), '--out', str(output)],
                env={**os.environ, 'PATH': str(empty_path)}, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            book = json.loads(output.read_text())
            self.assertEqual(book['sourceCommit'], 'unknown')
            self.assertEqual([topic['id'] for topic in book['topics']], ['overview', 'sending'])


if __name__ == '__main__':
    unittest.main()
