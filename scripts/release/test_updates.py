import copy
from contextlib import contextmanager, redirect_stdout
import io
import hashlib
import json
import os
from pathlib import Path
import tempfile
import plistlib
import shutil
import subprocess
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import build_info
import prepare_update
import publish_update
import preview

class UpdatesTests(unittest.TestCase):
    def test_website_record_binds_each_edition_to_the_verified_feed(self):
        with tempfile.TemporaryDirectory() as directory:
            feed = Path(directory) / 'production.xml'
            feed.write_bytes(b'synthetic feed fixture; not a signed release')
            for channel, tag, filename in [('production', 'v2.0.0', 'Workbench.zip'),
                                           ('preview', 'v2.0.0-preview.5', 'Workbench.Preview.zip')]:
                receipt = dict(channel=channel, version='2.0.0', build='5', tag=tag,
                               source='a'*40, sha256='b'*64,
                               download_url=f'https://github.com/Ship-Work/workbench/releases/download/{tag}/{filename}',
                               feed_url=f'https://workbench-mac.vercel.app/updates/{channel}.xml',
                               notarization='private-packaging-evidence')
                record = publish_update.website_record(receipt, feed)
                self.assertEqual(record['channel'], channel)
                self.assertEqual(record['download_url'], receipt['download_url'])
                self.assertEqual(record['feed_sha256'], hashlib.sha256(feed.read_bytes()).hexdigest())
                self.assertNotIn('notarization', record)
                feed.write_bytes(feed.read_bytes() + b' changed')
                self.assertNotEqual(record['feed_sha256'], publish_update.website_record(receipt, feed)['feed_sha256'])

    def test_local_packages_cannot_inherit_release_feed(self):
        original = {'SUFeedURL': 'https://old.example', 'SUPublicEDKey': 'old',
                    'SUEnableAutomaticChecks': True, 'SUAutomaticallyUpdate': True,
                    'SUEnableSystemProfiling': False, 'SURequireSignedFeed': True,
                    'SUVerifyUpdateBeforeExtraction': True}
        for channel in ('production', 'preview'):
            with self.subTest(channel=channel):
                value = build_info.stamp(original.copy(), channel, source='a'*40, dirty=True, build='3')
                for key in original:
                    self.assertNotIn(key, value)
                self.assertEqual(value['WorkbenchBuildKind'], 'local')
                self.assertTrue(value['WorkbenchSourceDirty'])

    def test_channels_and_provenance(self):
        stable = build_info.stamp({}, 'production', released=True, source='a'*40, dirty=False, build='3')
        preview_info = build_info.stamp({}, 'preview', released=True, source='a'*40, dirty=False, build='4')
        self.assertNotEqual(stable['SUFeedURL'], preview_info['SUFeedURL'])
        for channel, info in [('production', stable), ('preview', preview_info)]:
            with self.subTest(channel=channel):
                self.assertIs(info['SUEnableAutomaticChecks'], True)
                self.assertIs(info['SUAutomaticallyUpdate'], True)
                self.assertIs(info['SURequireSignedFeed'], True)
                self.assertIs(info['SUVerifyUpdateBeforeExtraction'], True)
                self.assertIs(info['SUEnableSystemProfiling'], False)
        with self.assertRaises(RuntimeError):
            build_info.stamp({}, 'preview', released=True, source='a'*40, dirty=True)
        with self.assertRaises(RuntimeError):
            build_info.stamp({}, 'staging', source='a'*40, dirty=False)

    def test_receipt_cannot_relabel_or_change_archive(self):
        config = json.loads((build_info.ROOT/'scripts/release/updates.json').read_text())
        with tempfile.TemporaryDirectory() as directory:
            archive = Path(directory)/'Workbench.zip'; archive.write_bytes(b'package fixture')
            receipt = dict(channel='preview', source='a'*40, version='2.0.0', build='4', notarization='accepted-id', sha256=hashlib.sha256(archive.read_bytes()).hexdigest())
            info = build_info.stamp({'CFBundleIdentifier':'com.ethdawg.workbench.preview','CFBundleShortVersionString':'2.0.0'}, 'preview', released=True, source='a'*40, dirty=False, build='4')
            prepare_update.validate_receipt(receipt, archive, info, config)
            for key, value in [('CFBundleIdentifier','com.ethdawg.workbench'),('WorkbenchBuildKind','local'),('WorkbenchSourceRevision','b'*40),('WorkbenchSourceDirty',True),('SUPublicEDKey','other'),('CFBundleVersion','5'),('SUFeedURL',config['feed_base']+'/production.xml')]:
                bad = copy.deepcopy(info); bad[key] = value
                with self.subTest(key=key), self.assertRaises(RuntimeError):
                    prepare_update.validate_receipt(receipt, archive, bad, config)
            archive.write_bytes(b'changed')
            with self.assertRaises(RuntimeError): prepare_update.validate_receipt(receipt, archive, info, config)

    def test_existing_install_location_is_preserved_and_duplicates_stop(self):
        config = {'identifier':'com.example.preview','bundle':'Workbench Preview.app'}
        with tempfile.TemporaryDirectory() as directory:
            roots = [Path(directory)/'user',Path(directory)/'system']
            original = roots[1]/'Workbench Preview.app'
            (original/'Contents').mkdir(parents=True)
            (original/'Contents/Info.plist').write_bytes(plistlib.dumps({'CFBundleIdentifier':config['identifier']}))
            self.assertEqual(preview.installation_destination(config, roots), original)
            duplicate = roots[0]/'Workbench Preview Copy.app'
            (duplicate/'Contents').mkdir(parents=True)
            (duplicate/'Contents/Info.plist').write_bytes((original/'Contents/Info.plist').read_bytes())
            with self.assertRaises(RuntimeError): preview.installation_destination(config, roots)

    def test_install_lock_excludes_another_writer(self):
        with tempfile.TemporaryDirectory() as directory, patch.object(Path, 'home', return_value=Path(directory)):
            with preview.install_lock({'channel':'preview'}):
                with self.assertRaises(RuntimeError):
                    with preview.install_lock({'channel':'preview'}): pass
                with preview.install_lock({'channel':'production'}): pass
            with preview.install_lock({'channel':'preview'}): pass

    def test_signed_feed_must_deliver_exact_package(self):
        ns = prepare_update.SPARKLE
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory)/'preview.xml'
            rss = ET.Element('rss'); channel=ET.SubElement(rss,'channel'); item=ET.SubElement(channel,'item')
            ET.SubElement(item,ns+'version').text='4'
            display = ET.SubElement(item,ns+'shortVersionString'); display.text='2.0.0'
            ET.SubElement(item,ns+'minimumSystemVersion').text='14.0'
            enclosure=ET.SubElement(item,'enclosure',{'url':'https://example.test/Workbench.Preview.zip','length':'123',ns+'edSignature':'signature-fixture'})
            ET.ElementTree(rss).write(path)
            receipt={'build':'4','version':'2.0.0'}
            prepare_update.validate_feed(path,receipt,enclosure.get('url'),123)
            with self.assertRaises(RuntimeError): prepare_update.validate_feed(path,receipt,'https://example.test/Workbench.zip',123)
            with self.assertRaises(RuntimeError): prepare_update.validate_feed(path,receipt,enclosure.get('url'),124)
            display.text='3.0.0'; ET.ElementTree(rss).write(path)
            with self.assertRaises(RuntimeError): prepare_update.validate_feed(path,receipt,enclosure.get('url'),123)
            display.text='2.0.0'
            del enclosure.attrib[ns+'edSignature']; ET.ElementTree(rss).write(path)
            with self.assertRaises(RuntimeError): prepare_update.validate_feed(path,receipt,enclosure.get('url'),123)

    def test_tag_cannot_mislabel_packaged_version_or_edition(self):
        receipt={'channel':'preview','version':'2.0.0'}
        prepare_update.validate_tag(receipt,'v2.0.0-preview.5')
        for tag in ['v3.0.0-preview.5','v2.0.0','v2.0.0-preview.5/other']:
            with self.subTest(tag=tag), self.assertRaises(RuntimeError):
                prepare_update.validate_tag(receipt,tag)
        prepare_update.validate_tag({'channel':'production','version':'2.0.0'},'v2.0.0')

    def test_production_rebuild_tag_identifies_exact_packaged_build(self):
        receipt = {'channel': 'production', 'version': '2.0.0', 'build': '20260927101737'}
        prepare_update.validate_tag(receipt, 'v2.0.0+20260927101737')
        for tag in ['v2.0.0+20260925215646', 'v3.0.0+20260927101737',
                    'v2.0.0-preview.1+20260927101737', 'v2.0.0+local',
                    'v2.0.0+', 'v2.0.0+20260927101737/other']:
            with self.subTest(tag=tag), self.assertRaises(RuntimeError):
                prepare_update.validate_tag(receipt, tag)
        with self.assertRaises(RuntimeError):
            prepare_update.validate_tag({**receipt, 'channel': 'preview'}, 'v2.0.0+20260927101737')
        with self.assertRaises(RuntimeError):
            prepare_update.validate_tag({'channel': 'production', 'version': '2.0.0'}, 'v2.0.0+20260927101737')

    def test_preexisting_tag_must_resolve_to_delivered_source(self):
        tag='v2.0.0-preview.5'; source='a'*40
        prefix={'ref':f'refs/tags/{tag}0','object':{'type':'commit','sha':'b'*40}}
        with patch.object(publish_update,'gh',return_value=json.dumps([prefix])):
            publish_update.verify_tag_target(tag,source)
        actual={'ref':f'refs/tags/{tag}','object':{'type':'commit','sha':'b'*40}}
        with patch.object(publish_update,'gh',return_value=json.dumps([actual])):
            with self.assertRaises(RuntimeError): publish_update.verify_tag_target(tag,source)
        actual['object']={'type':'tag','sha':'c'*40}
        with patch.object(publish_update,'gh',side_effect=[json.dumps([actual]),json.dumps({'object':{'type':'commit','sha':source}})]):
            publish_update.verify_tag_target(tag,source)

    def test_publication_rechecks_package_before_any_remote_write(self):
        config=json.loads((build_info.ROOT/'scripts/release/updates.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            directory=Path(temporary); name='Workbench.Preview.zip'; tag='v2.0.0-preview.5'
            archive=directory/name; archive.write_bytes(b'prepared package')
            receipt=dict(archive=name,tag=tag,channel='preview',version='2.0.0',sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                         download_url=f'https://github.com/Ship-Work/workbench/releases/download/{tag}/{name}',feed_url=config['feed_base']+'/preview.xml')
            (directory/'release.json').write_text(json.dumps(receipt))
            (directory/'SHA256SUMS.txt').write_text(f"{receipt['sha256']}  {name}\n")
            with patch.object(prepare_update,'verify_package',side_effect=RuntimeError('receipt source differs from signed app')) as verify, patch.object(publish_update,'gh') as remote:
                with self.assertRaisesRegex(RuntimeError,'receipt source differs'):
                    publish_update.publish(directory,directory/'notes.md')
                verify.assert_called_once()
                remote.assert_not_called()

    def test_transfer_preserves_prepared_urls_but_rejects_other_destinations(self):
        config = json.loads((build_info.ROOT/'scripts/release/updates.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            directory = Path(temporary)
            name, tag = 'Workbench.Preview.zip', 'v2.0.0-preview.5'
            archive = directory/name
            archive.write_bytes(b'synthetic prepared package')
            receipt = dict(archive=name, tag=tag, channel='preview', version='2.0.0',
                           sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                           feed_url=config['feed_base']+'/preview.xml')
            (directory/'SHA256SUMS.txt').write_text(f"{receipt['sha256']}  {name}\n")
            for repo in ('Ship-Work/workbench', 'EthDawg/workbench', 'Other/workbench',
                         'Ship-Work/another-repo', 'Ship-Work/workbench/..'):
                receipt['download_url'] = f'https://github.com/{repo}/releases/download/{tag}/{name}'
                (directory/'release.json').write_text(json.dumps(receipt))
                accepted = repo in ('Ship-Work/workbench', 'EthDawg/workbench')
                with self.subTest(repo=repo), \
                     patch.object(prepare_update, 'verify_package', side_effect=RuntimeError('package verification reached')) as verify, \
                     patch.object(publish_update, 'gh') as remote:
                    expected = 'package verification reached' if accepted else 'URL differs'
                    with self.assertRaisesRegex(RuntimeError, expected):
                        publish_update.publish(directory, directory/'notes.md')
                    self.assertEqual(verify.call_count, int(accepted))
                    remote.assert_not_called()

    def test_stale_prepared_release_cannot_create_or_publish_remote_assets(self):
        config = json.loads((build_info.ROOT/'scripts/release/updates.json').read_text())
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root/'scripts/release').mkdir(parents=True)
            (root/'scripts/release/updates.json').write_text(json.dumps(config))
            destination = root/'site/updates'
            destination.mkdir(parents=True)
            prepared = root/'prepared'
            prepared.mkdir()
            name, tag = 'Workbench.zip', 'v2.0.0'
            archive = prepared/name
            archive.write_bytes(b'synthetic package; signature checks mocked')
            receipt = dict(archive=name, tag=tag, channel='production', version='2.0.0', build='10',
                           sha256=hashlib.sha256(archive.read_bytes()).hexdigest(),
                           download_url=f'https://github.com/Ship-Work/workbench/releases/download/{tag}/{name}',
                           feed_url=config['feed_base']+'/production.xml')
            (prepared/'release.json').write_text(json.dumps(receipt))
            (prepared/'SHA256SUMS.txt').write_text(f"{receipt['sha256']}  {name}\n")
            for published_build in ['10', '20']:
                with self.subTest(published_build=published_build):
                    feed = ET.Element('rss')
                    item = ET.SubElement(ET.SubElement(feed, 'channel'), 'item')
                    ET.SubElement(item, prepare_update.SPARKLE+'version').text = published_build
                    previous = destination/'production.xml'
                    ET.ElementTree(feed).write(previous)
                    original = previous.read_bytes()
                    with patch.object(publish_update, 'ROOT', root), \
                         patch.object(prepare_update, 'verify_package'), \
                         patch.object(prepare_update, 'validate_feed', return_value='fixture-signature'), \
                         patch.object(publish_update.subprocess, 'run'), \
                         patch.object(publish_update, 'gh') as remote:
                        with self.assertRaisesRegex(RuntimeError, 'same or newer feed'):
                            publish_update.publish(prepared, prepared/'notes.md')
                        remote.assert_not_called()
                        self.assertEqual(previous.read_bytes(), original)


# Keep the Git graph and traversal real. Only the canonical network boundary is
# redirected to a disposable local repository; no live release or signer is used.
REAL_RUN = subprocess.run


class ReleaseHistoryFixture:
    def setUp(self):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        self.directory = Path(temporary.name)
        self.remote = self.directory/'remote'
        self.remote.mkdir()
        self.git('init', '-q', '-b', 'main', directory=self.remote)
        self.git('config', 'user.email', 'release-test@example.invalid', directory=self.remote)
        self.git('config', 'user.name', 'Synthetic release test', directory=self.remote)
        self.initial = self.commit('initial main')
        self.git('switch', '-qc', 'feature', directory=self.remote)
        self.feature = self.commit('feature tip')
        self.git('switch', '-q', 'main', directory=self.remote)
        self.previous = self.commit('prior integrated main')
        self.git('merge', '--no-ff', '-qm', 'integrate feature', 'feature', directory=self.remote)
        self.integrated = self.git('rev-parse', 'HEAD', directory=self.remote)
        self.git('switch', '-qc', 'unmerged', self.previous, directory=self.remote)
        self.unmerged = self.commit('unmerged feature')
        self.git('switch', '-q', 'main', directory=self.remote)
        tree = self.git('rev-parse', 'HEAD^{tree}', directory=self.remote)
        self.divergent = self.git('commit-tree', tree, '-m', 'unrelated root', directory=self.remote)
        self.checkout = self.directory/'checkout'
        self.git('clone', '-q', '--no-hardlinks', str(self.remote), str(self.checkout), directory=self.directory)
        # Main advances after the tooling clone. The verification must fetch this
        # exact commit rather than trust checkout HEAD or origin/main.
        self.current = self.commit('newer integrated main')
        self.git('remote', 'set-url', 'origin', 'https://invalid.example/stale')
        self.fetch_head = self.checkout/'.git/FETCH_HEAD'
        self.fetch_head.write_text('Synthetic pre-existing FETCH_HEAD; preserve exactly\n')
        self.fetches = []

    def git(self, *args, directory=None):
        result = REAL_RUN(['git', '-C', str(directory or self.checkout), *args],
                          check=True, capture_output=True, text=True)
        return result.stdout.strip()

    def commit(self, message):
        self.git('commit', '--allow-empty', '-qm', message, directory=self.remote)
        return self.git('rev-parse', 'HEAD', directory=self.remote)

    def git_boundary(self, command, *args, **kwargs):
        if command[0] == 'git' and 'fetch' in command:
            self.fetches.append(command)
            self.assertEqual(command[-2], 'https://github.com/Ship-Work/workbench.git')
            command = [*command[:-2], str(self.remote), command[-1]]
            kwargs.setdefault('stdout', subprocess.PIPE)
            kwargs.setdefault('stderr', subprocess.PIPE)
        return REAL_RUN(command, *args, **kwargs)

    @contextmanager
    def source_boundary(self, response=None):
        response = response if response is not None else json.dumps({'commit': {'sha': self.current}})
        with patch.object(publish_update, 'ROOT', self.checkout), \
             patch.object(publish_update, 'gh', return_value=response), \
             patch.object(publish_update.subprocess, 'run', side_effect=self.git_boundary):
            yield

    def checkout_state(self):
        return (self.git('rev-parse', 'HEAD'), self.git('symbolic-ref', 'HEAD'),
                self.git('for-each-ref', '--format=%(refname) %(objectname)'),
                self.fetch_head.read_bytes())


class IntegratedSourceTests(ReleaseHistoryFixture, unittest.TestCase):
    def test_current_main_needs_no_local_history_or_fetch(self):
        with self.source_boundary():
            publish_update.verify_integrated_source(self.current)
        self.assertEqual(self.fetches, [])

    def test_real_fetch_accepts_prior_main_without_moving_checkout_refs_or_fetch_head(self):
        before = self.checkout_state()
        # Prove the latest main object is absent before this real local fetch.
        missing = REAL_RUN(['git', '-C', str(self.checkout), 'cat-file', '-e', self.current],
                           capture_output=True)
        self.assertNotEqual(missing.returncode, 0)
        with self.source_boundary():
            for source in (self.initial, self.previous, self.integrated):
                publish_update.verify_integrated_source(source)
        self.assertEqual(self.checkout_state(), before)
        self.assertEqual(self.git('cat-file', '-t', self.current), 'commit')
        for command in self.fetches:
            self.assertEqual(command[-1], self.current)
            for option in ('--no-replace-objects', '--no-tags', '--no-write-fetch-head', '--no-recurse-submodules'):
                self.assertIn(option, command)

    def test_merged_feature_tip_unmerged_and_divergent_sources_are_not_main_states(self):
        # This tip passes a broad ancestry check, but was never itself main.
        self.git('merge-base', '--is-ancestor', self.feature, self.integrated)
        with self.source_boundary():
            for source in (self.feature, self.unmerged, self.divergent):
                with self.subTest(source=source), self.assertRaisesRegex(RuntimeError, 'first-parent'):
                    publish_update.verify_integrated_source(source)

    def test_local_replacement_cannot_promote_a_feature_tip(self):
        self.git('fetch', '--no-tags', str(self.remote), self.current)
        self.git('replace', '--graft', self.current, self.feature)
        self.assertIn(self.feature, self.git('rev-list', '--first-parent', self.current).splitlines())
        with self.source_boundary(), self.assertRaisesRegex(RuntimeError, 'first-parent'):
            publish_update.verify_integrated_source(self.feature)

    def test_default_graft_file_cannot_promote_feature_or_hide_integrated_source(self):
        self.git('fetch', '--no-tags', str(self.remote), self.current)
        (self.checkout/'.git/info/grafts').write_text(f'{self.current} {self.feature}\n')
        # Make the default graft path active even if the test runner inherited one.
        with patch.dict(os.environ):
            os.environ.pop('GIT_GRAFT_FILE', None)
            self.assertIn(self.feature, self.git('--no-replace-objects', 'rev-list',
                                                '--first-parent', self.current).splitlines())
            with self.source_boundary():
                publish_update.verify_integrated_source(self.previous)
                with self.assertRaisesRegex(RuntimeError, 'first-parent'):
                    publish_update.verify_integrated_source(self.feature)

    def test_inherited_graft_file_cannot_promote_feature_or_hide_integrated_source(self):
        self.git('fetch', '--no-tags', str(self.remote), self.current)
        grafts = self.directory/'inherited-synthetic-grafts'
        grafts.write_text(f'{self.current} {self.feature}\n')
        with patch.dict(os.environ, {'GIT_GRAFT_FILE': str(grafts)}):
            self.assertIn(self.feature, self.git('--no-replace-objects', 'rev-list',
                                                '--first-parent', self.current).splitlines())
            with self.source_boundary():
                publish_update.verify_integrated_source(self.previous)
                with self.assertRaisesRegex(RuntimeError, 'first-parent'):
                    publish_update.verify_integrated_source(self.feature)

    def test_invalid_source_and_main_hashes_fail_closed(self):
        for source in (None, '', 'main', '0'*40, 'a'*39, '--all'):
            with self.subTest(source=source), self.source_boundary(), self.assertRaisesRegex(RuntimeError, 'exact commit'):
                publish_update.verify_integrated_source(source)
        for response in ('not json', '{}', 'null', '{"commit":{}}', '{"commit":{"sha":null}}',
                         '{"commit":{"sha":"main"}}', json.dumps({'commit': {'sha': '0'*40}})):
            with self.subTest(response=response), self.source_boundary(response), self.assertRaises(RuntimeError):
                publish_update.verify_integrated_source(self.previous)
        self.assertEqual(self.fetches, [])

    def test_remote_and_fetch_failures_cannot_use_cached_history(self):
        with self.source_boundary(), patch.object(publish_update, 'gh', side_effect=subprocess.CalledProcessError(1, ['gh'])):
            with self.assertRaisesRegex(RuntimeError, 'Cannot verify'):
                publish_update.verify_integrated_source(self.previous)
        for error in (subprocess.CalledProcessError(1, ['git']), subprocess.TimeoutExpired(['git'], 120)):
            def failed_fetch(command, *args, **kwargs):
                if 'fetch' in command:
                    raise error
                return self.git_boundary(command, *args, **kwargs)
            with self.subTest(error=type(error).__name__), self.source_boundary(), \
                 patch.object(publish_update.subprocess, 'run', side_effect=failed_fetch):
                with self.assertRaisesRegex(RuntimeError, 'Cannot verify integrated'):
                    publish_update.verify_integrated_source(self.previous)
        # A syntactically valid but unavailable remote hash also fails at real Git.
        with self.source_boundary(json.dumps({'commit': {'sha': 'f'*40}})):
            with self.assertRaisesRegex(RuntimeError, 'Cannot verify integrated'):
                publish_update.verify_integrated_source(self.previous)

    def test_missing_commit_object_refuses_prior_source(self):
        def incomplete_history(command, *args, **kwargs):
            if 'rev-list' in command:
                # Lose a real parent after fetching; rev-list must report failure,
                # not let an earlier or partial list establish integration.
                object_path = self.checkout/'.git/objects'/self.previous[:2]/self.previous[2:]
                self.assertTrue(object_path.is_file())
                object_path.unlink()
                kwargs.setdefault('stderr', subprocess.PIPE)
            return self.git_boundary(command, *args, **kwargs)
        with self.source_boundary(), patch.object(publish_update.subprocess, 'run', side_effect=incomplete_history):
            with self.assertRaisesRegex(RuntimeError, 'Cannot verify integrated'):
                publish_update.verify_integrated_source(self.initial)

    def test_incomplete_shallow_history_is_refused(self):
        (self.checkout/'.git/shallow').write_text(self.integrated+'\n')
        with self.source_boundary(), self.assertRaisesRegex(RuntimeError, 'complete main history'):
            publish_update.verify_integrated_source(self.previous)



def acceptance_fixture(root, directory, receipt, baseline):
    policy = json.loads((build_info.ROOT/'scripts/release/config.json').read_text())['acceptance']
    (root/'scripts/release/config.json').write_text(json.dumps({'acceptance': policy}))
    evidence_name = 'acceptance-evidence/native.md'
    data = b'Synthetic test-only native attestation, not an actual acceptance claim.\n'
    (directory/'acceptance-evidence').mkdir(exist_ok=True)
    (directory/evidence_name).write_bytes(data)
    artifact = {key: receipt[key] for key in ('source', 'channel', 'version', 'build', 'sha256')}
    artifact['bundle'] = 'com.ethdawg.workbench' + ('.preview' if receipt['channel'] == 'preview' else '')
    value = dict(schemaVersion=1, stage='candidate', publicationReady=True, resetComplete=False,
        policySHA256=prepare_update.policy_digest(policy), artifact=artifact,
        observer='Synthetic observer', reviewer='Synthetic independent reviewer', observedAt='2026-10-07T01:00:00Z',
        environment={'macOS':'synthetic macOS 26.5.1', 'hardware':'synthetic Apple silicon'},
        candidateSmoke={'method':'native', 'status':'pass', 'opening':'pass', 'permissions':'pass', 'savedWork':'pass', 'evidence':[evidence_name]},
        evidence=[{'path':evidence_name, 'sha256':hashlib.sha256(data).hexdigest(), 'sanitized':True}],
        journeys=[dict(id=row['id'], variant=row['variant'], status='not-tested' if row['phase']=='delivery' else 'pass',
                       method='native', evidence=[evidence_name]) for row in policy['journeys']],
        compatibility={'previousRelease':{k:baseline[k] for k in ('source','version','build','sha256')},
            'reviewer':'Synthetic upgrade reviewer', 'assessment':'Synthetic fixture; no real upgrade claimed.',
            'upgradeEvidence':[evidence_name], 'formats':[{'name':name,
                'upgrade':'Original format-1 manifest and tracks checked in this fixture.',
                'downgrade':'unsupported', 'recovery':'Retain original folders and use a compatible newer binary.'} for name in policy['storageFormats']]})
    (directory/prepare_update.ACCEPTANCE_NAME).write_text(json.dumps(value))
    info = {'CFBundleIdentifier':artifact['bundle'], 'CFBundleShortVersionString':receipt['version'],
            'CFBundleVersion':receipt['build'], 'WorkbenchSourceRevision':receipt['source'],
            'WorkbenchBuildKind':'release', 'WorkbenchSourceDirty':False}
    return value, info


class PinnedPublicationTests(ReleaseHistoryFixture, unittest.TestCase):
    def setUp(self):
        super().setUp()
        config = json.loads((build_info.ROOT/'scripts/release/updates.json').read_text())
        (self.checkout/'scripts/release').mkdir(parents=True)
        (self.checkout/'scripts/release/updates.json').write_text(json.dumps(config))
        self.prepared = self.directory/'immutable-prepared'
        self.prepared.mkdir()
        self.archive = self.prepared/'Workbench.zip'
        self.archive.write_bytes(b'synthetic immutable archive; signing boundary mocked')
        self.receipt = dict(archive=self.archive.name, tag='v2.0.0', channel='production',
                            version='2.0.0', build='10', source=self.previous,
                            sha256=hashlib.sha256(self.archive.read_bytes()).hexdigest(),
                            download_url='https://github.com/Ship-Work/workbench/releases/download/v2.0.0/Workbench.zip',
                            feed_url=config['feed_base']+'/production.xml')
        self.save_receipt()
        (self.prepared/'SHA256SUMS.txt').write_text(f"{self.receipt['sha256']}  {self.archive.name}\n")
        self.prepared_feed = self.prepared/'production.xml'
        self.write_feed(self.prepared_feed, '10')
        self.destination = self.checkout/'site/updates'
        self.destination.mkdir(parents=True)
        self.previous_feed = self.destination/'production.xml'
        self.write_feed(self.previous_feed, '9')
        self.previous_record = self.destination/'production.json'
        baseline=dict(source=self.initial,version='1.9.0',build='9',sha256='b'*64)
        self.previous_record.write_text(json.dumps(baseline))
        self.acceptance,self.verified_info=acceptance_fixture(self.checkout,self.prepared,self.receipt,baseline)
        self.release_listing = [[]]
        self.tag_refs = []
        self.remote_calls = []

    def save_receipt(self):
        (self.prepared/'release.json').write_text(json.dumps(self.receipt))

    def write_feed(self, path, build):
        rss = ET.Element('rss')
        item = ET.SubElement(ET.SubElement(rss, 'channel'), 'item')
        for field, value in [('version', build), ('shortVersionString', '2.0.0'), ('minimumSystemVersion', '14.0')]:
            ET.SubElement(item, prepare_update.SPARKLE+field).text = value
        ET.SubElement(item, 'enclosure', {'url': self.receipt['download_url'],
            'length': str(self.archive.stat().st_size), prepare_update.SPARKLE+'edSignature': 'fixture-signature'})
        ET.ElementTree(rss).write(path)

    def github(self, *args):
        self.remote_calls.append(args)
        if args == ('api', 'repos/Ship-Work/workbench/releases', '--paginate', '--slurp'):
            return json.dumps(self.release_listing)
        if args == ('api', 'repos/Ship-Work/workbench/branches/main'):
            return json.dumps({'commit': {'sha': self.current}})
        if args == ('api', 'repos/Ship-Work/workbench/git/matching-refs/tags/v2.0.0'):
            return json.dumps(self.tag_refs)
        if args[:2] == ('release', 'download'):
            asset=args[args.index('--pattern')+1]
            source=self.prepared/asset if asset in (self.archive.name,prepare_update.ACCEPTANCE_NAME) else self.prepared/'acceptance-evidence'/asset
            shutil.copy2(source, Path(args[args.index('--dir')+1])/asset)
        elif args[:2] not in [('release', 'create'), ('release', 'upload'), ('release', 'edit')]:
            raise AssertionError(f'Unexpected GitHub call: {args}')
        return ''

    def publication_command(self, command, *args, **kwargs):
        if str(command[0]).endswith('/sign_update'):
            return subprocess.CompletedProcess(command, 0)
        return self.git_boundary(command, *args, **kwargs)

    @contextmanager
    def publication_boundary(self):
        with patch.object(publish_update, 'ROOT', self.checkout), \
             patch.object(prepare_update, 'verify_package', return_value=self.verified_info), \
             patch.object(publish_update.subprocess, 'run', side_effect=self.publication_command), \
             patch.object(publish_update, 'gh', side_effect=self.github), \
             patch.object(publish_update.urllib.request, 'urlopen', side_effect=lambda url,**kw: io.BytesIO(
                 (self.prepared/(url.rsplit('/',1)[1]) if url.rsplit('/',1)[1] in (self.archive.name,prepare_update.ACCEPTANCE_NAME)
                  else self.prepared/'acceptance-evidence'/url.rsplit('/',1)[1]).read_bytes())), \
             redirect_stdout(io.StringIO()):
            yield

    def publication_state(self):
        return self.previous_feed.read_bytes(), self.previous_record.read_bytes()

    def assert_no_release_writes(self, before):
        self.assertFalse(any(call[0] == 'release' for call in self.remote_calls))
        self.assertEqual(self.publication_state(), before)

    def test_prior_integrated_package_keeps_exact_target_receipt_and_bytes(self):
        original = {str(path.relative_to(self.prepared)): path.read_bytes() for path in self.prepared.rglob('*') if path.is_file()}
        checkout_before = self.checkout_state()
        with self.publication_boundary():
            publish_update.publish(self.prepared, self.prepared/'notes.md')
        create = next(call for call in self.remote_calls if call[:2] == ('release', 'create'))
        self.assertEqual(create[create.index('--target')+1], self.previous)
        self.assertEqual(json.loads(self.previous_record.read_text())['source'], self.previous)
        self.assertEqual(self.previous_feed.read_bytes(), original['production.xml'])
        self.assertEqual({str(path.relative_to(self.prepared)): path.read_bytes() for path in self.prepared.rglob('*') if path.is_file()}, original)
        self.assertEqual(self.checkout_state(), checkout_before)

    def test_unintegrated_source_stops_before_release_writes_or_feed_changes(self):
        before = self.publication_state()
        for source in (self.feature, self.unmerged, self.divergent):
            with self.subTest(source=source):
                self.remote_calls.clear()
                self.receipt['source'] = source
                self.acceptance['artifact']['source'] = source
                self.verified_info['WorkbenchSourceRevision'] = source
                self.save_receipt()
                self.save_acceptance()
                with self.publication_boundary(), self.assertRaisesRegex(RuntimeError, 'first-parent'):
                    publish_update.publish(self.prepared, self.prepared/'notes.md')
                self.assert_no_release_writes(before)

    def test_failed_source_fetch_stops_before_release_writes_or_feed_changes(self):
        before = self.publication_state()
        def failed_fetch(command, *args, **kwargs):
            if 'fetch' in command:
                raise subprocess.TimeoutExpired(command, 120)
            return self.publication_command(command, *args, **kwargs)
        with self.publication_boundary(), patch.object(publish_update.subprocess, 'run', side_effect=failed_fetch):
            with self.assertRaisesRegex(RuntimeError, 'Cannot verify integrated'):
                publish_update.publish(self.prepared, self.prepared/'notes.md')
        self.assert_no_release_writes(before)

    def test_pin_does_not_bypass_existing_tag_or_duplicate_release(self):
        before = self.publication_state()
        self.tag_refs = [{'ref': 'refs/tags/v2.0.0', 'object': {'type': 'commit', 'sha': self.current}}]
        with self.publication_boundary(), self.assertRaisesRegex(RuntimeError, 'tag points to different source'):
            publish_update.publish(self.prepared, self.prepared/'notes.md')
        self.assert_no_release_writes(before)
        self.tag_refs = []
        self.release_listing = [[{'tag_name': 'v2.0.0'}]]
        self.remote_calls.clear()
        with self.publication_boundary(), self.assertRaisesRegex(RuntimeError, 'already exists'):
            publish_update.publish(self.prepared, self.prepared/'notes.md')
        self.assert_no_release_writes(before)

    def test_pin_does_not_bypass_equal_or_newer_published_build(self):
        for build in ('10', '11'):
            with self.subTest(build=build):
                self.write_feed(self.previous_feed, build)
                before = self.publication_state()
                with self.publication_boundary(), self.assertRaisesRegex(RuntimeError, 'same or newer feed'):
                    publish_update.publish(self.prepared, self.prepared/'notes.md')
                self.assertEqual(self.remote_calls, [])
                self.assert_no_release_writes(before)

    def save_acceptance(self):
        (self.prepared/prepare_update.ACCEPTANCE_NAME).write_text(json.dumps(self.acceptance))

    def assert_acceptance_rejected(self, pattern='Release acceptance|Invalid acceptance'):
        before = self.publication_state()
        self.remote_calls.clear()
        output = self.directory/'rejected-output'
        with patch.object(prepare_update, 'ROOT', self.checkout), \
             patch.object(prepare_update, 'verify_package', return_value=self.verified_info):
            with self.assertRaisesRegex(RuntimeError, pattern):
                prepare_update.prepare(self.prepared, 'v2.0.0', self.prepared/'notes.md', output)
        self.assertFalse(output.exists())
        with self.publication_boundary(), self.assertRaisesRegex(RuntimeError, pattern):
            publish_update.publish(self.prepared, self.prepared/'notes.md')
        self.assert_no_release_writes(before)

    def test_acceptance_missing_unknown_partial_or_automated_cannot_publish(self):
        original = copy.deepcopy(self.acceptance)
        cases = [
            ('schemaVersion', 2), ('stage', 'source'), ('publicationReady', False),
            ('resetComplete', True), ('policySHA256', '0'*64), ('reviewer', ''),
            ('environment', {}), ('journeys', original['journeys'][1:]),
            ('journeys', original['journeys']+[original['journeys'][0]]),
            ('evidence', []), ('compatibility', {'compatible':True}),
            ('compatibility',dict(original['compatibility'],formats=original['compatibility']['formats'][1:])),
            ('candidateSmoke', {'method':'automated', 'status':'pass', 'evidence':['acceptance-evidence/native.md']})]
        for key, value in cases:
            with self.subTest(key=key, value=str(value)[:40]):
                self.acceptance = copy.deepcopy(original)
                self.acceptance[key] = value
                self.save_acceptance()
                self.assert_acceptance_rejected()
        for key, value in [('id','unknown'), ('variant','unreviewed-route'), ('status','not-tested'), ('status','fail'), ('method','automated')]:
            with self.subTest(journey_field=key, value=value):
                self.acceptance = copy.deepcopy(original)
                self.acceptance['journeys'][0][key] = value
                self.save_acceptance()
                self.assert_acceptance_rejected()
        for key, value in [('source','a'*40), ('channel','preview'), ('build','99'), ('version','9.9.9'), ('bundle','wrong.app'), ('sha256','f'*64)]:
            with self.subTest(identity=key):
                self.acceptance = copy.deepcopy(original)
                self.acceptance['artifact'][key] = value
                self.save_acceptance()
                self.assert_acceptance_rejected()

    def test_duplicate_keys_and_missing_receipt_reject_before_mutation(self):
        path = self.prepared/prepare_update.ACCEPTANCE_NAME
        path.write_text('{"schemaVersion":1,"schemaVersion":1}')
        self.assert_acceptance_rejected()
        path.unlink()
        self.assert_acceptance_rejected()

    def test_all_promoted_routes_are_required_and_delivery_is_later(self):
        original = copy.deepcopy(self.acceptance)
        for index, row in enumerate(original['journeys']):
            if row['id'] not in ('H2', 'P1', 'L1', 'L2', 'L3', 'L4'):
                continue
            with self.subTest(id=row['id'], variant=row['variant']):
                self.acceptance = copy.deepcopy(original)
                del self.acceptance['journeys'][index]
                self.save_acceptance()
                self.assert_acceptance_rejected()
        self.acceptance = copy.deepcopy(original)
        next(r for r in self.acceptance['journeys'] if r['id']=='I1')['status']='pass'
        self.save_acceptance()
        self.assert_acceptance_rejected()

    def test_missing_changed_escaping_or_symlink_evidence_rejects(self):
        path = self.prepared/'acceptance-evidence/native.md'
        data = path.read_bytes()
        for changed in (b'changed after preparation', None):
            if changed is None:
                path.unlink()
            else:
                path.write_bytes(changed)
            self.assert_acceptance_rejected()
        outside = self.directory/'private-neighbor.md'
        outside.write_bytes(data)
        path.symlink_to(outside)
        self.assert_acceptance_rejected()
        path.unlink()
        path.write_bytes(data)
        original = copy.deepcopy(self.acceptance)
        for name in ('../private-neighbor.md', str(outside), 'acceptance-evidence/../../private-neighbor.md',
                     'acceptance-evidence/./native.md','acceptance-evidence/journey-acceptance.json'):
            self.acceptance=copy.deepcopy(original)
            self.acceptance['evidence'][0]['path']=name
            self.save_acceptance()
            self.assert_acceptance_rejected()
        self.acceptance=original
        self.save_acceptance()
        path.parent.rename(self.prepared/'moved-evidence')
        path.parent.symlink_to(self.prepared/'moved-evidence', target_is_directory=True)
        self.assert_acceptance_rejected()

    def test_unreviewed_reuse_and_wrong_upgrade_baseline_reject(self):
        original = copy.deepcopy(self.acceptance)
        self.acceptance['journeys'][0]['reuse'] = {'artifact':original['artifact']}
        self.save_acceptance()
        self.assert_acceptance_rejected()
        self.acceptance = copy.deepcopy(original)
        self.acceptance['compatibility']['previousRelease']['build']='unknown'
        self.save_acceptance()
        self.assert_acceptance_rejected()
        self.acceptance = copy.deepcopy(original)
        self.acceptance['compatibility']['formats'][0].pop('recovery')
        self.save_acceptance()
        self.assert_acceptance_rejected()

    def test_reviewed_reuse_requires_fresh_candidate_smoke(self):
        self.acceptance['journeys'][0]['reuse'] = dict(artifact=dict(self.acceptance['artifact'],source=self.initial),
            environment=self.acceptance['environment'], sourceImpact='Reviewed source delta leaves this path unchanged.',
            configurationImpact='Same route and configuration.', environmentImpact='Same approved OS and receiver.',
            reviewer='Synthetic independent reviewer', evidence=['acceptance-evidence/native.md'])
        self.save_acceptance()
        files=prepare_update.validate_acceptance(self.prepared,self.receipt,self.verified_info,self.checkout)
        self.assertEqual(set(files), {'journey-acceptance.json','acceptance-evidence/native.md'})
        self.acceptance['candidateSmoke']['status']='not-tested'
        self.save_acceptance()
        self.assert_acceptance_rejected()

    def test_preparation_normalizes_filename_without_changing_acceptance_bytes(self):
        old=self.archive
        self.archive=self.prepared/'Workbench Candidate.zip'
        old.rename(self.archive)
        self.receipt['archive']=self.archive.name
        self.save_receipt()
        notes=self.prepared/'notes.html'
        notes.write_text('<p>Synthetic fixture.</p>')
        output=self.directory/'prepared-output'
        expected={name:data for name,data in prepare_update.validate_acceptance(self.prepared,self.receipt,self.verified_info,self.checkout).items()}
        def commands(command, *args, **kwargs):
            if str(command[0]).endswith('/generate_appcast'):
                rss=ET.Element('rss'); item=ET.SubElement(ET.SubElement(rss,'channel'),'item')
                for key,val in [('version','10'),('shortVersionString','2.0.0'),('minimumSystemVersion','14.0')]:
                    ET.SubElement(item,prepare_update.SPARKLE+key).text=val
                ET.SubElement(item,'enclosure',{'url':'https://github.com/Ship-Work/workbench/releases/download/v2.0.0/Workbench.Candidate.zip',
                    'length':str(self.archive.stat().st_size),prepare_update.SPARKLE+'edSignature':'fixture-signature'})
                ET.ElementTree(rss).write(command[command.index('-o')+1])
            return subprocess.CompletedProcess(command,0)
        # A neighboring private file must never be copied into public evidence.
        (self.prepared/'acceptance-evidence/private.txt').write_text('synthetic private neighbor')
        with patch.object(prepare_update,'ROOT',self.checkout), patch.object(prepare_update,'verify_package',return_value=self.verified_info), \
             patch.object(prepare_update.subprocess,'run',side_effect=commands), redirect_stdout(io.StringIO()):
            prepare_update.prepare(self.prepared,'v2.0.0',notes,output)
        self.assertEqual((output/'Workbench.Candidate.zip').read_bytes(),self.archive.read_bytes())
        self.assertEqual(json.loads((output/'release.json').read_text())['sha256'],self.receipt['sha256'])
        self.assertEqual({name:(output/name).read_bytes() for name in expected},expected)
        self.assertFalse((output/'acceptance-evidence/private.txt').exists())

    def test_uploaded_evidence_mismatch_keeps_draft_and_feed(self):
        before=self.publication_state()
        original=self.github
        def corrupt(*args):
            result=original(*args)
            if args[:2]==('release','download') and args[args.index('--pattern')+1]=='native.md':
                (Path(args[args.index('--dir')+1])/'native.md').write_text('wrong remote bytes')
            return result
        with self.publication_boundary(),patch.object(publish_update,'gh',side_effect=corrupt),self.assertRaisesRegex(RuntimeError,'Uploaded acceptance'):
            publish_update.publish(self.prepared,self.prepared/'notes.md')
        self.assertFalse(any(call[:2]==('release','edit') for call in self.remote_calls))
        self.assertEqual(self.publication_state(),before)

    def test_public_evidence_mismatch_does_not_promote_feed(self):
        before=self.publication_state()
        with self.publication_boundary(),patch.object(publish_update.urllib.request,'urlopen',side_effect=lambda url,**kw:
                io.BytesIO(self.archive.read_bytes() if url==self.receipt['download_url'] else b'wrong public evidence')), \
                self.assertRaisesRegex(RuntimeError,'Public acceptance'):
            publish_update.publish(self.prepared,self.prepared/'notes.md')
        self.assertEqual(self.publication_state(),before)



if __name__ == '__main__': unittest.main()
