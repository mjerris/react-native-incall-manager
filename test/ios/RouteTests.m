// iOS route tests for RNInCallManager.m (run: bash test/ios/run.sh).
//
// Runs the real, unmodified RNInCallManager.m as a Mac Catalyst command-line binary against a FAKE
// AVAudioSession, so the devices, the route and the timing of route-change notifications are under
// each scenario's control. What is real: every line of RNInCallManager.m, GCD, NSNotificationCenter,
// the module's queue. What is modelled: the session's routing, from the iOS SDK headers:
// PlayAndRecord defaults to the receiver; VideoChat implies DefaultToSpeaker and AllowBluetoothHFP,
// VoiceChat implies AllowBluetoothHFP (AVAudioSessionTypes.h, the mode constants); an output
// override lasts until the route changes (AVAudioSession.h, overrideOutputAudioPort:); a category
// without input has no availableInputs; the preferred input picks the device (setPreferredInput:);
// iOS has no receiver override, so wired headphones keep the output whatever the input. Which
// reason iOS posts for a change, and when, is a scenario parameter, not a claim about iOS.
//
// Each scenario runs in its own process: `route-tests <scenario>` exits 0 when every check holds.
#import <Foundation/Foundation.h>
#import <AVFoundation/AVFoundation.h>
#import <UIKit/UIKit.h>
#import <objc/runtime.h>
#import <stdatomic.h>
#import "RNInCallManager.h"

#pragma clang diagnostic ignored "-Wdeprecated-declarations"

// ---------------------------------------------------------------- the module's methods
@interface RNInCallManager (Tests)
- (void)start:(NSString *)mediaType auto:(BOOL)_auto ringbackUriType:(NSString *)ringbackUriType;
- (void)stop:(NSString *)busytoneUriType;
- (void)setForceSpeakerphoneOn:(int)flag;
- (void)chooseAudioRoute:(NSString *)audioRoute resolve:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject;
- (void)getAudioDeviceStatus:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject;
- (void)getIsWiredHeadsetPluggedIn:(RCTPromiseResolveBlock)resolve reject:(RCTPromiseRejectBlock)reject;
@end

