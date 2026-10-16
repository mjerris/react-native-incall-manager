//
//  RNInCallManager.m
//  RNInCallManager
//
//  Created by Ian Yu-Hsun Lin (@ianlin) on 05/12/2017.
//  Copyright © 2017 zxcpoiu. All rights reserved.
//

#import "RNInCallManager.h"

#import <React/RCTBridge.h>
#import <React/RCTConvert.h>
#import <React/RCTEventDispatcher.h>
#import <React/RCTUtils.h>

//static BOOL const automatic = YES;

@implementation RNInCallManager
{
    UIDevice *_currentDevice;

    AVAudioSession *_audioSession;
    AVAudioPlayer *_ringtone;
    AVAudioPlayer *_ringback;
    AVAudioPlayer *_busytone;

    NSURL *_defaultRingtoneUri;
    NSURL *_defaultRingbackUri;
    NSURL *_defaultBusytoneUri;
    NSURL *_bundleRingtoneUri;
    NSURL *_bundleRingbackUri;
    NSURL *_bundleBusytoneUri;

    //BOOL isProximitySupported;
    BOOL _proximityIsNear;

    // --- tags to indicating which observer has added
    BOOL _isProximityRegistered;
    BOOL _isAudioSessionInterruptionRegistered;
    BOOL _isAudioSessionRouteChangeRegistered;
    BOOL _isAudioSessionMediaServicesWereLostRegistered;
    BOOL _isAudioSessionMediaServicesWereResetRegistered;
    BOOL _isAudioSessionSilenceSecondaryAudioHintRegistered;
    BOOL _isAudioSessionAvailableInputsChangeRegistered;

    // -- notification observers
    id _proximityObserver;
    id _audioSessionInterruptionObserver;
    id _audioSessionRouteChangeObserver;
    id _audioSessionMediaServicesWereLostObserver;
    id _audioSessionMediaServicesWereResetObserver;
    id _audioSessionSilenceSecondaryAudioHintObserver;
    id _audioSessionAvailableInputsChangeObserver;

    NSString *_incallAudioMode;
    NSString *_incallAudioCategory;
    NSString *_origAudioCategory;
    NSString *_origAudioMode;
    BOOL _audioSessionInitialized;
    // --- one per call's session: start() and stop() each move it on. The observers registered
    // --- by start() capture it, so work they queue for an ended session is dropped, even when
    // --- the next session has started (and set the registered flags again) by the time it runs.
    // --- Read and written only on the route queue.
    NSUInteger _sessionGeneration;
    int _forceSpeakerOn;
    NSString *_media;
    BOOL _hasListeners;
    NSDictionary *_lastAudioDeviceStatus;
    // --- the route a chooseAudioRoute call pinned the preferred input for (EARPIECE: the built-in
    // --- mic), so it can be pinned again after a media services reset; nil when nothing is pinned.
    NSString *_chosenInputRoute;
    // --- a choice whose route hasn't shown up in currentRoute yet, answered when it does.
    NSString *_pendingChoiceRoute;
    RCTPromiseResolveBlock _pendingChoiceResolve;
    NSUInteger _choiceSerial;
    // --- the module's method queue (see methodQueue). The route-change observer hands its work
    // --- to it as well, so the route state above, the status sent and the answers to choices are
    // --- read and written in one order, and a handler never samples a change halfway through.
    dispatch_queue_t _routeQueue;
}

static const void *const RNInCallManagerRouteQueueKey = &RNInCallManagerRouteQueueKey;

+ (BOOL)requiresMainQueueSetup
{
    return NO;
}

RCT_EXPORT_MODULE(InCallManager)

- (dispatch_queue_t)methodQueue
{
    return _routeQueue;
}

/** Runs `block` on the route queue, and waits for it. Safe to call from the queue itself. */
- (void)onRouteQueue:(dispatch_block_t)block
{
    if (dispatch_get_specific(RNInCallManagerRouteQueueKey) != NULL) {
        block();
    } else {
        dispatch_sync(_routeQueue, block);
    }
}

- (instancetype)init
{
    if (self = [super init]) {
        _currentDevice = [UIDevice currentDevice];
        _audioSession = [AVAudioSession sharedInstance];
        _ringtone = nil;
        _ringback = nil;
        _busytone = nil;

        _defaultRingtoneUri = nil;
        _defaultRingbackUri = nil;
        _defaultBusytoneUri = nil;
        _bundleRingtoneUri = nil;
        _bundleRingbackUri = nil;
        _bundleBusytoneUri = nil;

        _proximityIsNear = NO;

        _isProximityRegistered = NO;
        _isAudioSessionInterruptionRegistered = NO;
        _isAudioSessionRouteChangeRegistered = NO;
        _isAudioSessionMediaServicesWereLostRegistered = NO;
        _isAudioSessionMediaServicesWereResetRegistered = NO;
        _isAudioSessionSilenceSecondaryAudioHintRegistered = NO;
        _isAudioSessionAvailableInputsChangeRegistered = NO;

        _proximityObserver = nil;
        _audioSessionInterruptionObserver = nil;
        _audioSessionRouteChangeObserver = nil;
        _audioSessionMediaServicesWereLostObserver = nil;
        _audioSessionMediaServicesWereResetObserver = nil;
        _audioSessionSilenceSecondaryAudioHintObserver = nil;
        _audioSessionAvailableInputsChangeObserver = nil;

        _incallAudioMode = AVAudioSessionModeVoiceChat;
        _incallAudioCategory = AVAudioSessionCategoryPlayAndRecord;
        _origAudioCategory = nil;
        _origAudioMode = nil;
        _audioSessionInitialized = NO;
        _sessionGeneration = 0;
        _forceSpeakerOn = 0;
        _media = @"audio";
        _routeQueue = dispatch_queue_create("com.zxcpoiu.incallmanager.route", DISPATCH_QUEUE_SERIAL);
        dispatch_queue_set_specific(_routeQueue, RNInCallManagerRouteQueueKey, (void *)RNInCallManagerRouteQueueKey, NULL);

        NSLog(@"RNInCallManager.init(): initialized");
    }
    return self;
}

- (void)dealloc
{
    // --- the observers hold this module weakly: take them away with it.
    [self stopProximitySensor];
    [self stopAudioSessionNotification];
}

// --- a JS reload, or the bridge going away: React Native calls this on the method queue. Without
// --- it the old instance keeps its observers and goes on re-applying its route next to the new one.
- (void)invalidate
{
    [self onRouteQueue:^{
        [self stop:@""];
    }];
    [super invalidate];
}

- (NSArray<NSString *> *)supportedEvents
{
    return @[@"Proximity",
             @"WiredHeadset",
             @"onAudioDeviceChanged"];
}

// --- startObserving and stopObserving run on the method queue (RCTEventEmitter's addListener: and
// --- removeListeners: are methods of this module).
- (void)startObserving
{
    // --- a new listener hears the next change, whatever was sent before it subscribed.
    _lastAudioDeviceStatus = nil;
    _hasListeners = YES;
}

- (void)stopObserving
{
    _hasListeners = NO;
}

// --- Audio routes use the same names as Android: EARPIECE, SPEAKER_PHONE, WIRED_HEADSET, BLUETOOTH.
// --- A call on iOS is routed by its input: the preferred input picks the device (a Bluetooth
// --- HFP headset or a wired headset carries both directions), and the built-in mic routes the
// --- output to the receiver. The speaker is an output override on top of that.
// --- USB audio (a USB-C headset) counts as a wired headset.
static NSDictionary<NSString *, NSArray<AVAudioSessionPort> *> *RNInCallManagerPortsForRoute(void)
{
    static NSDictionary<NSString *, NSArray<AVAudioSessionPort> *> *ports;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        ports = @{
            @"EARPIECE": @[AVAudioSessionPortBuiltInReceiver],
            @"SPEAKER_PHONE": @[AVAudioSessionPortBuiltInSpeaker],
            @"WIRED_HEADSET": @[AVAudioSessionPortHeadphones, AVAudioSessionPortHeadsetMic, AVAudioSessionPortUSBAudio],
            @"BLUETOOTH": @[AVAudioSessionPortBluetoothHFP, AVAudioSessionPortBluetoothA2DP,
                            AVAudioSessionPortBluetoothLE, AVAudioSessionPortCarAudio],
        };
    });
    return ports;
}

- (NSArray<AVAudioSessionPort> *)portTypesForAudioRoute:(NSString *)audioRoute
{
    return RNInCallManagerPortsForRoute()[audioRoute];
}

- (NSString *)audioRouteForPortType:(AVAudioSessionPort)portType
{
    // --- the table above, read backwards (no port type is in two routes).
    static NSDictionary<AVAudioSessionPort, NSString *> *routes;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSMutableDictionary<AVAudioSessionPort, NSString *> *byPort = [NSMutableDictionary dictionary];
        [RNInCallManagerPortsForRoute() enumerateKeysAndObjectsUsingBlock:^(NSString *audioRoute, NSArray<AVAudioSessionPort> *portTypes, BOOL *stop) {
            for (AVAudioSessionPort type in portTypes) {
                byPort[type] = audioRoute;
            }
        }];
        routes = [byPort copy];
    });
    return portType != nil ? routes[portType] : nil;
}

- (BOOL)hasEarpiece
{
    return _currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone;
}

- (AVAudioSessionPortDescription *)preferredInputForAudioRoute:(NSString *)audioRoute
{
    // --- the earpiece has no input of its own: the built-in mic selects it.
    NSString *portType = [audioRoute isEqualToString:@"EARPIECE"] ? AVAudioSessionPortBuiltInMic : nil;
    for (AVAudioSessionPortDescription *input in _audioSession.availableInputs) {
        if (portType != nil
                ? [input.portType isEqualToString:portType]
                : [[self audioRouteForPortType:input.portType] isEqualToString:audioRoute]) {
            return input;
        }
    }
    return nil;
}

- (BOOL)isCurrentOutputAudioRoute:(NSString *)audioRoute
{
    return [self checkAudioRoute:[self portTypesForAudioRoute:audioRoute] routeType:@"output"];
}

