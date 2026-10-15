'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function loadManager(platform, nativeModule, vibration) {
    const filename = path.join(__dirname, '..', 'index.js');
    let source = fs.readFileSync(filename, 'utf8');
    source = source.replace(
        /import \{\s*Platform,\s*Vibration,\s*\} from 'react-native';/,
        "const { Platform, Vibration } = require('react-native');"
    );
    source = source.replace(
        'export default new InCallManager();',
        'module.exports = new InCallManager();'
    );

    const module = { exports: {} };
    const context = {
        console,
        module,
        exports: module.exports,
        require(name) {
            assert.strictEqual(name, 'react-native');
            return {
                NativeModules: { InCallManager: nativeModule },
                Platform: { OS: platform },
                Vibration: vibration,
            };
        },
    };
    vm.runInNewContext(source, context, { filename });
    return module.exports;
}

function run() {
    {
        const calls = [];
        const nativeModule = {
            startRingtoneWithVibration(...args) { calls.push(args); },
            stopRingtone() { calls.push(['stop']); },
        };
        const vibration = {
            vibrate() { throw new Error('new Android native must own vibration'); },
            cancel() { throw new Error('new Android native must own cancellation'); },
        };
        const manager = loadManager('android', nativeModule, vibration);

        manager.startRingtone('_DEFAULT_', [0, 250], 'default', 3);
        manager.stopRingtone();

        assert.deepStrictEqual(calls[0], ['_DEFAULT_', 3, [0, 250]]);
        assert.deepStrictEqual(calls[1], ['stop']);
    }

    {
        const calls = [];
        const nativeModule = {
            startRingtone(...args) { calls.push(['start', ...args]); },
            stopRingtone() { calls.push(['stop']); },
        };
        const vibration = {
            vibrate(...args) { calls.push(['vibrate', ...args]); },
            cancel() { calls.push(['cancel']); },
        };
        const manager = loadManager('android', nativeModule, vibration);

        manager.startRingtone('_BUNDLE_', [0, 100], 'default', 2);
        manager.stopRingtone();

        assert.deepStrictEqual(calls, [
            ['start', '_BUNDLE_', 2],
            ['vibrate', [0, 100], false],
            ['cancel'],
            ['stop'],
        ]);
    }

    {
        const calls = [];
        const nativeModule = {
            startRingtone(...args) { calls.push(['start', ...args]); },
            stopRingtone() { calls.push(['stop']); },
        };
        const vibration = {
            vibrate(...args) { calls.push(['vibrate', ...args]); },
            cancel() { calls.push(['cancel']); },
        };
        const manager = loadManager('ios', nativeModule, vibration);

        manager.startRingtone('_DEFAULT_', [0, 150], 'playback', 9);
        manager.stopRingtone();

        assert.deepStrictEqual(calls, [
            ['start', '_DEFAULT_', 'playback'],
            ['vibrate', [0, 150], false],
            ['cancel'],
            ['stop'],
        ]);
    }

}

async function runAudioRoutes() {
    const status = {
        availableAudioDeviceList: '["EARPIECE","SPEAKER_PHONE","BLUETOOTH"]',
        selectedAudioDevice: 'BLUETOOTH',
        selectedAudioDeviceName: 'Headset',
    };
    const vibration = { vibrate() {}, cancel() {} };

    {
        const calls = [];
        const nativeModule = {
            chooseAudioRoute(...args) { calls.push(['choose', ...args]); return Promise.resolve(status); },
            getAudioDeviceStatus() { calls.push(['status']); return Promise.resolve(status); },
        };
        const manager = loadManager('ios', nativeModule, vibration);

        assert.deepStrictEqual(await manager.chooseAudioRoute('BLUETOOTH'), status);
        assert.deepStrictEqual(await manager.getAudioDeviceStatus(), status);
        assert.deepStrictEqual(calls, [['choose', 'BLUETOOTH'], ['status']]);
    }

    {
        const nativeModule = {
            chooseAudioRoute() { return Promise.reject(new Error('EARPIECE is not available')); },
        };
        const manager = loadManager('ios', nativeModule, vibration);

        await assert.rejects(manager.chooseAudioRoute('EARPIECE'), /EARPIECE is not available/);
    }

    {
        const nativeModule = {
            getAudioDeviceStatus() { throw new Error('android native has no getAudioDeviceStatus'); },
        };
        const manager = loadManager('android', nativeModule, vibration);

        await assert.rejects(manager.getAudioDeviceStatus(), /android doesn't support getAudioDeviceStatus/);
    }
}

run();
runAudioRoutes().then(() => {
    console.log('index.js wrapper tests passed');
}, (err) => {
    console.error(err);
    process.exitCode = 1;
});