// ---------------------------------------------------------------- logging and checks
static atomic_int gSeq;
static atomic_int gFailures;
static void H(NSString *fmt, ...) NS_FORMAT_FUNCTION(1, 2);
static void H(NSString *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:ap];
    va_end(ap);
    fprintf(stderr, "#%03d %s\n", atomic_fetch_add(&gSeq, 1), msg.UTF8String);
    fflush(stderr);
}
#define CHECK(cond, ...) do { \
        if (cond) { H(@"  check ok: %@", [NSString stringWithFormat:__VA_ARGS__]); } \
        else { atomic_fetch_add(&gFailures, 1); H(@"  check failed: %@ (%s, line %d)", [NSString stringWithFormat:__VA_ARGS__], #cond, __LINE__); } \
    } while (0)
static NSString *json(id obj)
{
    if (obj == nil) return @"nil";
    if (![NSJSONSerialization isValidJSONObject:obj]) return [obj description];
    NSData *d = [NSJSONSerialization dataWithJSONObject:obj options:NSJSONWritingSortedKeys error:nil];
    return [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
}

// ---------------------------------------------------------------- React stubs
static NSMutableArray<NSDictionary *> *gEvents;
@implementation RCTEventEmitter
- (NSArray<NSString *> *)supportedEvents { return @[]; }
- (void)sendEventWithName:(NSString *)name body:(id)body
{
    H(@"EVENT %@ %@", name, json(body));
    @synchronized (gEvents) { [gEvents addObject:@{@"name": name, @"body": body ?: [NSNull null]}]; }
}
- (void)startObserving {}
- (void)stopObserving {}
- (void)invalidate {}
@end
NSError *RCTErrorWithMessage(NSString *message)
{
    return [NSError errorWithDomain:@"RCT" code:0 userInfo:@{NSLocalizedDescriptionKey: message}];
}
static NSArray<NSDictionary *> *eventsNamed(NSString *name)
{
    @synchronized (gEvents) { return [gEvents filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"name == %@", name]]; }
}
static void clearEvents(void)
{
    @synchronized (gEvents) { [gEvents removeAllObjects]; }
}

// ---------------------------------------------------------------- fake ports and routes
@interface FakePort : NSObject
@property (nonatomic, copy) NSString *portType;
@property (nonatomic, copy) NSString *portName;
@property (nonatomic, copy) NSString *UID;
@end
@implementation FakePort
- (NSString *)description { return self.portName; }
@end
static FakePort *Port(NSString *type, NSString *name)
{
    FakePort *p = [FakePort new];
    p.portType = type;
    p.portName = name;
    p.UID = name;
    return p;
}
// a subclass, so the module's isKindOfClass check on AVAudioSessionRouteChangePreviousRouteKey holds
@interface FakeRoute : AVAudioSessionRouteDescription
@property (nonatomic, copy) NSArray *fakeInputs;
@property (nonatomic, copy) NSArray *fakeOutputs;
@end
@implementation FakeRoute
- (NSArray *)inputs { return self.fakeInputs; }
- (NSArray *)outputs { return self.fakeOutputs; }
- (NSString *)description
{
    return [NSString stringWithFormat:@"%@ -> %@", [self.fakeInputs componentsJoinedByString:@","], [self.fakeOutputs componentsJoinedByString:@","]];
}
- (BOOL)isEqual:(id)o { return [o isKindOfClass:[FakeRoute class]] && [[self description] isEqualToString:[o description]]; }
- (NSUInteger)hash { return [[self description] hash]; }
@end

static FakePort *gBuiltInMic, *gReceiver, *gSpeaker, *gHeadsetMic, *gHeadphones, *gUSBIn, *gUSBOut, *gUSBMic,
    *gHFPIn, *gHFPOut, *gCarIn, *gCarOut, *gHDMI;
static dispatch_queue_t gNotifyQ;

static NSString *reasonName(NSUInteger r)
{
    switch (r) {
        case AVAudioSessionRouteChangeReasonUnknown: return @"Unknown";
        case AVAudioSessionRouteChangeReasonNewDeviceAvailable: return @"NewDeviceAvailable";
        case AVAudioSessionRouteChangeReasonOldDeviceUnavailable: return @"OldDeviceUnavailable";
        case AVAudioSessionRouteChangeReasonCategoryChange: return @"CategoryChange";
        case AVAudioSessionRouteChangeReasonOverride: return @"Override";
        case AVAudioSessionRouteChangeReasonRouteConfigurationChange: return @"RouteConfigurationChange";
    }
    return [NSString stringWithFormat:@"%lu", (unsigned long)r];
}
static NSString *shortName(NSString *s)
{
    return [[s stringByReplacingOccurrencesOfString:@"AVAudioSessionCategory" withString:@""]
            stringByReplacingOccurrencesOfString:@"AVAudioSessionMode" withString:@""];
}

// ---------------------------------------------------------------- fake session
@interface FakeSession : NSObject
@property (nonatomic, copy) NSString *category;
@property (nonatomic, copy) NSString *mode;
@property (nonatomic) NSUInteger categoryOptions;
@property (nonatomic) BOOL active;
@property (nonatomic) NSUInteger portOverride;
@property (nonatomic, strong) FakePort *preferredInput;
@property (nonatomic, strong) FakePort *systemSelected;   // the system route picker's / CallKit's choice
// the world: what is plugged in or connected
@property (nonatomic) BOOL wiredMic, wiredNoMic, usb, usbMicOnly, bt, car, hdmi;
// knobs
@property (nonatomic) BOOL failPreferredInput;            // setPreferredInput: with a port returns NO
@property (nonatomic) NSUInteger preferredInputReason;    // the reason posted for a change a preferred input causes
@property (nonatomic, copy) void (^onDeactivate)(void);   // runs inside setActive:NO (synchronous, AVAudioSession.h)
@property (nonatomic, strong) FakeRoute *lastRoute;
@property (nonatomic, strong) NSMutableArray<NSDictionary *> *pending; // route changes not yet posted
@property (nonatomic, strong) NSMutableArray<FakeRoute *> *history;    // every route the session went through
@end

@implementation FakeSession
- (instancetype)init
{
    if (self = [super init]) {
        _category = AVAudioSessionCategorySoloAmbient;
        _mode = AVAudioSessionModeDefault;
        _pending = [NSMutableArray array];
        _history = [NSMutableArray array];
        _preferredInputReason = AVAudioSessionRouteChangeReasonRouteConfigurationChange;
        _lastRoute = [self computeRoute];
    }
    return self;
}
- (BOOL)inputCapable
{
    return [_category isEqualToString:AVAudioSessionCategoryPlayAndRecord] || [_category isEqualToString:AVAudioSessionCategoryRecord];
}
- (BOOL)hfpAllowed
{
    return (_categoryOptions & AVAudioSessionCategoryOptionAllowBluetooth) || [_mode isEqualToString:AVAudioSessionModeVoiceChat]
        || [_mode isEqualToString:AVAudioSessionModeVideoChat];
}
- (NSArray *)_availableInputs
{
    if (![self inputCapable]) return @[];
    NSMutableArray *a = [NSMutableArray arrayWithObject:gBuiltInMic];
    if (_wiredMic) [a addObject:gHeadsetMic];
    if (_usb) [a addObject:gUSBIn];
    if (_usbMicOnly) [a addObject:gUSBMic];
    if ([self hfpAllowed]) {
        // the car is listed before the AirPods: the order is iOS's, not the module's
        if (_car) [a addObject:gCarIn];
        if (_bt) [a addObject:gHFPIn];
    }
    return a;
}
- (FakeRoute *)computeRoute
{
    FakeRoute *r = [FakeRoute new];
    BOOL wiredOut = _wiredMic || _wiredNoMic;
    if (![self inputCapable]) {
        r.fakeInputs = @[];
        r.fakeOutputs = @[wiredOut ? gHeadphones : _usb ? gUSBOut : gSpeaker];
        return r;
    }
    if (_portOverride == AVAudioSessionPortOverrideSpeaker) {
        r.fakeInputs = @[gBuiltInMic];
        r.fakeOutputs = @[gSpeaker];
        return r;
    }
    NSArray *avail = [self _availableInputs];
    FakePort *input;
    if (_systemSelected && [avail containsObject:_systemSelected]) {
        input = _systemSelected;
    } else if (_preferredInput && [avail containsObject:_preferredInput]) {
        input = _preferredInput;
    } else {
        input = _wiredMic ? gHeadsetMic : _usb ? gUSBIn : [avail containsObject:gHFPIn] ? gHFPIn
            : [avail containsObject:gCarIn] ? gCarIn : _usbMicOnly ? gUSBMic : gBuiltInMic;
    }
    FakePort *output;
    if (input == gHeadsetMic) output = gHeadphones;
    else if (input == gUSBIn) output = gUSBOut;
    else if (input == gHFPIn) output = gHFPOut;
    else if (input == gCarIn) output = gCarOut;
    else if (input == _systemSelected) output = gReceiver; // the picker's "iPhone"
    else {
        BOOL defaultToSpeaker = (_categoryOptions & AVAudioSessionCategoryOptionDefaultToSpeaker)
            || [_mode isEqualToString:AVAudioSessionModeVideoChat];
        // no receiver override: a wired or USB output keeps the call whatever the input
        output = wiredOut ? gHeadphones : _usb ? gUSBOut : _hdmi ? gHDMI : defaultToSpeaker ? gSpeaker : gReceiver;
    }
    r.fakeInputs = @[input];
    r.fakeOutputs = @[output];
    return r;
}
// with the lock held
- (void)changed:(NSUInteger)reason force:(BOOL)force
{
    FakeRoute *now = [self computeRoute];
    if (!force && [now isEqual:_lastRoute]) return;
    FakeRoute *prev = _lastRoute;
    _lastRoute = now;
    [_history addObject:now];
    [_pending addObject:@{@"reason": @(reason), @"prev": prev}];
    H(@"  (iOS) route change %@: %@ => %@ (queued)", reasonName(reason), prev, now);
}
- (void)postPending
{
    NSArray *items;
    @synchronized (self) {
        items = [_pending copy];
        [_pending removeAllObjects];
    }
    for (NSDictionary *n in items) {
        H(@"  (iOS) posting AVAudioSessionRouteChangeNotification reason=%@", reasonName([n[@"reason"] unsignedIntegerValue]));
        [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioSessionRouteChangeNotification
                                                            object:self
                                                          userInfo:@{AVAudioSessionRouteChangeReasonKey: n[@"reason"],
                                                                     AVAudioSessionRouteChangePreviousRouteKey: n[@"prev"]}];
    }
}
static NSError *FakeError(NSString *what)
{
    return [NSError errorWithDomain:NSOSStatusErrorDomain code:-50 userInfo:@{NSLocalizedDescriptionKey: what}];
}

// --- the AVAudioSession API RNInCallManager.m uses
- (NSString *)category { @synchronized (self) { return _category; } }
- (NSString *)mode { @synchronized (self) { return _mode; } }
- (NSUInteger)categoryOptions { @synchronized (self) { return _categoryOptions; } }
- (FakePort *)preferredInput { @synchronized (self) { return _preferredInput; } }
- (NSArray *)availableInputs { @synchronized (self) { return [self _availableInputs]; } }
- (FakeRoute *)currentRoute { @synchronized (self) { return [self computeRoute]; } }
- (BOOL)setCategory:(NSString *)category error:(NSError **)outError
{
    return [self setCategory:category withOptions:0 error:outError];
}
- (BOOL)setCategory:(NSString *)category withOptions:(NSUInteger)options error:(NSError **)outError
{
    @synchronized (self) {
        BOOL changedValue = ![category isEqualToString:_category] || options != _categoryOptions;
        H(@"AVAS setCategory(%@, options=%lu)", shortName(category), (unsigned long)options);
        _category = [category copy];
        _categoryOptions = options;
        if (changedValue) {
            _portOverride = AVAudioSessionPortOverrideNone; // a route change: drops an override
            [self changed:AVAudioSessionRouteChangeReasonCategoryChange force:YES];
        }
        return YES;
    }
}
- (BOOL)setMode:(NSString *)mode error:(NSError **)outError
{
    @synchronized (self) {
        H(@"AVAS setMode(%@)", shortName(mode));
        if (![mode isEqualToString:_mode]) {
            _mode = [mode copy];
            _portOverride = AVAudioSessionPortOverrideNone;
            [self changed:AVAudioSessionRouteChangeReasonCategoryChange force:NO];
        }
        return YES;
    }
}
- (BOOL)setActive:(BOOL)active error:(NSError **)outError
{
    return [self setActive:active withOptions:0 error:outError];
}
- (BOOL)setActive:(BOOL)active withOptions:(NSUInteger)options error:(NSError **)outError
{
    void (^hook)(void) = nil;
    @synchronized (self) {
        H(@"AVAS setActive(%@)", active ? @"YES" : @"NO");
        _active = active;
        if (!active) hook = _onDeactivate;
    }
    if (hook) hook(); // outside the lock
    return YES;
}
- (BOOL)overrideOutputAudioPort:(NSUInteger)port error:(NSError **)outError
{
    @synchronized (self) {
        H(@"AVAS overrideOutputAudioPort(%@)", port ? @"Speaker" : @"None");
        _portOverride = port;
        _systemSelected = nil;
        [self changed:AVAudioSessionRouteChangeReasonOverride force:NO];
        return YES;
    }
}
- (BOOL)setPreferredInput:(FakePort *)port error:(NSError **)outError
{
    @synchronized (self) {
        if (port != nil && _failPreferredInput) {
            H(@"AVAS setPreferredInput(%@) -> NO (knob failPreferredInput)", port);
            if (outError) *outError = FakeError(@"setPreferredInput failed");
            return NO;
        }
        H(@"AVAS setPreferredInput(%@)", port ?: @"nil");
        _preferredInput = port;
        if (port) _systemSelected = nil;
        [self changed:_preferredInputReason force:NO];
        return YES;
    }
}
- (BOOL)setPreferredOutputNumberOfChannels:(NSInteger)n error:(NSError **)outError { return YES; }

// --- the world outside the app
- (void)connect:(NSString *)what
{
    @synchronized (self) {
        H(@"(world) %@ connects", what);
        [self setValue:@YES forKey:what];
        _portOverride = AVAudioSessionPortOverrideNone; // a new headset takes the call off the speaker
        [self changed:AVAudioSessionRouteChangeReasonNewDeviceAvailable force:NO];
    }
}
- (void)disconnect:(NSString *)what
{
    @synchronized (self) {
        H(@"(world) %@ disconnects", what);
        [self setValue:@NO forKey:what];
        if ([_preferredInput isEqual:gHeadsetMic] || [_preferredInput isEqual:gHFPIn] || [_preferredInput isEqual:gCarIn]) {
            if (![[self _availableInputs] containsObject:_preferredInput]) _preferredInput = nil;
        }
        [self changed:AVAudioSessionRouteChangeReasonOldDeviceUnavailable force:YES];
    }
}
/** The system route picker or CallKit's route button: "speaker", "receiver" or "bt", posted with `reason`. */
- (void)systemPick:(NSString *)what reason:(NSUInteger)reason
{
    @synchronized (self) {
        H(@"(world) the system route picker / CallKit chooses %@, posted as %@", what, reasonName(reason));
        if ([what isEqualToString:@"speaker"]) {
            _portOverride = AVAudioSessionPortOverrideSpeaker;
        } else {
            _portOverride = AVAudioSessionPortOverrideNone;
            _systemSelected = [what isEqualToString:@"bt"] ? gHFPIn : gBuiltInMic;
        }
        [self changed:reason force:NO];
    }
}
/** Another component (WebRTC, callkeep) sets the category and mode: a CategoryChange. */
- (void)externalCategory:(NSString *)category options:(NSUInteger)options mode:(NSString *)mode
{
    @synchronized (self) {
        H(@"(world) another component sets %@ options=%lu mode=%@", shortName(category), (unsigned long)options, shortName(mode));
        _category = [category copy];
        _categoryOptions = options;
        _mode = [mode copy];
        _portOverride = AVAudioSessionPortOverrideNone;
        [self changed:AVAudioSessionRouteChangeReasonCategoryChange force:YES];
    }
}
/** mediaserverd restarts: the session is back to its defaults (QA1749), and the app is told. */
- (void)mediaServicesReset
{
    @synchronized (self) {
        H(@"(world) media services reset: the session is back to SoloAmbient/Default, inactive, no override, no preferred input");
        _category = AVAudioSessionCategorySoloAmbient;
        _mode = AVAudioSessionModeDefault;
        _categoryOptions = 0;
        _active = NO;
        _portOverride = AVAudioSessionPortOverrideNone;
        _preferredInput = nil;
        _systemSelected = nil;
        _lastRoute = [self computeRoute];
        [_pending removeAllObjects];
    }
    dispatch_sync(gNotifyQ, ^{
        [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioSessionMediaServicesWereLostNotification object:self];
        [[NSNotificationCenter defaultCenter] postNotificationName:AVAudioSessionMediaServicesWereResetNotification object:self];
    });
}
- (NSString *)state
{
    @synchronized (self) {
        return [NSString stringWithFormat:@"%@/%@ active=%d override=%@ preferredInput=%@ route %@", shortName(_category),
                shortName(_mode), _active, _portOverride ? @"Speaker" : @"None", _preferredInput ?: @"nil", [self computeRoute]];
    }
}
@end

static FakeSession *gFake;

// ---------------------------------------------------------------- swizzles
@implementation AVAudioSession (Tests)
+ (instancetype)tests_sharedInstance { return (id)gFake; }
@end
@implementation UIDevice (Tests)
- (UIUserInterfaceIdiom)tests_userInterfaceIdiom { return UIUserInterfaceIdiomPhone; }
- (void)tests_setProximityMonitoringEnabled:(BOOL)e {}
- (BOOL)tests_proximityState { return NO; }
@end
@implementation UIApplication (Tests)
+ (instancetype)tests_sharedApplication { return nil; }
@end
static void swizzleInstance(Class c, SEL a, SEL b)
{
    method_exchangeImplementations(class_getInstanceMethod(c, a), class_getInstanceMethod(c, b));
}
static void swizzleClass(Class c, SEL a, SEL b)
{
    method_exchangeImplementations(class_getClassMethod(c, a), class_getClassMethod(c, b));
}

// ---------------------------------------------------------------- scenario helpers
static RNInCallManager *gM;
static dispatch_queue_t routeQueue(void) { return [(id)gM methodQueue]; }
/** Runs `b` on the module's method queue, as React Native calls its methods, and waits. */
static void MQ(dispatch_block_t b) { dispatch_sync(routeQueue(), b); }
static void drain(void)
{
    dispatch_sync(gNotifyQ, ^{});
    dispatch_sync(routeQueue(), ^{});
}
/** Posts the queued route changes, and those the handlers cause, until quiet. */
static void deliver(void)
{
    for (int round = 0; round < 8; round++) {
        NSUInteger n;
        @synchronized (gFake) { n = gFake.pending.count; }
        if (n == 0) break;
        dispatch_sync(gNotifyQ, ^{ [gFake postPending]; });
        drain();
    }
    drain();
}
static void STEP(NSString *what) { H(@"===== %@", what); }
static int flag(void)
{
    __block int f = 0;
    MQ(^{ f = [[gM valueForKey:@"_forceSpeakerOn"] intValue]; });
    return f;
}
static NSString *output(void) { return [gFake.currentRoute.outputs.firstObject portName]; }
static void STATE(NSString *label)
{
    drain();
    H(@"STATE %@: %@ | flag=%d", label, [gFake state], flag());
}
static NSDictionary *status(void)
{
    __block NSDictionary *result = nil;
    MQ(^{
        [gM getAudioDeviceStatus:^(id r) { result = r; } reject:^(NSString *c, NSString *m, NSError *e) {}];
    });
    H(@"getAudioDeviceStatus -> %@", json(result));
    return result;
}
static NSArray *availableRoutes(void)
{
    NSString *list = status()[@"availableAudioDeviceList"];
    return [NSJSONSerialization JSONObjectWithData:[list dataUsingEncoding:NSUTF8StringEncoding] options:0 error:nil];
}
/** chooseAudioRoute(route), with the route changes it causes delivered; returns the status, or the rejection code. */
static id choose(NSString *route)
{
    __block id answer = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    MQ(^{
        [gM chooseAudioRoute:route
                     resolve:^(id result) { answer = result; H(@"chooseAudioRoute(%@) RESOLVED %@", route, json(result)); dispatch_semaphore_signal(done); }
                      reject:^(NSString *code, NSString *message, NSError *error) {
                          answer = code;
                          H(@"chooseAudioRoute(%@) REJECTED %@: %@", route, code, message);
                          dispatch_semaphore_signal(done);
                      }];
    });
    deliver();
    if (dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 3 * NSEC_PER_SEC)) != 0) {
        H(@"chooseAudioRoute(%@) NOT ANSWERED within 3 s", route);
    }
    deliver();
    return answer;
}
static void start(NSString *media) { MQ(^{ [gM start:media auto:YES ringbackUriType:@""]; }); deliver(); }
static void stop(void) { MQ(^{ [gM stop:@""]; }); deliver(); }
static void force(int f) { MQ(^{ [gM setForceSpeakerphoneOn:f]; }); deliver(); }