/** The route of an output port, or nil (AirPlay, HDMI, or no output). */
- (NSString *)audioRouteForOutput:(AVAudioSessionPortDescription *)output
{
    return [self audioRouteForPortType:output.portType];
}

/** The route of the current output, or nil (AirPlay, HDMI, or no output). */
- (NSString *)currentOutputAudioRoute
{
    return [self audioRouteForOutput:_audioSession.currentRoute.outputs.firstObject];
}

- (NSDictionary *)audioDeviceStatus
{
    NSMutableOrderedSet<NSString *> *available = [NSMutableOrderedSet orderedSet];
    // --- iOS has no receiver override: with a wired or USB headset plugged in the call can't
    // --- reach the earpiece (chooseAudioRoute refuses it).
    if ([self hasEarpiece] && ![self isWiredHeadsetPluggedIn]) {
        [available addObject:@"EARPIECE"];
    }
    [available addObject:@"SPEAKER_PHONE"];
    for (AVAudioSessionPortDescription *input in _audioSession.availableInputs) {
        NSString *audioRoute = [self audioRouteForPortType:input.portType];
        if (audioRoute != nil) {
            [available addObject:audioRoute];
        }
    }
    // --- output-only devices (wired headphones without a mic, A2DP) have no input to list.
    AVAudioSessionPortDescription *output = _audioSession.currentRoute.outputs.firstObject;
    NSString *selected = [self audioRouteForOutput:output];
    if (selected != nil) {
        [available addObject:selected];
    }

    NSData *json = [NSJSONSerialization dataWithJSONObject:available.array options:0 error:nil];
    NSString *availableJson = json != nil ? [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding] : nil;
    return @{
        @"availableAudioDeviceList": availableJson ?: @"[]",
        @"selectedAudioDevice": selected ?: @"",
        @"selectedAudioDeviceName": output.portName ?: @"",
    };
}

// --- like android, only report when the available routes or the selected one changed, only
// --- between start() and stop(), and only to a listener (subscribed through NativeEventEmitter:
// --- see addListener in index.js). On the route queue, like every caller.
- (void)sendAudioDeviceChanged
{
    if (!_hasListeners || !_audioSessionInitialized) {
        return;
    }
    [self sendAudioDeviceStatus:[self audioDeviceStatus]];
}

- (void)sendAudioDeviceStatus:(NSDictionary *)status
{
    if (!_hasListeners || !_audioSessionInitialized || [status isEqualToDictionary:_lastAudioDeviceStatus]) {
        return;
    }
    _lastAudioDeviceStatus = status;
    [self sendEventWithName:@"onAudioDeviceChanged" body:status];
}

/** Whether the flag puts the call on the speaker: forced (1), or a video call's default (0). */
- (BOOL)flagPutsSpeaker:(int)flag
{
    return flag == 1 || (flag == 0 && [_media isEqualToString:@"video"]);
}

/**
 * Whether `output` (a route, or nil) is where the flag leaves the call. A connected headset or
 * car has the call under any flag but a forced speaker.
 */
- (BOOL)output:(NSString *)output fitsFlag:(int)flag
{
    if ([output isEqualToString:@"WIRED_HEADSET"] || [output isEqualToString:@"BLUETOOTH"]) {
        return flag != 1;
    }
    return [output isEqualToString:@"SPEAKER_PHONE"] == [self flagPutsSpeaker:flag];
}

/** Sets the flag and applies it, as setForceSpeakerphoneOn does: the mode, the sensor, the override. */
- (void)applyForceSpeaker:(int)flag caller:(NSString *)caller
{
    if (flag != _forceSpeakerOn) {
        NSLog(@"RNInCallManager.%@: forceSpeakerOn %d -> %d", caller, _forceSpeakerOn, flag);
    }
    _forceSpeakerOn = flag;
    [self updateAudioRoute];
}

- (void)clearPreferredInput:(NSString *)caller
{
    _chosenInputRoute = nil;
    NSError *error = nil;
    if (![_audioSession setPreferredInput:nil error:&error]) {
        NSLog(@"RNInCallManager.%@: setPreferredInput(nil) failed: %@", caller, error);
    }
}

/** Drops a preferred input that would take the call somewhere other than `audioRoute`. */
- (void)clearPreferredInputUnlessRoute:(NSString *)audioRoute caller:(NSString *)caller
{
    AVAudioSessionPortDescription *preferred = _audioSession.preferredInput;
    if (preferred == nil) {
        return;
    }
    NSString *preferredRoute = [preferred.portType isEqualToString:AVAudioSessionPortBuiltInMic]
        ? @"EARPIECE"
        : [self audioRouteForPortType:preferred.portType];
    if (![preferredRoute isEqualToString:audioRoute]) {
        NSLog(@"RNInCallManager.%@: %@ has the call: dropping the preferred input %@", caller, audioRoute, preferred.portType);
        [self clearPreferredInput:caller];
    }
}

/**
 * Keeps _forceSpeakerOn, and the preferred input, in step with a route change this module didn't
 * make, so the category-change re-apply in updateAudioRoute keeps what iOS or the user chose
 * instead of undoing it. AVAudioSessionRouteChangeReasonKey tells the kinds apart:
 *
 * - a device arriving or leaving (NewDeviceAvailable, OldDeviceUnavailable): iOS has already
 *   moved the call, dropping a speaker override when a headset or car took it;
 * - an output override, or a reason iOS doesn't name (Override, Unknown, RouteConfigurationChange):
 *   the system route picker or CallKit's speaker button chose the speaker, the receiver or a
 *   device. This module's own overrides and preferred inputs post these too, but they move the
 *   call to where the flag puts it, so the previous route (AVAudioSessionRouteChangePreviousRouteKey)
 *   didn't fit the flag; someone else's move the call away from there.
 * - every other reason leaves the flag alone. A category change is re-applied instead
 *   (updateAudioRoute): sampling the route then would read the override it just dropped.
 *
 * Flag values: 1 forces the speaker, -1 is "speaker off" (voice chat mode for a video call),
 * 0 is the media's default (video chat mode, on the speaker, for a video call).
 */
- (void)followRouteChange:(NSUInteger)reason previousRoute:(AVAudioSessionRouteDescription *)previousRoute
{
    BOOL deviceChange = reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable
        || reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable;
    if (!deviceChange) {
        if (reason != AVAudioSessionRouteChangeReasonOverride
                && reason != AVAudioSessionRouteChangeReasonUnknown
                && reason != AVAudioSessionRouteChangeReasonRouteConfigurationChange) {
            return;
        }
        if (previousRoute != nil
                && ![self output:[self audioRouteForOutput:previousRoute.outputs.firstObject] fitsFlag:_forceSpeakerOn]) {
            // --- the call was on its way to where the flag puts it: our own change.
            return;
        }
    }

    NSString *output = [self currentOutputAudioRoute];
    int flag = _forceSpeakerOn;
    if ([output isEqualToString:@"WIRED_HEADSET"] || [output isEqualToString:@"BLUETOOTH"]) {
        // --- a headset or car has the call: the media's default, so neither a forced speaker
        // --- nor a video call's voice chat mode and proximity sensor is put back over it, and a
        // --- device or receiver choice made before doesn't pin the input elsewhere.
        flag = 0;
        [self clearPreferredInputUnlessRoute:output caller:@"followRouteChange()"];
    } else if (deviceChange) {
        // --- a device left, and iOS chose what follows from the flag (the media's default
        // --- after a device, the receiver after "speaker off"). Nothing to follow.
        return;
    } else if ([output isEqualToString:@"SPEAKER_PHONE"]) {
        if (![self flagPutsSpeaker:flag]) {
            flag = 1;
        }
    } else if ([output isEqualToString:@"EARPIECE"]) {
        if ([self flagPutsSpeaker:flag]) {
            flag = -1;
        }
        [self clearPreferredInputUnlessRoute:output caller:@"followRouteChange()"];
    }
    if (flag != _forceSpeakerOn) {
        NSLog(@"RNInCallManager.followRouteChange(): output=%@", output);
        // --- the mode and proximity sensor follow the flag, as for setForceSpeakerphoneOn.
        [self applyForceSpeaker:flag caller:@"followRouteChange()"];
    }
}

/**
 * An output-only device (mic-less headphones, A2DP) has no input to find it by, and only a
 * forced speaker can hide it. Looks under the override, putting it back if the device isn't there.
 */
- (BOOL)isOutputUnderSpeakerOverride:(NSString *)audioRoute
{
    if (_forceSpeakerOn != 1) {
        return NO;
    }
    [self overrideOutputAudioPort:AVAudioSessionPortOverrideNone caller:@"chooseAudioRoute()"];
    if ([self isCurrentOutputAudioRoute:audioRoute]) {
        return YES;
    }
    [self overrideOutputAudioPort:AVAudioSessionPortOverrideSpeaker caller:@"chooseAudioRoute()"];
    return NO;
}

/**
 * Answers a choice with the status once the output is on the chosen route: at once when
 * currentRoute already shows it, else when a route change brings it there (handleRouteChange),
 * or after a second with wherever iOS put the call. setPreferredInput only "will initiate a
 * route change" (AVAudioSession.h), so currentRoute can still show the old route when it returns.
 */
- (void)answerChoice:(NSString *)audioRoute resolve:(RCTPromiseResolveBlock)resolve
{
    _pendingChoiceRoute = audioRoute;
    _pendingChoiceResolve = resolve;
    if ([self isCurrentOutputAudioRoute:audioRoute]) {
        [self answerPendingChoice];
        return;
    }
    NSLog(@"RNInCallManager.chooseAudioRoute(): %@ is not the route yet; answering when it is", audioRoute);
    NSUInteger choice = ++_choiceSerial;
    __weak RNInCallManager *weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)NSEC_PER_SEC), _routeQueue, ^{
        RNInCallManager *strongSelf = weakSelf;
        if (strongSelf != nil && strongSelf->_choiceSerial == choice) {
            [strongSelf answerPendingChoice];
        }
    });
}

