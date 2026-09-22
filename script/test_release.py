#!/usr/bin/env python3
"""Exercise real Sparkle signing with disposable keys and reject tampered updates."""
import json
import os
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parent.parent
SWIFT = ['swift', '-sdk', subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()]
NS = {'sparkle': 'http://www.andymatuschak.org/xml-namespaces/sparkle'}


def test_key():
    # Random, disposable test keys; never reads release credentials.
    source = '''
import Foundation
import CryptoKit
let key = Curve25519.Signing.PrivateKey()
let result = ["private": key.rawRepresentation.base64EncodedString(),
              "public": key.publicKey.rawRepresentation.base64EncodedString()]
print(String(data: try JSONSerialization.data(withJSONObject: result), encoding: .utf8)!)
'''
    return json.loads(subprocess.check_output([*SWIFT, '-'], input=source.encode()))


class UpdateSigningTests(unittest.TestCase):
    def test_signed_feed_and_tamper_rejection(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for subdirectory in ('script', 'Config', 'dist/Jot.app/Contents', '.build/artifacts/sparkle'):
                (root / subdirectory).mkdir(parents=True)
            for name in ('create_appcast.py', 'verify_update.swift'):
                shutil.copy(ROOT / 'script' / name, root / 'script' / name)
            (root / '.build/artifacts/sparkle/Sparkle').symlink_to(ROOT / '.build/artifacts/sparkle/Sparkle')
            key = test_key()
            public = root / 'Config/sparkle-public-key.txt'
            public.write_text(key['public'])
            with (root / 'dist/Jot.app/Contents/Info.plist').open('wb') as output:
                plistlib.dump({'CFBundleShortVersionString': '0.1.42', 'CFBundleVersion': '42'}, output)
            archive = root / 'dist/Jot.zip'
            archive.write_bytes(b'disposable update archive fixture')
            env = dict(os.environ, JOT_SPARKLE_PRIVATE_KEY=key['private'])
            subprocess.run(['python3', str(root / 'script/create_appcast.py')], env=env, check=True, capture_output=True)
            item = ET.parse(root / 'dist/appcast.xml').find('./channel/item')
            self.assertEqual(item.find('sparkle:version', NS).text, '42')
            enclosure = item.find('enclosure')
            self.assertEqual(int(enclosure.get('length')), archive.stat().st_size)
            self.assertIn('/v0.1.42/Jot.zip', enclosure.get('url'))
            signature = enclosure.get(f"{{{NS['sparkle']}}}edSignature")
            command = [*SWIFT, str(root / 'script/verify_update.swift'), str(archive), str(public), signature]
            self.assertEqual(subprocess.run(command, capture_output=True).returncode, 0)
            archive.write_bytes(b'tampered update archive fixture!!')
            self.assertNotEqual(subprocess.run(command, capture_output=True).returncode, 0)
            # A valid signature from the wrong CI key must also fail publication.
            env['JOT_SPARKLE_PRIVATE_KEY'] = test_key()['private']
            result = subprocess.run(['python3', str(root / 'script/create_appcast.py')], env=env, capture_output=True)
            self.assertNotEqual(result.returncode, 0)
            self.assertIn(b'does not match the public key', result.stderr)


if __name__ == '__main__':
    unittest.main()