// ---------------------------------------------------------------- scenarios
// The system route picker or CallKit's speaker button moves the call off a forced speaker (a
// foreign Override): the flag follows, and the next category change keeps the receiver.
static void s_follows_foreign_override(void)
{
    STEP(@"start('audio'), speaker forced (flag 1)");
    start(@"audio");
    force(1);
    CHECK([output() isEqualToString:@"Speaker"], @"the call is on the speaker (%@)", output());
    STEP(@"CallKit's speaker button turns the speaker off (Override, not the module's)");
    [gFake systemPick:@"receiver" reason:AVAudioSessionRouteChangeReasonOverride];
    deliver();
    CHECK(flag() == -1, @"the flag follows to -1 (%d)", flag());
    STEP(@"callkeep or WebRTC sets the category (CategoryChange): the re-apply keeps the receiver");
    [gFake externalCategory:AVAudioSessionCategoryPlayAndRecord options:0x24 mode:AVAudioSessionModeVoiceChat];
    deliver();
    CHECK([output() isEqualToString:@"Receiver"], @"the call stays on the receiver (%@)", output());
}

// A route change posted to the ended call's observer while its stop() runs, with the next call's
// start() already queued behind that stop(), is that ended call's: it is dropped, so call B hears no
// 'WiredHeadset' event for a headset that left before it started.
static void s_stale_route_change_after_restart(void)
{
    STEP(@"call A: a wired headset with a mic is plugged in; start('audio')");
    gFake.wiredMic = YES;
    start(@"audio");
    STEP(@"JS calls stop() and start() back to back; during stop()'s setActive:NO the headset is pulled out, and iOS posts that to call A's observer");
    dispatch_semaphore_t queued = dispatch_semaphore_create(0);
    gFake.onDeactivate = ^{
        dispatch_semaphore_wait(queued, DISPATCH_TIME_FOREVER); // call B's start() is queued behind this stop()
        [gFake disconnect:@"wiredMic"];
        dispatch_sync(gNotifyQ, ^{ [gFake postPending]; });
    };
    dispatch_async(routeQueue(), ^{ [gM stop:@""]; });
    dispatch_async(routeQueue(), ^{ clearEvents(); H(@"(call B) start('audio')"); [gM start:@"audio" auto:YES ringbackUriType:@""]; });
    dispatch_semaphore_signal(queued);
    drain();
    gFake.onDeactivate = nil;
    deliver();
    STATE(@"call B");
    CHECK(eventsNamed(@"WiredHeadset").count == 0, @"call B hears nothing of call A's route changes (%@)", json(eventsNamed(@"WiredHeadset")));
    CHECK(flag() == 0, @"call B's flag is its own (%d)", flag());
}