- (void)answerPendingChoice
{
    RCTPromiseResolveBlock resolve = _pendingChoiceResolve;
    if (resolve == nil) {
        return;
    }
    _pendingChoiceResolve = nil;
    _pendingChoiceRoute = nil;
    _choiceSerial++;
    // --- the event first: a listener hears the change before the promise settles, as for a
    // --- report, and the dedup then drops the observer's copy of the same status.
    NSDictionary *status = [self audioDeviceStatus];
    [self sendAudioDeviceStatus:status];
    resolve(status);
}

RCT_EXPORT_METHOD(chooseAudioRoute:(NSString *)audioRoute
                           resolve:(RCTPromiseResolveBlock)resolve
                            reject:(RCTPromiseRejectBlock)reject)
{
    NSLog(@"RNInCallManager.chooseAudioRoute(): audioRoute=%@", audioRoute);
    // --- like android, a choice is part of a call: before start() it would set the category
    // --- that start() then records as the app's own, and start() resets the flag anyway.
    if (!_audioSessionInitialized) {
        reject(@"E_AUDIO_ROUTE_INACTIVE", @"chooseAudioRoute(): call start() first", nil);
        return;
    }
    if ([self portTypesForAudioRoute:audioRoute] == nil) {
        reject(@"E_AUDIO_ROUTE_UNAVAILABLE",
               [NSString stringWithFormat:@"chooseAudioRoute(): %@ is not a route", audioRoute], nil);
        return;
    }
    // --- an earlier choice still waiting for its route is answered with where the call is now.
    [self answerPendingChoice];
    @try {
        if ([audioRoute isEqualToString:@"SPEAKER_PHONE"]) {
            // --- the mode follows the flag (video chat for a video call), then the override.
            [self applyForceSpeaker:1 caller:@"chooseAudioRoute()"];
            [self answerChoice:audioRoute resolve:resolve];
            return;
        }
        AVAudioSessionPortDescription *input = [self preferredInputForAudioRoute:audioRoute];
        BOOL available;
        if ([audioRoute isEqualToString:@"EARPIECE"]) {
            // --- iOS has no receiver override: a wired or USB headset keeps the output whatever
            // --- the input, and the call would play on the headset and record from the phone.
            available = [self hasEarpiece] && input != nil && ![self isWiredHeadsetPluggedIn];
        } else {
            // --- a device with an input, or an output-only one: the current output, or hidden
            // --- under a forced speaker.
            available = input != nil
                || [self isCurrentOutputAudioRoute:audioRoute]
                || [self isOutputUnderSpeakerOverride:audioRoute];
        }
        if (!available) {
            // --- refused before anything changed: the route stays as it was.
            reject(@"E_AUDIO_ROUTE_UNAVAILABLE",
                   [NSString stringWithFormat:@"chooseAudioRoute(): %@ is not available", audioRoute], nil);
            return;
        }
        // --- the mode follows the flag. A video call is in video chat mode, which defaults
        // --- to the speaker: the earpiece needs voice chat mode, or the built-in mic stays
        // --- paired with the speaker. This also clears a speaker override, which an
        // --- output-only device needs before it can be the route.
        [self applyForceSpeaker:[audioRoute isEqualToString:@"EARPIECE"] ? -1 : 0 caller:@"chooseAudioRoute()"];
        // --- an output-only device (no input) is the route once the override is gone; nil
        // --- also drops an earlier pin (the built-in mic for the earpiece).
        NSError *error = nil;
        if (![_audioSession setPreferredInput:input error:&error]) {
            reject(@"E_AUDIO_ROUTE", error.localizedDescription ?: @"chooseAudioRoute() failed", error);
            return;
        }
        _chosenInputRoute = input != nil ? audioRoute : nil;
        [self answerChoice:audioRoute resolve:resolve];
    } @catch (NSException *e) {
        reject(@"E_AUDIO_ROUTE", [NSString stringWithFormat:@"chooseAudioRoute(): %@", e.reason ?: @"exception"], nil);
    }
}

RCT_EXPORT_METHOD(getAudioDeviceStatus:(RCTPromiseResolveBlock)resolve
                                reject:(RCTPromiseRejectBlock)reject)
{
    resolve([self audioDeviceStatus]);
}

RCT_EXPORT_METHOD(start:(NSString *)mediaType
                   auto:(BOOL)_auto
        ringbackUriType:(NSString *)ringbackUriType)
{
    if (_audioSessionInitialized) {
        return;
    }
    _media = mediaType;

    // --- auto is always true on ios
    if ([_media isEqualToString:@"video"]) {
        _incallAudioMode = AVAudioSessionModeVideoChat;
    } else {
        _incallAudioMode = AVAudioSessionModeVoiceChat;
    }
    NSLog(@"RNInCallManager.start() start InCallManager. media=%@, type=%@, mode=%@", _media, _media, _incallAudioMode);
    [self storeOriginalAudioSetup];
    _forceSpeakerOn = 0;
    _lastAudioDeviceStatus = nil;
    _sessionGeneration += 1;
    [self startAudioSessionNotification];
    [self audioSessionSetCategory:_incallAudioCategory
                          options:0
                       callerMemo:NSStringFromSelector(_cmd)];
    [self audioSessionSetMode:_incallAudioMode
                   callerMemo:NSStringFromSelector(_cmd)];
    [self audioSessionSetActive:YES
                        options:0
                     callerMemo:NSStringFromSelector(_cmd)];
    // --- after the category, mode and activation, where Apple's setPreferredInput documentation
    // --- puts input choices: a device chosen in an earlier call (the receiver's built-in mic, say)
    // --- must not keep this one off a connected headset or car.
    [self clearPreferredInput:@"start()"];

    if (ringbackUriType.length > 0) {
        NSLog(@"RNInCallManager.start() play ringback first. type=%@", ringbackUriType);
        [self startRingback:ringbackUriType];
    }

    if ([_media isEqualToString:@"audio"]) {
        [self startProximitySensor];
    }
    [self setKeepScreenOn:YES];
    _audioSessionInitialized = YES;
    //self.debugAudioSession()
}

RCT_EXPORT_METHOD(stop:(NSString *)busytoneUriType)
{
    if (!_audioSessionInitialized) {
        return;
    }

    [self stopRingback];

    if (busytoneUriType.length > 0 && [self startBusytone:busytoneUriType]) {
        // play busytone first, and call this func again when finish
        NSLog(@"RNInCallManager.stop(): play busytone before stop");
        return;
    } else {
        NSLog(@"RNInCallManager.stop(): stop InCallManager");
        [self answerPendingChoice];
        // --- the app's own audio after the call shouldn't inherit the call's device choice.
        [self clearPreferredInput:@"stop()"];
        [self restoreOriginalAudioSetup];
        [self stopBusytone];
        [self stopProximitySensor];
        [self audioSessionSetActive:NO
                            options:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                         callerMemo:NSStringFromSelector(_cmd)];
        [self setKeepScreenOn:NO];
        // --- route changes this teardown causes are handled after it, on this queue, and find
        // --- the observers gone.
        [self stopAudioSessionNotification];
        [[NSNotificationCenter defaultCenter] removeObserver:self];
        _sessionGeneration += 1;
        _audioSessionInitialized = NO;
    }
}

RCT_EXPORT_METHOD(turnScreenOn)
{
    NSLog(@"RNInCallManager.turnScreenOn(): ios doesn't support turnScreenOn()");
}

RCT_EXPORT_METHOD(turnScreenOff)
{
    NSLog(@"RNInCallManager.turnScreenOff(): ios doesn't support turnScreenOff()");
}

RCT_EXPORT_METHOD(setFlashOn:(BOOL)enable
                  brightness:(nonnull NSNumber *)brightness)
{
    if ([AVCaptureDevice class]) {
        AVCaptureDevice *device = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeVideo];
        if (device.hasTorch && device.position == AVCaptureDevicePositionBack) {
            @try {
                [device lockForConfiguration:nil];

                if (enable) {
                    [device setTorchMode:AVCaptureTorchModeOn];
                } else {
                    [device setTorchMode:AVCaptureTorchModeOff];
                }

                [device unlockForConfiguration];
            } @catch (NSException *e) {}
        }
    }
}

RCT_EXPORT_METHOD(setKeepScreenOn:(BOOL)enable)
{
    NSLog(@"RNInCallManager.setKeepScreenOn(): enable: %@", enable ? @"YES" : @"NO");
    dispatch_async(dispatch_get_main_queue(), ^{
        [[UIApplication sharedApplication] setIdleTimerDisabled:enable];
    });
}

RCT_EXPORT_METHOD(setSpeakerphoneOn:(BOOL)enable)
{
    BOOL success;
    NSError *error = nil;
    NSArray* routes = [_audioSession availableInputs];

    if(!enable){
        NSLog(@"Routing audio via Earpiece");
        @try {
            success = [_audioSession setCategory:AVAudioSessionCategoryPlayAndRecord error:&error];
            if (!success)  NSLog(@"Cannot set category due to error: %@", error);
            success = [_audioSession setMode:AVAudioSessionModeVoiceChat error:&error];
            if (!success)  NSLog(@"Cannot set mode due to error: %@", error);
            [_audioSession setPreferredOutputNumberOfChannels:0 error:nil];
            if (!success)  NSLog(@"Port override failed due to: %@", error);
            [_audioSession overrideOutputAudioPort:[AVAudioSessionPortBuiltInReceiver intValue] error:&error];
            success = [_audioSession setActive:YES error:&error];
            if (!success) NSLog(@"Audio session override failed: %@", error);
            else NSLog(@"AudioSession override is successful ");

        } @catch (NSException *e) {
            NSLog(@"Error occurred while routing audio via Earpiece: %@", e.reason);
        }
    } else {
        NSLog(@"Routing audio via Loudspeaker");
        @try {
            NSLog(@"Available routes: %@", routes[0]);
            success = [_audioSession setCategory:AVAudioSessionCategoryPlayAndRecord
                        withOptions:AVAudioSessionCategoryOptionDefaultToSpeaker
                        error:nil];
            if (!success)  NSLog(@"Cannot set category due to error: %@", error);
            success = [_audioSession setMode:AVAudioSessionModeVoiceChat error: &error];
            if (!success)  NSLog(@"Cannot set mode due to error: %@", error);
            [_audioSession setPreferredOutputNumberOfChannels:0 error:nil];
            [_audioSession overrideOutputAudioPort:[AVAudioSessionPortBuiltInSpeaker intValue] error: &error];
            if (!success)  NSLog(@"Port override failed due to: %@", error);
            success = [_audioSession setActive:YES error:&error];
            if (!success) NSLog(@"Audio session override failed: %@", error);
            else NSLog(@"AudioSession override is successful ");
        } @catch (NSException *e) {
            NSLog(@"Error occurred while routing audio via Loudspeaker: %@", e.reason);
        }
    }
}

