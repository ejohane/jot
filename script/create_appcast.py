#!/usr/bin/env python3
"""Sign the final archive and generate Sparkle's public release feed."""
import base64
import os
from pathlib import Path
import plistlib
import subprocess
import xml.etree.ElementTree as ET

SPARKLE = 'http://www.andymatuschak.org/xml-namespaces/sparkle'
ET.register_namespace('sparkle', SPARKLE)


def create_appcast(version, build, signature, size):
    release = f'https://github.com/ejohane/jot/releases/tag/v{version}'
    root = ET.Element('rss', version='2.0')
    channel = ET.SubElement(root, 'channel')
    ET.SubElement(channel, 'title').text = 'Jot Updates'
    ET.SubElement(channel, 'link').text = 'https://github.com/ejohane/jot'
    ET.SubElement(channel, 'description').text = 'Jot for macOS'
    item = ET.SubElement(channel, 'item')
    ET.SubElement(item, 'title').text = f'Jot {version}'
    ET.SubElement(item, 'link').text = release
    ET.SubElement(item, f'{{{SPARKLE}}}version').text = build
    ET.SubElement(item, f'{{{SPARKLE}}}shortVersionString').text = version
    ET.SubElement(item, f'{{{SPARKLE}}}minimumSystemVersion').text = '14.0'
    ET.SubElement(item, 'description').text = f'Jot {version}. See the GitHub release for changes.'
    ET.SubElement(item, 'enclosure', {
        'url': f'https://github.com/ejohane/jot/releases/download/v{version}/Jot.zip',
        'length': str(size), 'type': 'application/octet-stream',
        f'{{{SPARKLE}}}edSignature': signature,
    })
    ET.indent(root)
    return ET.tostring(root, encoding='utf-8', xml_declaration=True)


def main():
    os.chdir(Path(__file__).resolve().parent.parent)
    archive = Path('dist/Jot.zip')
    with open('dist/Jot.app/Contents/Info.plist', 'rb') as source:
        info = plistlib.load(source)
    key = os.environ['JOT_SPARKLE_PRIVATE_KEY']
    tool = '.build/artifacts/sparkle/Sparkle/bin/sign_update'
    signature = subprocess.check_output(
        [tool, '--ed-key-file', '-', '-p', str(archive)], input=key.encode()
    ).decode().strip()
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise SystemExit('Invalid update signature')
    # Check the signature using the same tool before making the feed public.
    subprocess.run(
        [tool, '--ed-key-file', '-', '--verify', str(archive), signature],
        input=key.encode(), check=True,
    )
    subprocess.run([
        'swift', '-sdk', subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip(),
        'script/verify_update.swift', str(archive),
        'Config/sparkle-public-key.txt', signature,
    ], check=True)
    Path('dist/appcast.xml').write_bytes(create_appcast(
        info['CFBundleShortVersionString'], info['CFBundleVersion'],
        signature, archive.stat().st_size,
    ))
    print('Signed update archive and generated dist/appcast.xml')


if __name__ == '__main__':
    main()