// The basics: choices resolve once the call is on them, the list, and EARPIECE refused (and not
// listed) while a wired headset is plugged in.
static void s_choices(void)
{
    STEP(@"AirPods connected; start('audio')");
    gFake.bt = YES;
    start(@"audio");
    NSDictionary *answer = choose(@"BLUETOOTH");
    CHECK([answer[@"selectedAudioDevice"] isEqualToString:@"BLUETOOTH"] && [output() isEqualToString:@"AirPods"],
          @"BLUETOOTH resolves on the AirPods (%@, %@)", json(answer), output());
    answer = choose(@"EARPIECE");
    CHECK([answer[@"selectedAudioDevice"] isEqualToString:@"EARPIECE"] && [output() isEqualToString:@"Receiver"],
          @"EARPIECE resolves on the receiver (%@)", output());
    answer = choose(@"SPEAKER_PHONE");
    CHECK([answer[@"selectedAudioDevice"] isEqualToString:@"SPEAKER_PHONE"] && flag() == 1, @"SPEAKER_PHONE forces the speaker");
    CHECK([availableRoutes() isEqual:(@[@"EARPIECE", @"SPEAKER_PHONE", @"BLUETOOTH"])], @"the list");
    STEP(@"a wired headset with a mic is plugged in");
    [gFake connect:@"wiredMic"];
    deliver();
    CHECK(![availableRoutes() containsObject:@"EARPIECE"], @"EARPIECE isn't listed (%@)", availableRoutes());
    CHECK([choose(@"EARPIECE") isEqual:@"E_AUDIO_ROUTE_UNAVAILABLE"], @"EARPIECE is refused");
    CHECK([choose(@"NOT_A_ROUTE") isEqual:@"E_AUDIO_ROUTE_UNAVAILABLE"], @"an unknown route is refused");
    stop();
    CHECK([choose(@"SPEAKER_PHONE") isEqual:@"E_AUDIO_ROUTE_INACTIVE"], @"a choice after stop() is refused");
}