RCT_EXPORT_METHOD(setForceSpeakerphoneOn:(int)flag)
{
    NSLog(@"RNInCallManager.setForceSpeakerphoneOn(): flag: %d", flag);
    [self applyForceSpeaker:flag caller:@"setForceSpeakerphoneOn()"];
    [self sendAudioDeviceChanged];
}

RCT_EXPORT_METHOD(setMicrophoneMute:(BOOL)enable)
{
    NSLog(@"RNInCallManager.setMicrophoneMute(): ios doesn't support setMicrophoneMute()");
}

RCT_EXPORT_METHOD(startRingback:(NSString *)_ringbackUriType)
{
    // you may rejected by apple when publish app if you use system sound instead of bundled sound.
    NSLog(@"RNInCallManager.startRingback(): type=%@", _ringbackUriType);

    @try {
        if (_ringback != nil) {
            if ([_ringback isPlaying]) {
                NSLog(@"RNInCallManager.startRingback(): is already playing");
                return;
            } else {
                [self stopRingback];
            }
        }
        // ios don't have embedded DTMF tone generator. use system dtmf sound files.
        NSString *ringbackUriType = [_ringbackUriType isEqualToString:@"_DTMF_"]
            ? @"_DEFAULT_"
            : _ringbackUriType;
        NSURL *ringbackUri = [self getRingbackUri:ringbackUriType];
        if (ringbackUri == nil) {
            NSLog(@"RNInCallManager.startRingback(): no available media");
            return;
        }
        //self.storeOriginalAudioSetup()
        _ringback = [[AVAudioPlayer alloc] initWithContentsOfURL:ringbackUri error:nil];
        _ringback.delegate = self;
        _ringback.numberOfLoops = -1; // you need to stop it explicitly
        [_ringback prepareToPlay];

        //self.audioSessionSetCategory(self.incallAudioCategory, [.DefaultToSpeaker, .AllowBluetooth], #function)
        [self audioSessionSetCategory:_incallAudioCategory
                              options:0
                           callerMemo:NSStringFromSelector(_cmd)];
        [self audioSessionSetMode:_incallAudioMode
                       callerMemo:NSStringFromSelector(_cmd)];
        [_ringback play];
    } @catch (NSException *e) {
        NSLog(@"RNInCallManager.startRingback(): caught error=%@", e.reason);
    }
}

RCT_EXPORT_METHOD(stopRingback)
{
    if (_ringback != nil) {
        NSLog(@"RNInCallManager.stopRingback()");
        [_ringback stop];
        _ringback = nil;
        // --- need to reset route based on config because WebRTC seems will switch audio mode automatically when call established.
        //[self updateAudioRoute];
    }
}

RCT_EXPORT_METHOD(startRingtone:(NSString *)ringtoneUriType
               ringtoneCategory:(NSString *)ringtoneCategory)
{
    // you may rejected by apple when publish app if you use system sound instead of bundled sound.
    NSLog(@"RNInCallManager.startRingtone(): type: %@", ringtoneUriType);
    @try {
        if (_ringtone != nil) {
            if ([_ringtone isPlaying]) {
                NSLog(@"RNInCallManager.startRingtone(): is already playing.");
                return;
            } else {
                [self stopRingtone];
            }
        }
        NSURL *ringtoneUri = [self getRingtoneUri:ringtoneUriType];
        if (ringtoneUri == nil) {
            NSLog(@"RNInCallManager.startRingtone(): no available media");
            return;
        }

        // --- ios has Ringer/Silent switch, so just play without check ringer volume.
        [self storeOriginalAudioSetup];
        _ringtone = [[AVAudioPlayer alloc] initWithContentsOfURL:ringtoneUri error:nil];
        _ringtone.delegate = self;
        _ringtone.numberOfLoops = -1; // you need to stop it explicitly
        [_ringtone prepareToPlay];

        // --- 1. if we use Playback, it can supports background playing (starting from foreground), but it would not obey Ring/Silent switch.
        // ---    make sure you have enabled 'audio' tag ( or 'voip' tag ) at XCode -> Capabilities -> BackgroundMode
        // --- 2. if we use SoloAmbient, it would obey Ring/Silent switch in the foreground, but does not support background playing,
        // ---    thus, then you should play ringtone again via local notification after back to home during a ring session.

        // we prefer 2. by default, since most of users doesn't want to interrupted by a ringtone if Silent mode is on.

        //self.audioSessionSetCategory(AVAudioSessionCategoryPlayback, [.DuckOthers], #function)
        if ([ringtoneCategory isEqualToString:@"playback"]) {
            [self audioSessionSetCategory:AVAudioSessionCategoryPlayback
                                  options:0
                               callerMemo:NSStringFromSelector(_cmd)];
        } else {
            [self audioSessionSetCategory:AVAudioSessionCategorySoloAmbient
                                  options:0
                               callerMemo:NSStringFromSelector(_cmd)];
        }
        [self audioSessionSetMode:AVAudioSessionModeDefault
                       callerMemo:NSStringFromSelector(_cmd)];
        //[self audioSessionSetActive:YES
        //                    options:nil
        //                 callerMemo:NSStringFromSelector(_cmd)];
        [_ringtone play];
    } @catch (NSException *e) {
        NSLog(@"RNInCallManager.startRingtone(): caught error = %@", e.reason);
    }
}

RCT_EXPORT_METHOD(stopRingtone)
{
    if (_ringtone != nil) {
        NSLog(@"RNInCallManager.stopRingtone()");
        [_ringtone stop];
        _ringtone = nil;
        [self restoreOriginalAudioSetup];
        [self audioSessionSetActive:NO
                            options:AVAudioSessionSetActiveOptionNotifyOthersOnDeactivation
                         callerMemo:NSStringFromSelector(_cmd)];
    }
}

RCT_EXPORT_METHOD(getAudioUriJS:(NSString *)audioType
                       fileType:(NSString *)fileType
                        resolve:(RCTPromiseResolveBlock)resolve
                         reject:(RCTPromiseRejectBlock)reject)
{
    NSURL *result = nil;
    if ([audioType isEqualToString:@"ringback"]) {
        result = [self getRingbackUri:fileType];
    } else if ([audioType isEqualToString:@"busytone"]) {
        result = [self getBusytoneUri:fileType];
    } else if ([audioType isEqualToString:@"ringtone"]) {
        result = [self getRingtoneUri:fileType];
    }
    if (result != nil) {
        if (result.absoluteString.length > 0) {
            resolve(result.absoluteString);
            return;
        }
    }
    reject(@"error_code", @"getAudioUriJS() failed", RCTErrorWithMessage(@"getAudioUriJS() failed"));
}

RCT_EXPORT_METHOD(getIsWiredHeadsetPluggedIn:(RCTPromiseResolveBlock)resolve
                                      reject:(RCTPromiseRejectBlock)reject)
{
    BOOL wiredHeadsetPluggedIn = [self isWiredHeadsetPluggedIn];
    resolve(wiredHeadsetPluggedIn ? @YES : @NO);
}

- (void)updateAudioRoute
{
    NSLog(@"RNInCallManager.updateAudioRoute(): [Enter] forceSpeakerOn flag=%d media=%@ category=%@ mode=%@", _forceSpeakerOn, _media, _audioSession.category, _audioSession.mode);
    //self.debugAudioSession()

    AVAudioSessionPortOverride overrideAudioPort;
    NSString *audioMode = @"";

    // --- WebRTC native code will change audio mode automatically when established.
    // --- It would have some race condition if we change audio mode with webrtc at the same time.
    // --- So we should not change audio mode as possible as we can. Only when default video call which wants to force speaker off.
    // --- audio: only override speaker on/off; video: should change category if needed and handle proximity sensor. ( because default proximity is off when video call )
    // --- During a call an audio call's mode is put back too, as a video call's is: WebRTC sets
    // --- voice chat as well, but callkeep's configureAudioSession sets mode Default on every
    // --- CallKit activation, and nothing else would restore it.
    if (_forceSpeakerOn == 1) {
        // --- force ON, override speaker only, keep audio mode remain.
        overrideAudioPort = AVAudioSessionPortOverrideSpeaker;
        if ([_media isEqualToString:@"video"]) {
            audioMode = AVAudioSessionModeVideoChat;
            [self stopProximitySensor];
        }
    } else if (_forceSpeakerOn == -1) {
        // --- force off
        overrideAudioPort = AVAudioSessionPortOverrideNone;
        if ([_media isEqualToString:@"video"]) {
            audioMode = AVAudioSessionModeVoiceChat;
            [self startProximitySensor];
        }
    } else { // use default behavior
        overrideAudioPort = AVAudioSessionPortOverrideNone;
        if ([_media isEqualToString:@"video"]) {
            audioMode = AVAudioSessionModeVideoChat;
            [self stopProximitySensor];
        }
    }
    if (audioMode.length == 0 && _audioSessionInitialized) {
        audioMode = _incallAudioMode;
    }

    // --- category and mode first: changing either is a route change that drops an output
    // --- override, so an override set before them would be lost and need re-applying.
    if (![_audioSession.category isEqualToString:_incallAudioCategory]) {
        [self audioSessionSetCategory:_incallAudioCategory
                              options:0
                           callerMemo:NSStringFromSelector(_cmd)];
        NSLog(@"RNInCallManager.updateAudioRoute() audio category has changed to %@", _incallAudioCategory);
    } else {
        NSLog(@"RNInCallManager.updateAudioRoute() did NOT change audio category");
    }

    if (audioMode.length > 0 && ![_audioSession.mode isEqualToString:audioMode]) {
        [self audioSessionSetMode:audioMode
                       callerMemo:NSStringFromSelector(_cmd)];
        NSLog(@"RNInCallManager.updateAudioRoute() audio mode has changed to %@", audioMode);
    } else {
        NSLog(@"RNInCallManager.updateAudioRoute() did NOT change audio mode");
    }

    BOOL isCurrentRouteToSpeaker = [self isCurrentOutputAudioRoute:@"SPEAKER_PHONE"];
    if ((overrideAudioPort == AVAudioSessionPortOverrideSpeaker && !isCurrentRouteToSpeaker)
            || (overrideAudioPort == AVAudioSessionPortOverrideNone && isCurrentRouteToSpeaker)) {
        // --- its route change (reason Override) moves the call to where the flag puts it, which
        // --- followRouteChange tells from someone else's override.
        [self overrideOutputAudioPort:overrideAudioPort caller:NSStringFromSelector(_cmd)];
    } else {
        NSLog(@"RNInCallManager.updateAudioRoute(): did NOT overrideOutputAudioPort()");
    }
    //self.debugAudioSession()
}

