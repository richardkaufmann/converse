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

    def video_manifest(self):
        return json.loads((root / 'docs/videos.json').read_text())

    def test_video_manifest_schema(self):
        manifest = self.video_manifest()
        self.assertEqual(generator.video_errors(manifest), [])
        videos = manifest['videos']
        self.assertTrue(videos)
        self.assertEqual(len({video['id'] for video in videos}), len(videos))
        for video in videos:
            with self.subTest(video=video['id']):
                self.assertGreater(video['durationSeconds'], 0)
                self.assertRegex(video['sha256'], r'^[0-9a-f]{64}$')
                for key in ('mediaURL', 'posterURL'):
                    self.assertTrue(video[key].startswith(generator.VIDEO_PREFIX))
                    self.assertRegex(video[key].rsplit('/', 1)[1], r'-v[0-9]+\.[a-z0-9]+$')

    def test_video_manifest_rejects_unsafe_entries(self):
        good = self.video_manifest()['videos'][0]
        cases = {
            'duplicate id': [good, dict(good, mediaURL=good['mediaURL'].replace('-v1', '-v2'))],
            'unversioned file': [dict(good, mediaURL=generator.VIDEO_PREFIX + 'converse-first-run.mp4')],
            'other release': [dict(good, mediaURL=good['mediaURL'].replace('/help-videos/', '/v0.7.10/'))],
            'signed redirect': [dict(good, mediaURL='https://objects.githubusercontent.com/converse-first-run-v1.mp4')],
            'short hash': [dict(good, sha256='abc')],
            'no duration': [dict(good, durationSeconds=0)],
            'boolean duration': [dict(good, durationSeconds=True)],
            'missing title': [{k: v for k, v in good.items() if k != 'title'}],
            'insecure watch page': [dict(good, watchURL='http://example.com/watch')],
        }
        for name, videos in cases.items():
            with self.subTest(case=name):
                self.assertTrue(generator.video_errors({'schemaVersion': 1, 'videos': videos}))
        self.assertTrue(generator.video_errors({'schemaVersion': 2, 'videos': []}))

    def test_help_json_carries_videos_and_a_videos_topic(self):
        videos = self.video_manifest()['videos']
        book = generator.build_book((root / 'README.md').read_text(), videos=videos)
        self.assertEqual(book['schemaVersion'], 1)
        self.assertEqual(book['videos'], videos)
        topics = {topic['id']: topic for topic in book['topics']}
        self.assertEqual(len(topics), len(book['topics']))
        topic = topics['videos']
        self.assertEqual(topic['title'], 'Videos')
        for video in videos:
            with self.subTest(video=video['id']):
                link = '[' + generator.watch_label(video) + '](' + video['mediaURL'] + ')'
                self.assertIn(link, topic['markdown'])
                self.assertIn(video['description'], topic['plainText'])
                self.assertIn(video['helpTopic'], topics)
                # The inline README link stays in the topic it belongs beside.
                self.assertIn(link, topics[video['helpTopic']]['markdown'])
        self.assertIn('work offline', topic['markdown'])
        self.assertEqual(book['topics'][:-1], generator.build_book((root / 'README.md').read_text())['topics'])
        self.assertNotIn('videos', generator.build_book('# App\nIntro.\n'))

    def test_video_help_topic_must_exist(self):
        video = dict(self.video_manifest()['videos'][0], helpTopic='missing-topic')
        with self.assertRaises(SystemExit):
            generator.build_book('# App\nIntro.\n', videos=[video])

    def test_readme_video_links_match_the_manifest(self):
        source = (root / 'README.md').read_text()
        videos = {video['mediaURL']: video for video in self.video_manifest()['videos']}
        links = re.findall(r'\[([^\]]+)\]\((' + re.escape(generator.VIDEO_PREFIX) + r'[^)\s]+)\)', source)
        self.assertTrue(links)
        for label, url in links:
            with self.subTest(url=url):
                self.assertIn(url, videos)
                self.assertEqual(label, generator.watch_label(videos[url]))
        self.assertEqual(generator.watch_label(videos[links[0][1]]), '\u25b6 Watch: First launch (25 s)')
        self.assertEqual(generator.duration_label(125.4), '2 min 5 s')

    def test_build_reads_the_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / 'Content.json'
            result = subprocess.run([sys.executable, str(root / 'scripts/build-help.py'), str(root / 'README.md'), '--out', str(output)],
                                    text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            book = json.loads(output.read_text())
            self.assertEqual([video['id'] for video in book['videos']], [video['id'] for video in self.video_manifest()['videos']])
            self.assertEqual(book['topics'][-1]['id'], 'videos')


if __name__ == '__main__':
    unittest.main()