/** The outputs the session went through since `mark` (an index into its history). */
static NSArray<NSString *> *outputsSince(NSUInteger mark)
{
    @synchronized (gFake) {
        NSArray *routes = [gFake.history subarrayWithRange:NSMakeRange(mark, gFake.history.count - mark)];
        return [routes valueForKeyPath:@"fakeOutputs.@unionOfArrays.portName"];
    }
}
static NSUInteger historyMark(void) { @synchronized (gFake) { return gFake.history.count; } }

// A video call on the earpiece (flag -1, the built-in mic pinned) moves to the AirPods without
// passing through the loudspeaker: the device is pinned before video chat mode (DefaultToSpeaker) is set.
static void s_video_earpiece_to_bluetooth(void)
{
    STEP(@"AirPods connected; start('video'); chooseAudioRoute('EARPIECE')");
    gFake.bt = YES;
    start(@"video");
    choose(@"EARPIECE");
    CHECK([output() isEqualToString:@"Receiver"] && flag() == -1, @"on the receiver, flag -1 (%@, %d)", output(), flag());
    STEP(@"chooseAudioRoute('BLUETOOTH')");
    NSUInteger mark = historyMark();
    NSDictionary *answer = choose(@"BLUETOOTH");
    CHECK([answer[@"selectedAudioDevice"] isEqualToString:@"BLUETOOTH"], @"resolves BLUETOOTH (%@)", json(answer));
    CHECK(![outputsSince(mark) containsObject:@"Speaker"], @"the call never went through the speaker (outputs: %@)", outputsSince(mark));
    CHECK(flag() == 0, @"flag 0 (%d)", flag());
}