- (void)overrideOutputAudioPort:(AVAudioSessionPortOverride)port caller:(NSString *)caller
{
    NSString *name = port == AVAudioSessionPortOverrideSpeaker ? @".Speaker" : @".None";
    @try {
        NSError *error = nil;
        if ([_audioSession overrideOutputAudioPort:port error:&error]) {
            NSLog(@"RNInCallManager.%@: audioSession.overrideOutputAudioPort(%@) success", caller, name);
        } else {
            NSLog(@"RNInCallManager.%@: audioSession.overrideOutputAudioPort(%@) fail: %@", caller, name, error);
        }
    } @catch (NSException *e) {
        NSLog(@"RNInCallManager.%@: audioSession.overrideOutputAudioPort(%@) fail: %@", caller, name, e.reason);
    }
}

- (BOOL)checkAudioRoute:(NSArray<NSString *> *)targetPortTypeArray
              routeType:(NSString *)routeType
{
    AVAudioSessionRouteDescription *currentRoute = _audioSession.currentRoute;

    if (currentRoute != nil) {
        NSArray<AVAudioSessionPortDescription *> *routes = [routeType isEqualToString:@"input"]
            ? currentRoute.inputs
            : currentRoute.outputs;
        for (AVAudioSessionPortDescription *portDescription in routes) {
            if ([targetPortTypeArray containsObject:portDescription.portType]) {
                return YES;
            }
        }
    }
    return NO;
}

- (BOOL)startBusytone:(NSString *)_busytoneUriType
{
    // you may rejected by apple when publish app if you use system sound instead of bundled sound.
    NSLog(@"RNInCallManager.startBusytone(): type: %@", _busytoneUriType);
    @try {
        if (_busytone != nil) {
            if ([_busytone isPlaying]) {
                NSLog(@"RNInCallManager.startBusytone(): is already playing");
                return NO;
            } else {
                [self stopBusytone];
            }
        }

        // ios don't have embedded DTMF tone generator. use system dtmf sound files.
        NSString *busytoneUriType = [_busytoneUriType isEqualToString:@"_DTMF_"]
            ? @"_DEFAULT_"
            : _busytoneUriType;
        NSURL *busytoneUri = [self getBusytoneUri:busytoneUriType];
        if (busytoneUri == nil) {
            NSLog(@"RNInCallManager.startBusytone(): no available media");
            return NO;
        }
        //[self storeOriginalAudioSetup];
        _busytone = [[AVAudioPlayer alloc] initWithContentsOfURL:busytoneUri error:nil];
        _busytone.delegate = self;
        _busytone.numberOfLoops = 0; // it's part of start(), will stop at stop()
        [_busytone prepareToPlay];

        //self.audioSessionSetCategory(self.incallAudioCategory, [.DefaultToSpeaker, .AllowBluetooth], #function)
        [self audioSessionSetCategory:_incallAudioCategory
                              options:0
                           callerMemo:NSStringFromSelector(_cmd)];
        [self audioSessionSetMode:_incallAudioMode
                       callerMemo:NSStringFromSelector(_cmd)];
        [_busytone play];
    } @catch (NSException *e) {
        NSLog(@"RNInCallManager.startBusytone(): caught error = %@", e.reason);
        return NO;
    }
    return YES;
}

- (void)stopBusytone
{
    if (_busytone != nil) {
        NSLog(@"RNInCallManager.stopBusytone()");
        [_busytone stop];
        _busytone = nil;
    }
}

/** A wired headset (headphones, a headset with a mic, or USB audio, as for WIRED_HEADSET) is plugged in. */
- (BOOL)isWiredHeadsetPluggedIn
{
    NSArray<AVAudioSessionPort> *wired = [self portTypesForAudioRoute:@"WIRED_HEADSET"];
    if ([self checkAudioRoute:wired routeType:@"output"] || [self checkAudioRoute:wired routeType:@"input"]) {
        return YES;
    }
    // --- a headset mic can be available without carrying the call (under a forced speaker).
    for (AVAudioSessionPortDescription *input in _audioSession.availableInputs) {
        if ([wired containsObject:input.portType]) {
            return YES;
        }
    }
    return NO;
}

- (void)audioSessionSetCategory:(NSString *)audioCategory
                        options:(AVAudioSessionCategoryOptions)options
                     callerMemo:(NSString *)callerMemo
{
    @try {
        if (options != 0) {
            [_audioSession setCategory:audioCategory
                           withOptions:options
                                 error:nil];
        } else {
            [_audioSession setCategory:audioCategory
                                 error:nil];
        }
        NSLog(@"RNInCallManager.%@: audioSession.setCategory: %@, withOptions: %lu success", callerMemo, audioCategory, (unsigned long)options);
    } @catch (NSException *e) {
        NSLog(@"RNInCallManager.%@: audioSession.setCategory: %@, withOptions: %lu fail: %@", callerMemo, audioCategory, (unsigned long)options, e.reason);
    }
}

- (void)audioSessionSetMode:(NSString *)audioMode
                 callerMemo:(NSString *)callerMemo
{
    @try {
        [_audioSession setMode:audioMode error:nil];
        NSLog(@"RNInCallManager.%@: audioSession.setMode(%@) success", callerMemo, audioMode);
    } @catch (NSException *e) {
        NSLog(@"RNInCallManager.%@: audioSession.setMode(%@) fail: %@", callerMemo, audioMode, e.reason);
    }
}

- (void)audioSessionSetActive:(BOOL)audioActive
                   options:(AVAudioSessionSetActiveOptions)options
                   callerMemo:(NSString *)callerMemo
{
    @try {
        if (options != 0) {
            [_audioSession setActive:audioActive
                         withOptions:options
                               error:nil];
        } else {
            [_audioSession setActive:audioActive
                               error:nil];
        }
        NSLog(@"RNInCallManager.%@: audioSession.setActive(%@), withOptions: %lu success", callerMemo, audioActive ? @"YES" : @"NO", (unsigned long)options);
    } @catch (NSException *e) {
        NSLog(@"RNInCallManager.%@: audioSession.setActive(%@), withOptions: %lu fail: %@", callerMemo, audioActive ? @"YES" : @"NO", (unsigned long)options, e.reason);
    }
}

- (void)storeOriginalAudioSetup
{
    NSLog(@"RNInCallManager.storeOriginalAudioSetup(): origAudioCategory=%@, origAudioMode=%@", _audioSession.category, _audioSession.mode);
    _origAudioCategory = _audioSession.category;
    _origAudioMode = _audioSession.mode;
}

- (void)restoreOriginalAudioSetup
{
    NSLog(@"RNInCallManager.restoreOriginalAudioSetup(): origAudioCategory=%@, origAudioMode=%@", _audioSession.category, _audioSession.mode);
    [self audioSessionSetCategory:_origAudioCategory
                          options:0
                       callerMemo:NSStringFromSelector(_cmd)];
    [self audioSessionSetMode:_origAudioMode
                   callerMemo:NSStringFromSelector(_cmd)];
}

RCT_EXPORT_METHOD(startProximitySensor)
{
    if (_isProximityRegistered) {
        return;
    }

    NSLog(@"RNInCallManager.startProximitySensor()");
    UIDevice *device = _currentDevice;
    dispatch_async(dispatch_get_main_queue(), ^{
        device.proximityMonitoringEnabled = YES;
    });

    // --- in case it didn't deallocate when ViewDidUnload
    [self stopObserve:_proximityObserver
                 name:UIDeviceProximityStateDidChangeNotification
               object:nil];

    __weak RNInCallManager *weakSelf = self;
    _proximityObserver = [self startObserve:UIDeviceProximityStateDidChangeNotification
                                     object:_currentDevice
                                      queue: nil
                                      block:^(NSNotification *notification) {
        RNInCallManager *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        BOOL state = strongSelf->_currentDevice.proximityState;
        if (state != strongSelf->_proximityIsNear) {
            NSLog(@"RNInCallManager.UIDeviceProximityStateDidChangeNotification(): isNear: %@", state ? @"YES" : @"NO");
            strongSelf->_proximityIsNear = state;
            [strongSelf sendEventWithName:@"Proximity" body:@{@"isNear": state ? @YES : @NO}];
        }
    }];

    _isProximityRegistered = YES;
}

RCT_EXPORT_METHOD(stopProximitySensor)
{
    if (!_isProximityRegistered) {
        return;
    }

    NSLog(@"RNInCallManager.stopProximitySensor()");
    UIDevice *device = _currentDevice;
    dispatch_async(dispatch_get_main_queue(), ^{
        device.proximityMonitoringEnabled = NO;
    });

    // --- remove all no matter what object
    [self stopObserve:_proximityObserver
                 name:UIDeviceProximityStateDidChangeNotification
               object:nil];

    _isProximityRegistered = NO;
}

