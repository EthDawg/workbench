import copy
import hashlib
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import xml.etree.ElementTree as ET
import build_info
import prepare_update
import preview

class UpdatesTests(unittest.TestCase):
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
            ET.SubElement(item,ns+'minimumSystemVersion').text='14.0'
            enclosure=ET.SubElement(item,'enclosure',{'url':'https://example.test/Workbench.Preview.zip','length':'123',ns+'edSignature':'signature-fixture'})
            ET.ElementTree(rss).write(path)
            prepare_update.validate_feed(path,{'build':'4'},enclosure.get('url'),123)
            with self.assertRaises(RuntimeError): prepare_update.validate_feed(path,{'build':'4'},'https://example.test/Workbench.zip',123)
            with self.assertRaises(RuntimeError): prepare_update.validate_feed(path,{'build':'4'},enclosure.get('url'),124)
            del enclosure.attrib[ns+'edSignature']; ET.ElementTree(rss).write(path)
            with self.assertRaises(RuntimeError): prepare_update.validate_feed(path,{'build':'4'},enclosure.get('url'),123)

if __name__ == '__main__': unittest.main()