// AVAudioSession refuses the preferred input: the choice is rejected E_AUDIO_ROUTE and the module's
// setting is as it was (the flag, the mode, the speaker override).
static void s_refused_pin_changes_nothing(void)
{
    STEP(@"audio call on the forced speaker, AirPods connected; setPreferredInput will fail");
    gFake.bt = YES;
    start(@"audio");
    choose(@"SPEAKER_PHONE");
    gFake.failPreferredInput = YES;
    CHECK([choose(@"BLUETOOTH") isEqual:@"E_AUDIO_ROUTE"], @"BLUETOOTH is rejected E_AUDIO_ROUTE");
    CHECK(flag() == 1 && [output() isEqualToString:@"Speaker"], @"still flag 1 on the speaker (%d, %@)", flag(), output());
    STEP(@"a video call on its default speaker (flag 0); EARPIECE refused the same way");
    gFake.failPreferredInput = NO;
    stop();
    gFake.bt = NO;
    start(@"video");
    gFake.failPreferredInput = YES;
    CHECK([choose(@"EARPIECE") isEqual:@"E_AUDIO_ROUTE"], @"EARPIECE is rejected E_AUDIO_ROUTE");
    CHECK(flag() == 0 && [gFake.mode isEqualToString:AVAudioSessionModeVideoChat] && [output() isEqualToString:@"Speaker"],
          @"still flag 0, video chat mode, on the speaker (%d, %@, %@)", flag(), shortName(gFake.mode), output());
}