- (void)startAudioSessionNotification
{
    NSLog(@"RNInCallManager.startAudioSessionNotification() starting...");
    [self startAudioSessionInterruptionNotification];
    [self startAudioSessionRouteChangeNotification];
    [self startAudioSessionAvailableInputsChangeNotification];
    [self startAudioSessionMediaServicesWereLostNotification];
    [self startAudioSessionMediaServicesWereResetNotification];
    [self startAudioSessionSilenceSecondaryAudioHintNotification];
}

- (void)stopAudioSessionNotification
{
    NSLog(@"RNInCallManager.startAudioSessionNotification() stopping...");
    [self stopAudioSessionInterruptionNotification];
    [self stopAudioSessionRouteChangeNotification];
    [self stopAudioSessionAvailableInputsChangeNotification];
    [self stopAudioSessionMediaServicesWereLostNotification];
    [self stopAudioSessionMediaServicesWereResetNotification];
    [self stopAudioSessionSilenceSecondaryAudioHintNotification];
}

- (void)startAudioSessionInterruptionNotification
{
    if (_isAudioSessionInterruptionRegistered) {
        return;
    }
    NSLog(@"RNInCallManager.startAudioSessionInterruptionNotification()");

    // --- in case it didn't deallocate when ViewDidUnload
    [self stopObserve:_audioSessionInterruptionObserver
                 name:AVAudioSessionInterruptionNotification
               object:nil];

    _audioSessionInterruptionObserver = [self startObserve:AVAudioSessionInterruptionNotification
                                                    object:nil
                                                     queue:nil
                                                     block:^(NSNotification *notification) {
        if (notification.userInfo == nil
                || ![notification.name isEqualToString:AVAudioSessionInterruptionNotification]) {
            return;
        }

        //NSUInteger rawValue = notification.userInfo[AVAudioSessionInterruptionTypeKey].unsignedIntegerValue;
        NSNumber *interruptType = [notification.userInfo objectForKey:@"AVAudioSessionInterruptionTypeKey"];
        if ([interruptType unsignedIntegerValue] == AVAudioSessionInterruptionTypeBegan) {
            NSLog(@"RNInCallManager.AudioSessionInterruptionNotification: Began");
        } else if ([interruptType unsignedIntegerValue] == AVAudioSessionInterruptionTypeEnded) {
            NSLog(@"RNInCallManager.AudioSessionInterruptionNotification: Ended");
        } else {
            NSLog(@"RNInCallManager.AudioSessionInterruptionNotification: Unknow Value");
        }
        //NSLog(@"RNInCallManager.AudioSessionInterruptionNotification: could not resolve notification");
    }];

    _isAudioSessionInterruptionRegistered = YES;
}

- (void)stopAudioSessionInterruptionNotification
{
    if (!_isAudioSessionInterruptionRegistered) {
        return;
    }
    NSLog(@"RNInCallManager.stopAudioSessionInterruptionNotification()");
    // --- remove all no matter what object
    [self stopObserve:_audioSessionInterruptionObserver
                 name:AVAudioSessionInterruptionNotification
               object: nil];
    _isAudioSessionInterruptionRegistered = NO;
}

- (void)startAudioSessionRouteChangeNotification
{
        if (_isAudioSessionRouteChangeRegistered) {
            return;
        }

        NSLog(@"RNInCallManager.startAudioSessionRouteChangeNotification()");

        // --- in case it didn't deallocate when ViewDidUnload
        [self stopObserve:_audioSessionRouteChangeObserver
                     name: AVAudioSessionRouteChangeNotification
                   object: nil];

        __weak RNInCallManager *weakSelf = self;
        const NSUInteger generation = _sessionGeneration;
        _audioSessionRouteChangeObserver = [self startObserve:AVAudioSessionRouteChangeNotification
                                                       object: nil
                                                        queue: nil
                                                        block:^(NSNotification *notification) {
            RNInCallManager *strongSelf = weakSelf;
            if (strongSelf == nil || notification.userInfo == nil
                    || ![notification.name isEqualToString:AVAudioSessionRouteChangeNotification]) {
                return;
            }
            NSUInteger reason = [notification.userInfo[AVAudioSessionRouteChangeReasonKey] unsignedIntegerValue];
            id previousRoute = notification.userInfo[AVAudioSessionRouteChangePreviousRouteKey];
            // --- on the route queue, after whatever chooseAudioRoute, setForceSpeakerphoneOn, start
            // --- or stop is doing, so this samples the route they settled on.
            dispatch_async(strongSelf->_routeQueue, ^{
                [strongSelf handleRouteChange:reason
                                previousRoute:[previousRoute isKindOfClass:[AVAudioSessionRouteDescription class]] ? previousRoute : nil
                                   generation:generation];
            });
        }];

        _isAudioSessionRouteChangeRegistered = YES;
}

static NSString *RNInCallManagerRouteChangeReasonName(NSUInteger reason)
{
    switch (reason) {
        case AVAudioSessionRouteChangeReasonUnknown: return @"Unknown";
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable: return @"NewDeviceAvailable";
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: return @"OldDeviceUnavailable";
        case AVAudioSessionRouteChangeReasonCategoryChange: return @"CategoryChange";
        case AVAudioSessionRouteChangeReasonOverride: return @"Override";
        case AVAudioSessionRouteChangeReasonWakeFromSleep: return @"WakeFromSleep";
        case AVAudioSessionRouteChangeReasonNoSuitableRouteForCategory: return @"NoSuitableRouteForCategory";
        case AVAudioSessionRouteChangeReasonRouteConfigurationChange: return @"RouteConfigurationChange";
        default: return @"Unknow Value";
    }
}

- (void)handleRouteChange:(NSUInteger)reason
             previousRoute:(AVAudioSessionRouteDescription *)previousRoute
                generation:(NSUInteger)generation
{
    // --- queued by an ended call's observer (stop()'s own teardown posts route changes): that
    // --- call is over, whether or not the next one has started since.
    if (!_isAudioSessionRouteChangeRegistered || generation != _sessionGeneration) {
        return;
    }
    NSLog(@"RNInCallManager.AudioRouteChange.Reason: %@. category=%@ mode=%@ previous output=%@ output=%@",
          RNInCallManagerRouteChangeReasonName(reason), _audioSession.category, _audioSession.mode,
          previousRoute.outputs.firstObject.portType, _audioSession.currentRoute.outputs.firstObject.portType);
    [self sendWiredHeadsetForRouteChange:reason previousRoute:previousRoute];
    if (reason == AVAudioSessionRouteChangeReasonCategoryChange) {
        // --- someone else (WebRTC, CallKit) changed the category, which drops the speaker
        // --- override: put the forced route back.
        [self updateAudioRoute];
    } else {
        [self followRouteChange:reason previousRoute:previousRoute];
    }
    // --- reported after the re-apply, so a category change doesn't report the route it
    // --- momentarily fell back to.
    [self sendAudioDeviceChanged];
    if (_pendingChoiceResolve != nil && [self isCurrentOutputAudioRoute:_pendingChoiceRoute]) {
        [self answerPendingChoice];
    }
}

// --- 'WiredHeadset': a wired headset is what WIRED_HEADSET is (USB audio included).
- (void)sendWiredHeadsetForRouteChange:(NSUInteger)reason previousRoute:(AVAudioSessionRouteDescription *)previousRoute
{
    NSArray<AVAudioSessionPort> *wired = [self portTypesForAudioRoute:@"WIRED_HEADSET"];
    if (reason == AVAudioSessionRouteChangeReasonNewDeviceAvailable) {
        AVAudioSessionRouteDescription *route = _audioSession.currentRoute;
        for (AVAudioSessionPortDescription *input in route.inputs) {
            if ([wired containsObject:input.portType]) {
                [self sendEventWithName:@"WiredHeadset"
                                   body:@{@"isPlugged": @YES, @"hasMic": @YES, @"deviceName": input.portType}];
                return;
            }
        }
        for (AVAudioSessionPortDescription *output in route.outputs) {
            if ([wired containsObject:output.portType]) {
                [self sendEventWithName:@"WiredHeadset"
                                   body:@{@"isPlugged": @YES, @"hasMic": @NO, @"deviceName": output.portType}];
                return;
            }
        }
    } else if (reason == AVAudioSessionRouteChangeReasonOldDeviceUnavailable && ![self isWiredHeadsetPluggedIn]) {
        // --- only for a wired headset that left (the previous route had one, when iOS says).
        BOOL hadWired = previousRoute == nil;
        for (AVAudioSessionPortDescription *port in [previousRoute.inputs arrayByAddingObjectsFromArray:previousRoute.outputs ?: @[]]) {
            hadWired = hadWired || [wired containsObject:port.portType];
        }
        if (hadWired) {
            [self sendEventWithName:@"WiredHeadset" body:@{@"isPlugged": @NO, @"hasMic": @NO, @"deviceName": @""}];
        }
    }
}

- (void)stopAudioSessionRouteChangeNotification
{
    if (!_isAudioSessionRouteChangeRegistered) {
        return;
    }

    NSLog(@"RNInCallManager.stopAudioSessionRouteChangeNotification()");
    // --- remove all no matter what object
    [self stopObserve:_audioSessionRouteChangeObserver
                 name:AVAudioSessionRouteChangeNotification
               object:nil];
    _isAudioSessionRouteChangeRegistered = NO;
}

