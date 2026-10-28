#!/usr/bin/env python3
"""Check README indexing without network access or external packages."""
import hashlib
import importlib.util
from pathlib import Path
import unittest

root = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("build_help", root / "scripts/build-help.py")
generator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(generator)


class HelpContentTests(unittest.TestCase):
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


if __name__ == '__main__':
    unittest.main()