// With flag 1 outliving the speaker (an HDMI output took the call: a device change, so the flag is
// kept), a refused choice leaves the call where it is instead of putting a speaker override back.
static void s_refused_choice_keeps_hdmi(void)
{
    STEP(@"audio call, speaker forced; an HDMI adapter takes the output");
    start(@"audio");
    force(1);
    [gFake connect:@"hdmi"];
    deliver();
    CHECK([output() isEqualToString:@"HDMI"] && flag() == 1, @"on HDMI, flag still 1 (%@, %d)", output(), flag());
    STEP(@"chooseAudioRoute('WIRED_HEADSET') with no headset");
    CHECK([choose(@"WIRED_HEADSET") isEqual:@"E_AUDIO_ROUTE_UNAVAILABLE"], @"refused");
    CHECK([output() isEqualToString:@"HDMI"], @"the call stays on HDMI (%@)", output());
}

// Two Bluetooth inputs (a car listed first, the AirPods carrying the call): choosing BLUETOOTH keeps
// the AirPods, and a media services reset pins the AirPods again, not the first of the route.
static void s_choice_keeps_the_device(void)
{
    STEP(@"the car and the AirPods are connected; the call is on the AirPods");
    gFake.car = YES;
    gFake.bt = YES;
    start(@"audio");
    CHECK([output() isEqualToString:@"AirPods"], @"on the AirPods (%@)", output());
    NSDictionary *answer = choose(@"BLUETOOTH");
    CHECK([output() isEqualToString:@"AirPods"] && [answer[@"selectedAudioDeviceName"] isEqualToString:@"AirPods"],
          @"BLUETOOTH keeps the AirPods (%@, %@)", output(), json(answer));
    STEP(@"media services reset");
    [gFake mediaServicesReset];
    deliver();
    CHECK([gFake.preferredInput isEqual:gHFPIn] && [output() isEqualToString:@"AirPods"],
          @"the AirPods are pinned again (%@, %@)", gFake.preferredInput, output());
}

static BOOL wiredPluggedIn(void)
{
    __block BOOL plugged = NO;
    MQ(^{ [gM getIsWiredHeadsetPluggedIn:^(id r) { plugged = [r boolValue]; } reject:^(NSString *c, NSString *m, NSError *e) {}]; });
    return plugged;
}

// Mic-less wired headphones under a forced speaker: no input shows them and the speaker has the
// output, but they are still plugged in, so EARPIECE isn't listed or accepted and WIRED_HEADSET is;
// pulling them out is a 'WiredHeadset' isPlugged:false, and EARPIECE is back.
static void s_headphones_under_speaker(void)
{
    STEP(@"start('audio'); mic-less headphones are plugged in (they take the call); then the speaker is forced");
    start(@"audio");
    [gFake connect:@"wiredNoMic"];
    deliver();
    CHECK([output() isEqualToString:@"Headphones"], @"on the headphones (%@)", output());
    force(1);
    CHECK([output() isEqualToString:@"Speaker"], @"on the speaker (%@)", output());
    NSArray *routes = availableRoutes();
    CHECK(![routes containsObject:@"EARPIECE"] && [routes containsObject:@"WIRED_HEADSET"], @"WIRED_HEADSET listed, EARPIECE not (%@)", routes);
    CHECK(wiredPluggedIn(), @"getIsWiredHeadsetPluggedIn() is true");
    CHECK([choose(@"EARPIECE") isEqual:@"E_AUDIO_ROUTE_UNAVAILABLE"], @"EARPIECE is refused");
    CHECK(flag() == 1 && [output() isEqualToString:@"Speaker"], @"and the speaker kept (%d, %@)", flag(), output());
    NSDictionary *answer = choose(@"WIRED_HEADSET");
    CHECK([answer[@"selectedAudioDevice"] isEqualToString:@"WIRED_HEADSET"], @"WIRED_HEADSET resolves on the headphones (%@)", json(answer));
    STEP(@"speaker forced again; the headphones are pulled out (the previous route shows only the speaker)");
    force(1);
    clearEvents();
    [gFake disconnect:@"wiredNoMic"];
    deliver();
    NSArray *events = eventsNamed(@"WiredHeadset");
    CHECK(events.count == 1 && [events.firstObject[@"body"][@"isPlugged"] isEqual:@NO], @"one 'WiredHeadset' isPlugged:false (%@)", json(events));
    routes = availableRoutes();
    CHECK([routes containsObject:@"EARPIECE"] && ![routes containsObject:@"WIRED_HEADSET"], @"EARPIECE listed again (%@)", routes);
    CHECK(!wiredPluggedIn(), @"getIsWiredHeadsetPluggedIn() is false");
}

// An input-only USB-C microphone leaves the output on the receiver: EARPIECE stays available.
static void s_usb_microphone(void)
{
    STEP(@"start('audio') on the receiver; a USB-C microphone (no output) is plugged in");
    start(@"audio");
    force(-1);
    [gFake connect:@"usbMicOnly"];
    deliver();
    CHECK([output() isEqualToString:@"Receiver"], @"the output stays on the receiver (%@)", output());
    CHECK(!wiredPluggedIn(), @"getIsWiredHeadsetPluggedIn() is false");
    force(1);
    CHECK([availableRoutes() containsObject:@"EARPIECE"], @"on the speaker, EARPIECE is listed (%@)", availableRoutes());
    NSDictionary *answer = choose(@"EARPIECE");
    CHECK([answer isKindOfClass:[NSDictionary class]] && [answer[@"selectedAudioDevice"] isEqualToString:@"EARPIECE"],
          @"EARPIECE is accepted and lands (%@)", json(answer));
}