// --- iOS 26+: a device can become available without taking the route (a headset connecting
// --- while the receiver is pinned), which posts no route change. Earlier iOS has no such
// --- notification, and the list then catches up on the next route change.
- (void)startAudioSessionAvailableInputsChangeNotification
{
    if (_isAudioSessionAvailableInputsChangeRegistered) {
        return;
    }
    if (@available(iOS 26.0, *)) {
        NSLog(@"RNInCallManager.startAudioSessionAvailableInputsChangeNotification()");
        [self stopObserve:_audioSessionAvailableInputsChangeObserver
                     name:AVAudioSessionAvailableInputsChangeNotification
                   object:nil];
        __weak RNInCallManager *weakSelf = self;
        const NSUInteger generation = _sessionGeneration;
        _audioSessionAvailableInputsChangeObserver = [self startObserve:AVAudioSessionAvailableInputsChangeNotification
                                                                 object:nil
                                                                  queue:nil
                                                                  block:^(NSNotification *notification) {
            RNInCallManager *strongSelf = weakSelf;
            if (strongSelf == nil) {
                return;
            }
            dispatch_async(strongSelf->_routeQueue, ^{
                // --- queued by an ended call's observer: that call is over.
                if (strongSelf->_isAudioSessionAvailableInputsChangeRegistered
                        && generation == strongSelf->_sessionGeneration) {
                    [strongSelf sendAudioDeviceChanged];
                }
            });
        }];
        _isAudioSessionAvailableInputsChangeRegistered = YES;
    }
}

- (void)stopAudioSessionAvailableInputsChangeNotification
{
    if (!_isAudioSessionAvailableInputsChangeRegistered) {
        return;
    }
    if (@available(iOS 26.0, *)) {
        NSLog(@"RNInCallManager.stopAudioSessionAvailableInputsChangeNotification()");
        [self stopObserve:_audioSessionAvailableInputsChangeObserver
                     name:AVAudioSessionAvailableInputsChangeNotification
                   object:nil];
    }
    _isAudioSessionAvailableInputsChangeRegistered = NO;
}

- (void)startAudioSessionMediaServicesWereLostNotification
{
    if (_isAudioSessionMediaServicesWereLostRegistered) {
        return;
    }

    NSLog(@"RNInCallManager.startAudioSessionMediaServicesWereLostNotification()");

    // --- in case it didn't deallocate when ViewDidUnload
    [self stopObserve:_audioSessionMediaServicesWereLostObserver
                 name:AVAudioSessionMediaServicesWereLostNotification
               object:nil];

    _audioSessionMediaServicesWereLostObserver = [self startObserve:AVAudioSessionMediaServicesWereLostNotification
                                                             object:nil
                                                              queue:nil
                                                              block:^(NSNotification *notification) {
        // --- This notification has no userInfo dictionary.
        NSLog(@"RNInCallManager.AudioSessionMediaServicesWereLostNotification: Media Services Were Lost");
    }];

    _isAudioSessionMediaServicesWereLostRegistered = YES;
}

- (void)stopAudioSessionMediaServicesWereLostNotification
{
    if (!_isAudioSessionMediaServicesWereLostRegistered) {
        return;
    }

    NSLog(@"RNInCallManager.stopAudioSessionMediaServicesWereLostNotification()");

    // --- remove all no matter what object
    [self stopObserve:_audioSessionMediaServicesWereLostObserver
                 name:AVAudioSessionMediaServicesWereLostNotification
               object:nil];

    _isAudioSessionMediaServicesWereLostRegistered = NO;
}

- (void)startAudioSessionMediaServicesWereResetNotification
{
    if (_isAudioSessionMediaServicesWereResetRegistered) {
        return;
    }

    NSLog(@"RNInCallManager.startAudioSessionMediaServicesWereResetNotification()");

    // --- in case it didn't deallocate when ViewDidUnload
    [self stopObserve:_audioSessionMediaServicesWereResetObserver
                 name:AVAudioSessionMediaServicesWereResetNotification
               object:nil];

    __weak RNInCallManager *weakSelf = self;
    const NSUInteger generation = _sessionGeneration;
    _audioSessionMediaServicesWereResetObserver = [self startObserve:AVAudioSessionMediaServicesWereResetNotification
                                                              object:nil
                                                               queue:nil
                                                               block:^(NSNotification *notification) {
        // --- This notification has no userInfo dictionary.
        NSLog(@"RNInCallManager.AudioSessionMediaServicesWereResetNotification: Media Services Were Reset");
        RNInCallManager *strongSelf = weakSelf;
        if (strongSelf == nil) {
            return;
        }
        dispatch_async(strongSelf->_routeQueue, ^{
            [strongSelf mediaServicesWereReset:generation];
        });
    }];

    _isAudioSessionMediaServicesWereResetRegistered = YES;
}

/**
 * The media server restarted, and the session is back to its defaults (Technical Q&A QA1749):
 * set up the call's category, mode and activation again, then its route and chosen device.
 */
- (void)mediaServicesWereReset:(NSUInteger)generation
{
    // --- queued by an ended call's observer: that call is over, and the next one (if it has
    // --- started) set its session up after the reset.
    if (!_audioSessionInitialized || !_isAudioSessionMediaServicesWereResetRegistered
            || generation != _sessionGeneration) {
        return;
    }
    [self audioSessionSetCategory:_incallAudioCategory
                          options:0
                       callerMemo:NSStringFromSelector(_cmd)];
    [self audioSessionSetMode:_incallAudioMode
                   callerMemo:NSStringFromSelector(_cmd)];
    [self audioSessionSetActive:YES
                        options:0
                     callerMemo:NSStringFromSelector(_cmd)];
    [self updateAudioRoute];
    if (_chosenInputRoute != nil) {
        AVAudioSessionPortDescription *input = [self preferredInputForAudioRoute:_chosenInputRoute];
        NSError *error = nil;
        if (input == nil || ![_audioSession setPreferredInput:input error:&error]) {
            NSLog(@"RNInCallManager.mediaServicesWereReset(): %@ can't be chosen again: %@", _chosenInputRoute, error);
            _chosenInputRoute = nil;
        }
    }
    [self sendAudioDeviceChanged];
}

- (void)stopAudioSessionMediaServicesWereResetNotification
{
    if (!_isAudioSessionMediaServicesWereResetRegistered) {
        return;
    }

    NSLog(@"RNInCallManager.stopAudioSessionMediaServicesWereResetNotification()");

    // --- remove all no matter what object
    [self stopObserve:_audioSessionMediaServicesWereResetObserver
                 name:AVAudioSessionMediaServicesWereResetNotification
               object:nil];

    _isAudioSessionMediaServicesWereResetRegistered = NO;
}

- (void)startAudioSessionSilenceSecondaryAudioHintNotification
{
    if (_isAudioSessionSilenceSecondaryAudioHintRegistered) {
        return;
    }

    NSLog(@"RNInCallManager.startAudioSessionSilenceSecondaryAudioHintNotification()");

    // --- in case it didn't deallocate when ViewDidUnload
    [self stopObserve:_audioSessionSilenceSecondaryAudioHintObserver
                 name:AVAudioSessionSilenceSecondaryAudioHintNotification
               object:nil];

    _audioSessionSilenceSecondaryAudioHintObserver = [self startObserve:AVAudioSessionSilenceSecondaryAudioHintNotification
                                                                 object:nil
                                                                  queue:nil
                                                                  block:^(NSNotification *notification) {
        if (notification.userInfo == nil
                || ![notification.name isEqualToString:AVAudioSessionSilenceSecondaryAudioHintNotification]) {
            return;
        }

        NSNumber *silenceSecondaryAudioHintType = [notification.userInfo objectForKey:@"AVAudioSessionSilenceSecondaryAudioHintTypeKey"];
        NSUInteger silenceSecondaryAudioHintTypeValue = [silenceSecondaryAudioHintType unsignedIntegerValue];
        switch (silenceSecondaryAudioHintTypeValue) {
            case AVAudioSessionSilenceSecondaryAudioHintTypeBegin:
                NSLog(@"RNInCallManager.AVAudioSessionSilenceSecondaryAudioHintNotification: Begin");
                break;
            case AVAudioSessionSilenceSecondaryAudioHintTypeEnd:
                NSLog(@"RNInCallManager.AVAudioSessionSilenceSecondaryAudioHintNotification: End");
                break;
            default:
                NSLog(@"RNInCallManager.AVAudioSessionSilenceSecondaryAudioHintNotification: Unknow Value");
                break;
        }
    }];
    _isAudioSessionSilenceSecondaryAudioHintRegistered = YES;
}

- (void)stopAudioSessionSilenceSecondaryAudioHintNotification
{
    if (!_isAudioSessionSilenceSecondaryAudioHintRegistered) {
        return;
    }

    NSLog(@"RNInCallManager.stopAudioSessionSilenceSecondaryAudioHintNotification()");
    // --- remove all no matter what object
    [self stopObserve:_audioSessionSilenceSecondaryAudioHintObserver
                 name:AVAudioSessionSilenceSecondaryAudioHintNotification
               object:nil];

    _isAudioSessionSilenceSecondaryAudioHintRegistered = NO;
}

- (id)startObserve:(NSString *)name
            object:(id)object
             queue:(NSOperationQueue *)queue
             block:(void (^)(NSNotification *))block
{
    return [[NSNotificationCenter defaultCenter] addObserverForName:name
                                               object:object
                                                queue:queue
                                           usingBlock:block];
}

- (void)stopObserve:(id)observer
             name:(NSString *)name
           object:(id)object
{
    if (observer == nil) return;
    [[NSNotificationCenter defaultCenter] removeObserver:observer
                                                    name:name
                                                  object:object];
}

- (NSURL *)getRingbackUri:(NSString *)_type
{
    NSString *fileBundle = @"incallmanager_ringback";
    NSString *fileBundleExt = @"mp3";
    //NSString *fileSysWithExt = @"vc~ringing.caf"; // --- ringtone of facetime, but can't play it.
    //NSString *fileSysPath = @"/System/Library/Audio/UISounds";
    NSString *fileSysWithExt = @"Marimba.m4r";
    NSString *fileSysPath = @"/Library/Ringtones";

    // --- you can't get default user perfrence sound in ios
    NSString *type = [_type isEqualToString:@""] || [_type isEqualToString:@"_DEFAULT_"]
        ? fileSysWithExt
        : _type;

    NSURL *bundleUri = _bundleRingbackUri;
    NSURL *defaultUri = _defaultRingbackUri;

    NSURL *uri = [self getAudioUri:type
                        fileBundle:fileBundle
                     fileBundleExt:fileBundleExt
                    fileSysWithExt:fileSysWithExt
                       fileSysPath:fileSysPath
                         uriBundle:&bundleUri
                        uriDefault:&defaultUri];

    _bundleRingbackUri = bundleUri;
    _defaultRingbackUri = defaultUri;

    return uri;
}

