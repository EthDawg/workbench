import copy
import hashlib
import json
from pathlib import Path
import tempfile
import plistlib
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
                               download_url=f'https://github.com/EthDawg/workbench/releases/download/{tag}/{filename}',
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
        original = {'SUFeedURL': 'https://old.example', 'SUPublicEDKey': 'old', 'SUEnableAutomaticChecks': True}
        value = build_info.stamp(original, 'preview', source='a'*40, dirty=True, build='3')
        self.assertNotIn('SUFeedURL', value)
        self.assertNotIn('SUPublicEDKey', value)
        self.assertEqual(value['WorkbenchBuildKind'], 'local')
        self.assertTrue(value['WorkbenchSourceDirty'])

    def test_channels_and_provenance(self):
        stable = build_info.stamp({}, 'production', released=True, source='a'*40, dirty=False, build='3')
        preview_info = build_info.stamp({}, 'preview', released=True, source='a'*40, dirty=False, build='4')
        self.assertNotEqual(stable['SUFeedURL'], preview_info['SUFeedURL'])
        self.assertTrue(stable['SURequireSignedFeed'])
        self.assertFalse(stable['SUEnableSystemProfiling'])
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
                         download_url=f'https://github.com/EthDawg/workbench/releases/download/{tag}/{name}',feed_url=config['feed_base']+'/preview.xml')
            (directory/'release.json').write_text(json.dumps(receipt))
            (directory/'SHA256SUMS.txt').write_text(f"{receipt['sha256']}  {name}\n")
            with patch.object(prepare_update,'verify_package',side_effect=RuntimeError('receipt source differs from signed app')) as verify, patch.object(publish_update,'gh') as remote:
                with self.assertRaisesRegex(RuntimeError,'receipt source differs'):
                    publish_update.publish(directory,directory/'notes.md')
                verify.assert_called_once()
                remote.assert_not_called()

if __name__ == '__main__': unittest.main()
