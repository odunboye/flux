#!/usr/bin/env python3
"""Opt-in vault acceptance on NEW owned devices/apps only. Never uses user AVDs."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import socket
import subprocess
import sys
import tempfile
import time
import uuid

ROOT = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(ROOT / 'tools'))
import workspace

APP = 'org.flux.vaultprobe'


def run(args, cwd=None, env=None, timeout=300, binary=False, input=None):
    process = subprocess.Popen([str(a) for a in args], cwd=cwd, env=env, start_new_session=True,
                               stdin=subprocess.PIPE if input is not None else subprocess.DEVNULL,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=not binary)
    try:
        stdout, stderr = process.communicate(input=input, timeout=timeout)
        if process.returncode:
            raise RuntimeError('Native probe command failed: ' + str(args[0]) + '\n' +
                               (stderr.decode(errors='replace') if binary else stderr)[-4000:])
        return stdout if binary else stdout.strip()
    except BaseException:
        workspace.stop_group(process)
        raise


def cleanup(actions):
    primary = sys.exc_info()[1]
    errors = []
    for action in actions:
        try:
            action()
        except BaseException as error:
            errors.append(error)
            print('Native probe cleanup failed: ' + str(error), file=sys.stderr)
    if errors and primary is None:
        raise RuntimeError('Native probe cleanup incomplete') from errors[0]


def project(directory, capacitor):
    public = directory / 'public'; public.mkdir()
    (public / 'index.html').write_text('<!doctype html><html><head><meta name="viewport" content="width=device-width,initial-scale=1">'
        '<meta http-equiv="Content-Security-Policy" content="default-src \'self\'; script-src \'self\'; style-src \'self\'; object-src \'none\'; base-uri \'none\'; form-action \'none\'">'
        '<link rel="stylesheet" href="probe.css"></head><body>Probe starting<script src="app.js"></script></body></html>')
    (public / 'probe.css').write_text('body{font:36px system-ui;background:white;color:black;padding:80px 10px}')
    (directory / 'probe.js').write_bytes((Path(__file__).parent / 'native-probe.js').read_bytes())
    (directory / 'flux.mobile.json').write_text(json.dumps({'format': 1, 'appId': APP, 'appName': 'Vault Probe',
        'capacitor': str(capacitor), 'webDir': 'public', 'entry': 'probe.js', 'assets': ['index.html', '*.css']}))
    run([ROOT / 'flux', '--project', directory, 'mobile', 'build'])


def ios(directory, runtime):
    run([ROOT / 'flux', '--project', directory, 'mobile', 'sync', 'ios'])
    host = directory / '.workspace/mobile/native/ios/App'
    build = directory / 'ios-build'
    run(['xcodebuild', '-project', 'App.xcodeproj', '-scheme', 'App', '-configuration', 'Debug', '-sdk', 'iphonesimulator',
         '-destination', 'generic/platform=iOS Simulator', '-derivedDataPath', build, 'CODE_SIGNING_ALLOWED=YES', 'CODE_SIGN_IDENTITY=-', 'build'], cwd=host)
    app = build / 'Build/Products/Debug-iphonesimulator/App.app'
    device = run(['xcrun', 'simctl', 'create', 'Flux vault ' + uuid.uuid4().hex[:8],
                  'com.apple.CoreSimulator.SimDeviceType.iPhone-16-Pro', runtime])
    uuid.UUID(device)
    try:
        run(['xcrun', 'simctl', 'boot', device]); run(['xcrun', 'simctl', 'bootstatus', device, '-b'])
        run(['xcrun', 'simctl', 'ui', device, 'appearance', 'light'])
        ocr = directory / 'ocr.swift'
        ocr.write_text('import Foundation\nimport Vision\nimport AppKit\n'
            'let image = NSImage(contentsOfFile: CommandLine.arguments[1])!\n'
            'let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)!\n'
            'let request = VNRecognizeTextRequest(); request.recognitionLevel = .accurate; request.usesLanguageCorrection = false\n'
            'try VNImageRequestHandler(cgImage: cg).perform([request])\n'
            'print((request.results ?? []).compactMap { $0.topCandidates(1).first?.string }.joined(separator: " "))\n')
        run(['swiftc', ocr, '-o', directory / 'ocr'])
        def inspect(expected):
            run(['xcrun', 'simctl', 'launch', device, APP])
            for _ in range(30):
                picture = directory / 'screen.png'
                run(['xcrun', 'simctl', 'io', device, 'screenshot', picture])
                text = run([directory / 'ocr', picture])
                normalized = re.sub('[^A-Z]', '', text.upper())
                if expected.replace(' ', '') in normalized:
                    return
                if 'VAULTFAIL' in normalized:
                    raise RuntimeError('iOS native vault probe failed: ' + text)
                time.sleep(1)
            raise RuntimeError('iOS probe did not render its expected result: ' + text)
        run(['xcrun', 'simctl', 'install', device, app]); inspect('VAULT FIRST PASS')
        run(['xcrun', 'simctl', 'terminate', device, APP]); inspect('VAULT RESTORED PASS')
        run(['xcrun', 'simctl', 'uninstall', device, APP])
        run(['xcrun', 'simctl', 'install', device, app]); inspect('VAULT FIRST PASS')
        print('PASS real iOS Simulator Keychain: cold restore, scope isolation, stale CAS, clear and reinstall reset', flush=True)
    finally:
        cleanup([lambda: run(['xcrun', 'simctl', 'shutdown', device]),
                 lambda: run(['xcrun', 'simctl', 'delete', device])])


def android(directory, sdk, image):
    env = dict(os.environ, ANDROID_HOME=str(sdk), ANDROID_SDK_ROOT=str(sdk))
    env['JAVA_HOME'] = run(['/usr/libexec/java_home', '-v', '21']) if sys.platform == 'darwin' else os.environ['JAVA_HOME']
    run([ROOT / 'flux', '--project', directory, 'mobile', 'sync', 'android'], env=env)
    host = directory / '.workspace/mobile/native/android'
    run(['./gradlew', 'assembleDebug', '--no-daemon'], cwd=host, env=env)
    apk = host / 'app/build/outputs/apk/debug/app-debug.apk'
    manager = sdk / 'cmdline-tools/latest/bin/avdmanager'
    name = 'flux-vault-' + uuid.uuid4().hex
    emulator = None; forwards = []
    try:
        # No --force: never overwrite an existing AVD, even on name collision.
        run([manager, 'create', 'avd', '-n', name, '-k', image,
             '-p', directory / 'owned-avd', '--device', 'pixel_7_pro'], input='no\n', env=env, timeout=120)
        port = None
        for candidate in range(5554, 5682, 2):
            try:
                with socket.socket() as a, socket.socket() as b:
                    a.bind(('127.0.0.1', candidate)); b.bind(('127.0.0.1', candidate + 1)); port = candidate
                break
            except OSError:
                continue
        if port is None:
            raise RuntimeError('No free emulator port')
        serial = 'emulator-' + str(port)
        log = (directory / 'emulator.log').open('w')
        emulator = subprocess.Popen([str(sdk / 'emulator/emulator'), '-avd', name, '-port', str(port),
            '-no-window', '-no-audio', '-no-snapshot', '-no-boot-anim', '-gpu', 'swiftshader_indirect'],
            env=env, stdout=log, stderr=subprocess.STDOUT, start_new_session=True)
        def adb(*args, **kwargs):
            return run([sdk / 'platform-tools/adb', '-s', serial, *args], timeout=30, **kwargs)
        for _ in range(180):
            if emulator.poll() is not None:
                raise RuntimeError('Owned emulator exited before boot')
            try:
                if adb('shell', 'getprop', 'sys.boot_completed') == '1':
                    break
            except RuntimeError:
                pass
            time.sleep(1)
        else:
            raise RuntimeError('Owned emulator did not boot')
        if not adb('emu', 'avd', 'name').startswith(name):
            raise RuntimeError('Refusing to use an emulator not created by this test')
        adb('shell', 'settings', 'put', 'global', 'device_provisioned', '1')
        adb('shell', 'settings', 'put', 'secure', 'user_setup_complete', '1')
        adb('shell', 'svc', 'wifi', 'disable'); adb('shell', 'svc', 'data', 'disable')
        if 'package:com.google.android.setupwizard' in adb('shell', 'pm', 'list', 'packages', 'com.google.android.setupwizard'):
            adb('shell', 'pm', 'disable-user', '--user', '0', 'com.google.android.setupwizard')
        adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'); adb('shell', 'wm', 'dismiss-keyguard')
        adb('shell', 'settings', 'put', 'system', 'screen_off_timeout', '2147483647')
        # Android 12–14 require a secure screen lock for unlocked-device keys.
        # This PIN belongs only to the new disposable emulator, not the app.
        adb('shell', 'locksettings', 'set-pin', '246810')
        def inspect(expected):
            adb('shell', 'input', 'keyevent', 'KEYCODE_WAKEUP'); adb('shell', 'wm', 'dismiss-keyguard')
            adb('shell', 'am', 'start', '-W', '-n', APP + '/.MainActivity')
            time.sleep(2)
            pid = adb('shell', 'pidof', APP).split()[0]
            forwarded = adb('forward', 'tcp:0', 'localabstract:webview_devtools_remote_' + pid)
            forwards.append(forwarded)
            run(['node', Path(__file__).parent / 'native-probe-browser.cjs', forwarded, expected], timeout=40)
        adb('install', '-r', apk); inspect('VAULT FIRST PASS')
        adb('shell', 'am', 'force-stop', APP); inspect('VAULT RESTORED PASS')
        scope = hashlib.sha256(b'idris2-session-vault-v1\0https://vault.example.invalid').hexdigest()
        file = 'no_backup/idris2-vault-' + scope
        ciphertext = adb('exec-out', 'run-as', APP, 'cat', file, binary=True)
        if b'native-probe-fixture' in ciphertext or ciphertext[:1] != b'\x01':
            raise RuntimeError('Vault fixture was not encrypted')
        adb('shell', 'am', 'force-stop', APP)
        other = 'no_backup/idris2-vault-' + hashlib.sha256(b'idris2-session-vault-v1\0https://other.example.invalid').hexdigest()
        adb('shell', 'run-as', APP, 'sh', '-c', '"cp ' + other + ' ' + file + '"')
        inspect('VAULT FAIL read Native vault operation failed')
        adb('shell', 'am', 'force-stop', APP)
        adb('shell', 'run-as', APP, 'sh', '-c', '"printf corrupt > ' + file + '"')
        inspect('VAULT FAIL')
        adb('uninstall', APP); adb('install', apk); inspect('VAULT FIRST PASS')
        adb('shell', 'settings', 'put', 'secure', 'lock_screen_lock_after_timeout', '0')
        adb('shell', 'input', 'keyevent', 'KEYCODE_SLEEP'); time.sleep(3)
        if not re.search(r'deviceLocked=(?:1|true)', adb('shell', 'dumpsys', 'trust')):
            raise RuntimeError('Owned device did not enter its secured lock state')
        run(['node', Path(__file__).parent / 'native-probe-browser.cjs', forwards[-1], 'locked'], timeout=40)
        print('PASS real Android Keystore: cold restore, scope/AAD isolation, stale CAS, encrypted no-backup file, corruption failure, reinstall reset and locked-device read denial', flush=True)
    finally:
        actions = []
        if emulator is not None:
            actions += [lambda port=port: adb('forward', '--remove', 'tcp:' + port) for port in forwards]
            actions += [lambda: workspace.stop_group(emulator), log.close]
        if (directory / 'owned-avd').exists():
            actions.append(lambda: run([manager, 'delete', 'avd', '-n', name], env=env))
        cleanup(actions)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--capacitor', type=Path, required=True)
    parser.add_argument('--platform', choices=['ios', 'android', 'both'], default='both')
    parser.add_argument('--ios-runtime', default='com.apple.CoreSimulator.SimRuntime.iOS-26-5')
    parser.add_argument('--android-sdk', type=Path, default=Path.home() / 'Library/Android/sdk')
    parser.add_argument('--android-image', default='system-images;android-34;google_apis_playstore;arm64-v8a')
    args = parser.parse_args()
    def interrupted(*_):
        raise KeyboardInterrupt()
    signal.signal(signal.SIGTERM, interrupted)
    with tempfile.TemporaryDirectory(prefix='flux-native-vault-') as temporary:
        directory = Path(temporary).resolve()
        project(directory, args.capacitor.resolve(strict=True))
        if args.platform in ['ios', 'both']:
            ios(directory, args.ios_runtime)
        if args.platform in ['android', 'both']:
            android(directory, args.android_sdk.resolve(strict=True), args.android_image)


if __name__ == '__main__':
    main()