- (NSURL *)getBusytoneUri:(NSString *)_type
{
    NSString *fileBundle = @"incallmanager_busytone";
    NSString *fileBundleExt = @"mp3";
    NSString *fileSysWithExt = @"ct-busy.caf"; //ct-congestion.caf
    NSString *fileSysPath = @"/System/Library/Audio/UISounds";
    // --- you can't get default user perfrence sound in ios
    NSString *type = [_type isEqualToString:@""] || [_type isEqualToString:@"_DEFAULT_"]
        ? fileSysWithExt
        : _type;

    NSURL *bundleUri = _bundleBusytoneUri;
    NSURL *defaultUri = _defaultBusytoneUri;

    NSURL *uri = [self getAudioUri:type
                        fileBundle:fileBundle
                     fileBundleExt:fileBundleExt
                    fileSysWithExt:fileSysWithExt
                       fileSysPath:fileSysPath
                         uriBundle:&bundleUri
                        uriDefault:&defaultUri];

    _bundleBusytoneUri = bundleUri;
    _defaultBusytoneUri = defaultUri;

    return uri;
}

- (NSURL *)getRingtoneUri:(NSString *)_type
{
    NSString *fileBundle = @"incallmanager_ringtone";
    NSString *fileBundleExt = @"mp3";
    NSString *fileSysWithExt = @"Opening.m4r"; //Marimba.m4r
    NSString *fileSysPath = @"/Library/Ringtones";
    // --- you can't get default user perfrence sound in ios
    NSString *type = [_type isEqualToString:@""] || [_type isEqualToString:@"_DEFAULT_"]
        ? fileSysWithExt
        : _type;

    NSURL *bundleUri = _bundleRingtoneUri;
    NSURL *defaultUri = _defaultRingtoneUri;

    NSURL *uri = [self getAudioUri:type
                        fileBundle:fileBundle
                     fileBundleExt:fileBundleExt
                    fileSysWithExt:fileSysWithExt
                       fileSysPath:fileSysPath
                         uriBundle:&bundleUri
                        uriDefault:&defaultUri];

    _bundleRingtoneUri = bundleUri;
    _defaultRingtoneUri = defaultUri;

    return uri;
}

- (NSURL *)getAudioUri:(NSString *)_type
            fileBundle:(NSString *)fileBundle
         fileBundleExt:(NSString *)fileBundleExt
        fileSysWithExt:(NSString *)fileSysWithExt
           fileSysPath:(NSString *)fileSysPath
             uriBundle:(NSURL **)uriBundle
            uriDefault:(NSURL **)uriDefault
{
    NSString *type = _type;
    if ([type isEqualToString:@"_BUNDLE_"]) {
        if (*uriBundle == nil) {
            *uriBundle = [[NSBundle mainBundle] URLForResource:fileBundle withExtension:fileBundleExt];
            if (*uriBundle == nil) {
                NSLog(@"RNInCallManager.getAudioUri(): %@.%@ not found in bundle.", fileBundle, fileBundleExt);
                type = fileSysWithExt;
            } else {
                return *uriBundle;
            }
        } else {
            return *uriBundle;
        }
    }

    if (*uriDefault == nil) {
        NSString *target = [NSString stringWithFormat:@"%@/%@", fileSysPath, type];
        *uriDefault = [self getSysFileUri:target];
    }
    return *uriDefault;
}

- (NSURL *)getSysFileUri:(NSString *)target
{
    NSURL *url = [[NSURL alloc] initFileURLWithPath:target isDirectory:NO];

    if (url != nil) {
        NSString *path = url.path;
        if (path != nil) {
            NSFileManager *fileManager = [[NSFileManager alloc] init];
            BOOL isTargetDirectory;
            if ([fileManager fileExistsAtPath:path isDirectory:&isTargetDirectory]) {
                if (!isTargetDirectory) {
                    return url;
                }
            }
        }
    }
    NSLog(@"RNInCallManager.getSysFileUri(): can not get url for %@", target);
    return nil;
}

#pragma mark - AVAudioPlayerDelegate

// --- this only called when all loop played. it means, an infinite (numberOfLoops = -1) loop will never into here.
- (void)audioPlayerDidFinishPlaying:(AVAudioPlayer *)player
                       successfully:(BOOL)flag
{
    NSString *filename = player.url.URLByDeletingPathExtension.lastPathComponent;
    NSLog(@"RNInCallManager.audioPlayerDidFinishPlaying(): finished playing: %@", filename);
    if ([filename isEqualToString:_bundleBusytoneUri.URLByDeletingPathExtension.lastPathComponent]
            || [filename isEqualToString:_defaultBusytoneUri.URLByDeletingPathExtension.lastPathComponent]) {
        //[self stopBusytone];
        NSLog(@"RNInCallManager.audioPlayerDidFinishPlaying(): busytone finished, invoke stop()");
        // --- the delegate runs on the main thread; stop() belongs on the method queue.
        dispatch_async(_routeQueue, ^{
            [self stop:@""];
        });
    }
}

- (void)audioPlayerDecodeErrorDidOccur:(AVAudioPlayer *)player
                                 error:(NSError *)error
{
    NSString *filename = player.url.URLByDeletingPathExtension.lastPathComponent;
    NSLog(@"RNInCallManager.audioPlayerDecodeErrorDidOccur(): player=%@, error=%@", filename, error.localizedDescription);
}

// --- Deprecated in iOS 8.0.
//- (void)audioPlayerBeginInterruption:(AVAudioPlayer *)player
//{
//}

// --- Deprecated in iOS 8.0.
//- (void)audioPlayerEndInterruption:(AVAudioPlayer *)player
//{
//}

//- (void)debugAudioSession
//{
//    let currentRoute: Dictionary <String,String> = ["input": self.audioSession.currentRoute.inputs[0].uid, "output": self.audioSession.currentRoute.outputs[0].uid]
//    var categoryOptions = ""
//    switch self.audioSession.categoryOptions {
//        case AVAudioSessionCategoryOptions.mixWithOthers:
//            categoryOptions = "MixWithOthers"
//        case AVAudioSessionCategoryOptions.duckOthers:
//            categoryOptions = "DuckOthers"
//        case AVAudioSessionCategoryOptions.allowBluetooth:
//            categoryOptions = "AllowBluetooth"
//        case AVAudioSessionCategoryOptions.defaultToSpeaker:
//            categoryOptions = "DefaultToSpeaker"
//        default:
//            categoryOptions = "unknow"
//    }
//    if #available(iOS 9, *) {
//        if categoryOptions == "unknow" && self.audioSession.categoryOptions == AVAudioSessionCategoryOptions.interruptSpokenAudioAndMixWithOthers {
//            categoryOptions = "InterruptSpokenAudioAndMixWithOthers"
//        }
//    }
//    self._checkRecordPermission()
//    let audioSessionProperties: Dictionary <String,Any> = [
//        "category": self.audioSession.category,
//        "categoryOptions": categoryOptions,
//        "mode": self.audioSession.mode,
//        //"inputAvailable": self.audioSession.inputAvailable,
//        "otherAudioPlaying": self.audioSession.isOtherAudioPlaying,
//        "recordPermission" : self.recordPermission,
//        //"availableInputs": self.audioSession.availableInputs,
//        //"preferredInput": self.audioSession.preferredInput,
//        //"inputDataSources": self.audioSession.inputDataSources,
//        //"inputDataSource": self.audioSession.inputDataSource,
//        //"outputDataSources": self.audioSession.outputDataSources,
//        //"outputDataSource": self.audioSession.outputDataSource,
//        "currentRoute": currentRoute,
//        "outputVolume": self.audioSession.outputVolume,
//        "inputGain": self.audioSession.inputGain,
//        "inputGainSettable": self.audioSession.isInputGainSettable,
//        "inputLatency": self.audioSession.inputLatency,
//        "outputLatency": self.audioSession.outputLatency,
//        "sampleRate": self.audioSession.sampleRate,
//        "preferredSampleRate": self.audioSession.preferredSampleRate,
//        "IOBufferDuration": self.audioSession.ioBufferDuration,
//        "preferredIOBufferDuration": self.audioSession.preferredIOBufferDuration,
//        "inputNumberOfChannels": self.audioSession.inputNumberOfChannels,
//        "maximumInputNumberOfChannels": self.audioSession.maximumInputNumberOfChannels,
//        "preferredInputNumberOfChannels": self.audioSession.preferredInputNumberOfChannels,
//        "outputNumberOfChannels": self.audioSession.outputNumberOfChannels,
//        "maximumOutputNumberOfChannels": self.audioSession.maximumOutputNumberOfChannels,
//        "preferredOutputNumberOfChannels": self.audioSession.preferredOutputNumberOfChannels
//    ]
//    /*
//    // --- Too noisy
//    if #available(iOS 8, *) {
//        //audioSessionProperties["secondaryAudioShouldBeSilencedHint"] = self.audioSession.secondaryAudioShouldBeSilencedHint
//    } else {
//        //audioSessionProperties["secondaryAudioShouldBeSilencedHint"] = "unknow"
//    }
//    if #available(iOS 9, *) {
//        //audioSessionProperties["availableCategories"] = self.audioSession.availableCategories
//        //audioSessionProperties["availableModes"] = self.audioSession.availableModes
//    }
//    */
//    NSLog("RNInCallManager.debugAudioSession(): ==========BEGIN==========")
//    // iterate over all keys
//    for (key, value) in audioSessionProperties {
//        NSLog("\(key) = \(value)")
//    }
//    NSLog("RNInCallManager.debugAudioSession(): ==========END==========")
//}

@end
