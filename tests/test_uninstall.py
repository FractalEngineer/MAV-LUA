"""The uninstaller ships at the package root and must clean a card it is run from.

This runs the script exactly as a pilot would: the package is extracted, the script copied
to a simulated card root beside SCRIPTS, and then invoked with no path argument.
"""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import zipfile

ROOT = Path(__file__).resolve().parents[1]


def find_package():
    """Newest built source package, or None when nothing has been packaged yet.

    Folders are filtered by whether the expected ZIP is actually present: the newest
    SHA256SUMS.txt by timestamp is not necessarily a package folder.
    """
    candidates = []
    for sums in (ROOT / 'dist').glob('*/SHA256SUMS.txt'):
        package = sums.parent / f'MAV-LUA-{sums.parent.name}_source.zip'
        if package.exists():
            candidates.append((sums.stat().st_mtime, package))
    return max(candidates)[1] if candidates else None


@unittest.skipUnless(os.name == 'nt', 'the shipped uninstaller is a Windows batch script')
class UninstallScript(unittest.TestCase):
    def test_shipped_script_cleans_a_card(self):
        package = find_package()
        if package is None:
            self.skipTest('build packages before testing')

        with tempfile.TemporaryDirectory(dir=ROOT / '.build') as temp:
            temp = Path(temp)
            with zipfile.ZipFile(package) as archive:
                self.assertIn('uninstall-mav-lua.bat', archive.namelist())
                archive.extractall(temp)

            # Lay out a card the way the package expects: the script at the root beside
            # SCRIPTS and WIDGETS, plus unrelated files that must survive.
            card = temp / 'card'
            shutil.copytree(temp / 'SCRIPTS', card / 'SCRIPTS')
            shutil.copytree(temp / 'WIDGETS', card / 'WIDGETS')
            shutil.copy2(temp / 'uninstall-mav-lua.bat', card / 'uninstall-mav-lua.bat')
            for folder, name in (('MODELS', 'model.bin'), ('LOGS', 'a.txt'), ('RADIO', 'radio.yml')):
                (card / folder).mkdir(parents=True)
                (card / folder / name).write_text('keep', encoding='ascii')
            # Stale caches and a built index, which are the real reasons an update appears
            # to do nothing. The index is written by the Tools builder at run time, so its
            # DB folder is created here rather than shipped.
            (card / 'SCRIPTS/TELEMETRY/MAV.luac').write_text('old', encoding='ascii')
            (card / 'SCRIPTS/TOOLS/MAV.luac').write_text('old', encoding='ascii')
            (card / 'SCRIPTS/TOOLS/MAVLUA_BUILD_INDEX.luac').write_text('old', encoding='ascii')
            (card / 'WIDGETS/MAV/main.luac').write_text('old', encoding='ascii')
            (card / 'SCRIPTS/MAV/i0407c.pdb').write_text('idx', encoding='ascii')
            self.assertTrue((card / 'SCRIPTS/MAV/params.lua').exists(), 'fixture has modules')

            # /y runs unattended, which is how a scripted check must invoke it.
            result = subprocess.run(['cmd', '/c', 'uninstall-mav-lua.bat /y'], cwd=card,
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

            for folder, name in (('MODELS', 'model.bin'), ('LOGS', 'a.txt'), ('RADIO', 'radio.yml')):
                self.assertTrue((card / folder / name).exists(),
                                f'unrelated {folder}/{name} must survive')

            self.assertFalse((card / 'SCRIPTS/MAV').exists(), 'SCRIPTS/MAV must be removed')
            self.assertFalse((card / 'WIDGETS/MAV').exists(), 'WIDGETS/MAV must be removed')
            for rel in ('SCRIPTS/TELEMETRY/MAV.lua', 'SCRIPTS/TELEMETRY/MAV.luac',
                        'SCRIPTS/TOOLS/MAV.lua', 'SCRIPTS/TOOLS/MAV.luac'):
                self.assertFalse((card / rel).exists(), f'{rel} must be removed')

    def test_script_refuses_outside_a_card(self):
        """Guessing wrongly must not delete files, so a folder with no SCRIPTS is refused."""
        package = find_package()
        if package is None:
            self.skipTest('build packages before testing')
        with tempfile.TemporaryDirectory(dir=ROOT / '.build') as temp:
            temp = Path(temp)
            shutil.copy2(ROOT / 'src/uninstall-mav-lua.bat', temp / 'uninstall-mav-lua.bat')
            (temp / 'params.lua').write_text('do not delete me', encoding='ascii')
            result = subprocess.run(['cmd', '/c', 'uninstall-mav-lua.bat /y'], cwd=temp,
                                    capture_output=True, text=True, timeout=60)
            self.assertNotEqual(result.returncode, 0, 'must refuse a non-card folder')
            self.assertIn('does not look like', result.stdout)
            self.assertTrue((temp / 'params.lua').exists(), 'nothing may be deleted')


if __name__ == '__main__':
    unittest.main()
