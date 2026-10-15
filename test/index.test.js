'use strict';

const assert = require('assert');
const fs = require('fs');
const path = require('path');
const vm = require('vm');

function loadManager(platform, nativeModule, vibration, emitters = {}) {
    const filename = path.join(__dirname, '..', 'index.js');
    let source = fs.readFileSync(filename, 'utf8');
    source = source.replace(
        /import \{([^}]*)\} from 'react-native';/,
        (_, names) => `const {${names}} = require('react-native');`
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
                NativeEventEmitter: emitters.NativeEventEmitter,
                DeviceEventEmitter: emitters.DeviceEventEmitter,
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

async function runListeners() {
    const vibration = { vibrate() {}, cancel() {} };

    {
        // iOS: RCTEventEmitter only sends while a NativeEventEmitter built on this module has a
        // listener; DeviceEventEmitter.addListener alone never reaches the native side.
        const made = [];
        class NativeEventEmitter {
            constructor(module) { this.module = module; made.push(this); this.added = []; }
            addListener(event, listener) { this.added.push(event); return { remove() {}, event, listener }; }
        }
        const nativeModule = {};
        const deviceEventEmitter = { addListener() { throw new Error('ios must not use DeviceEventEmitter'); } };
        const manager = loadManager('ios', nativeModule, vibration, { NativeEventEmitter, DeviceEventEmitter: deviceEventEmitter });

        const listener = () => {};
        const first = manager.addListener('onAudioDeviceChanged', listener);
        manager.addListener('Proximity', listener);

        assert.strictEqual(made.length, 1);
        assert.strictEqual(made[0].module, nativeModule);
        assert.deepStrictEqual(made[0].added, ['onAudioDeviceChanged', 'Proximity']);
        assert.strictEqual(first.listener, listener);
        assert.strictEqual(typeof first.remove, 'function');
    }

    {
        // Android sends through RCTDeviceEventEmitter, which DeviceEventEmitter listens to.
        const added = [];
        const deviceEventEmitter = { addListener(event) { added.push(event); return { remove() {} }; } };
        class NativeEventEmitter { constructor() { throw new Error('android uses DeviceEventEmitter'); } }
        const manager = loadManager('android', {}, vibration, { NativeEventEmitter, DeviceEventEmitter: deviceEventEmitter });

        manager.addListener('onAudioDeviceChanged', () => {});
        assert.deepStrictEqual(added, ['onAudioDeviceChanged']);
    }
}

run();
Promise.all([runAudioRoutes(), runListeners()]).then(() => {
    console.log('index.js wrapper tests passed');
}, (err) => {
    console.error(err);
    process.exitCode = 1;
});