// EarPods (with a mic) plugged in while an earpiece choice pins the built-in mic: the route is
// built-in mic -> headphones, but the headset has a mic, and the event says so.
static void s_headset_mic_under_earpiece_pin(void)
{
    STEP(@"start('audio'); chooseAudioRoute('EARPIECE') pins the built-in mic; EarPods are plugged in");
    start(@"audio");
    choose(@"EARPIECE");
    clearEvents();
    [gFake connect:@"wiredMic"];
    deliver();
    NSArray *events = eventsNamed(@"WiredHeadset");
    CHECK(events.count >= 1 && [events.firstObject[@"body"][@"isPlugged"] isEqual:@YES] && [events.firstObject[@"body"][@"hasMic"] isEqual:@YES],
          @"'WiredHeadset' isPlugged:true hasMic:true (%@)", json(events));
    CHECK([output() isEqualToString:@"Headphones"], @"on the headset (%@)", output());
}

// ---------------------------------------------------------------- main
int main(int argc, char **argv)
{
    @autoreleasepool {
        NSDictionary<NSString *, dispatch_block_t> *scenarios = @{
            @"choices": ^{ s_choices(); },
            @"choice-keeps-the-device": ^{ s_choice_keeps_the_device(); },
            @"refused-choice-keeps-hdmi": ^{ s_refused_choice_keeps_hdmi(); },
            @"refused-pin-changes-nothing": ^{ s_refused_pin_changes_nothing(); },
            @"video-earpiece-to-bluetooth": ^{ s_video_earpiece_to_bluetooth(); },
            @"follows-foreign-override": ^{ s_follows_foreign_override(); },
            @"headphones-under-speaker": ^{ s_headphones_under_speaker(); },
            @"headset-mic-under-earpiece-pin": ^{ s_headset_mic_under_earpiece_pin(); },
            @"usb-microphone": ^{ s_usb_microphone(); },
            @"stale-route-change-after-restart": ^{ s_stale_route_change_after_restart(); },
        };
        NSString *scenario = argc > 1 ? @(argv[1]) : @"";
        if ([scenario isEqualToString:@"--list"]) {
            for (NSString *name in [scenarios.allKeys sortedArrayUsingSelector:@selector(compare:)]) printf("%s\n", name.UTF8String);
            return 0;
        }
        dispatch_block_t run = scenarios[scenario];
        if (run == nil) {
            fprintf(stderr, "unknown scenario '%s' (--list names them)\n", scenario.UTF8String);
            return 2;
        }

        gBuiltInMic = Port(AVAudioSessionPortBuiltInMic, @"iPhone Microphone");
        gReceiver = Port(AVAudioSessionPortBuiltInReceiver, @"Receiver");
        gSpeaker = Port(AVAudioSessionPortBuiltInSpeaker, @"Speaker");
        gHeadsetMic = Port(AVAudioSessionPortHeadsetMic, @"Headset Microphone");
        gHeadphones = Port(AVAudioSessionPortHeadphones, @"Headphones");
        gUSBIn = Port(AVAudioSessionPortUSBAudio, @"USB-C Earbuds");
        gUSBOut = Port(AVAudioSessionPortUSBAudio, @"USB-C Earbuds");
        gUSBMic = Port(AVAudioSessionPortUSBAudio, @"USB-C Microphone");
        gHFPIn = Port(AVAudioSessionPortBluetoothHFP, @"AirPods");
        gHFPOut = Port(AVAudioSessionPortBluetoothHFP, @"AirPods");
        gCarIn = Port(AVAudioSessionPortCarAudio, @"Car");
        gCarOut = Port(AVAudioSessionPortCarAudio, @"Car");
        gHDMI = Port(AVAudioSessionPortHDMI, @"HDMI");
        gNotifyQ = dispatch_queue_create("tests.notify", DISPATCH_QUEUE_SERIAL);
        gEvents = [NSMutableArray array];
        gFake = [FakeSession new];

        swizzleClass([AVAudioSession class], @selector(sharedInstance), @selector(tests_sharedInstance));
        swizzleClass([UIApplication class], @selector(sharedApplication), @selector(tests_sharedApplication));
        swizzleInstance([UIDevice class], @selector(userInterfaceIdiom), @selector(tests_userInterfaceIdiom));
        swizzleInstance([UIDevice class], @selector(setProximityMonitoringEnabled:), @selector(tests_setProximityMonitoringEnabled:));
        swizzleInstance([UIDevice class], @selector(proximityState), @selector(tests_proximityState));

        H(@"scenario %@", scenario);
        dispatch_async(dispatch_queue_create("tests.js", DISPATCH_QUEUE_SERIAL), ^{
            gM = [[RNInCallManager alloc] init];
            MQ(^{ [gM startObserving]; }); // a NativeEventEmitter listener is subscribed
            run();
            int failures = atomic_load(&gFailures);
            H(@"%@ %@ (%d failed checks)", failures == 0 ? @"PASS" : @"FAIL", scenario, failures);
            exit(failures == 0 ? 0 : 1);
        });
        dispatch_main();
    }
    return 0;
}
