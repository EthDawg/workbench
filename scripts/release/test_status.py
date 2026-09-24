"""Read-only inventory regression using synthetic Applications and Downloads."""
from contextlib import redirect_stdout
import io
from pathlib import Path
import plistlib
from types import SimpleNamespace
import tempfile
import unittest
from unittest.mock import patch
import preview
import status


class StatusTests(unittest.TestCase):
    def test_downloaded_duplicate_is_visible_without_becoming_an_install_target(self):
        with tempfile.TemporaryDirectory() as directory:
            home=Path(directory)
            stable=home/'Applications/Workbench.app'
            installed=home/'Applications/Workbench Preview.app'
            downloaded=home/'Downloads/Workbench Preview.app'
            identity='com.ethdawg.workbench.preview'
            original={}
            for app,bundle,build in [(stable,'com.ethdawg.workbench','30'),
                                     (installed,identity,'20'),(downloaded,identity,'10')]:
                path=app/'Contents/Info.plist'
                path.parent.mkdir(parents=True)
                original[path]=plistlib.dumps(dict(CFBundleIdentifier=bundle,
                    CFBundleShortVersionString='2.0.0',CFBundleVersion=build))
                path.write_bytes(original[path])
            saved=home/'Library/Application Support/Workbench Preview/saved.txt'
            saved.parent.mkdir(parents=True)
            saved.write_text('original saved work')
            actual_glob=Path.glob
            def isolated_glob(root,pattern):
                return iter(()) if root == Path('/Applications') else actual_glob(root,pattern)
            with patch.object(Path,'home',return_value=home), \
                 patch.object(Path,'glob',autospec=True,side_effect=isolated_glob), \
                 patch.object(status.subprocess,'run',return_value=SimpleNamespace(stderr='TeamIdentifier=TESTTEAM\n')) as command:
                rows=status.inventory()
                by_path={row['path']:row for row in rows}
                self.assertEqual(set(by_path),{str(stable),str(installed),str(downloaded)})
                self.assertEqual(by_path[str(downloaded)]['location'],'downloaded')
                self.assertEqual(by_path[str(installed)]['location'],'installed')
                self.assertTrue(by_path[str(downloaded)]['duplicate_identity'])
                self.assertTrue(by_path[str(installed)]['duplicate_identity'])
                self.assertFalse(by_path[str(stable)]['duplicate_identity'])
                previous_fields={'path','identity','version','build','source','kind','edition','legacy','team','feed'}
                self.assertTrue(all(previous_fields <= row.keys() for row in rows))
                report=io.StringIO()
                with redirect_stdout(report): status.print_inventory(rows)
                self.assertIn('Downloaded (not installed)',report.getvalue())
                self.assertIn(f'Warning: 2 copies share identity {identity}',report.getvalue())
                # Explicit roots retain their scope; Downloads is discovery, not installation.
                scoped=status.inventory(roots=[home/'Applications'])
                self.assertEqual(len(scoped),2)
                self.assertFalse(any(row['duplicate_identity'] for row in scoped))
                self.assertEqual(preview.installation_destination(
                    {'identifier':identity,'bundle':'Workbench Preview.app'},[home/'Applications']),installed)
                self.assertTrue(all(call.args[0][:3] == ['codesign','-dv','--verbose=2'] for call in command.call_args_list))
            for path,data in original.items(): self.assertEqual(path.read_bytes(),data)
            self.assertEqual(saved.read_text(),'original saved work')


if __name__=='__main__': unittest.main()
