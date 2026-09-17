#import "LDZoomBridge.h"

@implementation LDZoomParticipant
@end

// Only the direct-download edition (LIVEDECK_ZOOM_SDK=1) links the Zoom SDK — it cannot run in the App Sandbox.
#if defined(LIVEDECK_ZOOM_SDK) && __has_include(<ZoomSDK/ZoomSDK.h>)
#import <ZoomSDK/ZoomSDK.h>

// ─── one video subscription ────────────────────────────────────────────────────────────────
@interface LDZoomVideoTarget : NSObject <ZoomSDKRendererDelegate>
@property (nonatomic, strong) ZoomSDKRenderer *renderer;
@property (nonatomic, copy) LDZoomVideoHandler handler;
@end

@implementation LDZoomVideoTarget
- (void)onSubscribedUserDataOn {}
- (void)onSubscribedUserDataOff {}
- (void)onSubscribedUserLeft {}
- (void)onRendererBeDestroyed { self.renderer = nil; }
- (void)onRawDataReceived:(ZoomSDKYUVRawDataI420 *)data {
    if (!data || !self.handler) return;
    const char *y = [data getYBuffer], *u = [data getUBuffer], *v = [data getVBuffer];
    int w = (int)[data getStreamWidth], h = (int)[data getStreamHeight];
    if (!y || !u || !v || w <= 0 || h <= 0) return;
    self.handler((const uint8_t *)y, (const uint8_t *)u, (const uint8_t *)v, w, h);
}
@end

// ─── bridge ────────────────────────────────────────────────────────────────────────────────
@interface LDZoomBridge () <ZoomSDKAuthDelegate, ZoomSDKMeetingServiceDelegate, ZoomSDKMeetingRecordDelegate,
                            ZoomSDKMeetingActionControllerDelegate, ZoomSDKAudioRawDataDelegate>
@property (nonatomic, readwrite) LDZoomState state;
@property (nonatomic, readwrite) BOOL rawDataAllowed;
@property (nonatomic, strong) NSMutableDictionary<NSString *, LDZoomVideoTarget *> *videoTargets;
@property (nonatomic, copy, nullable) LDZoomAudioHandler audioHandler;
@property (nonatomic, strong, nullable) ZoomSDKAudioRawDataHelper *audioHelper;
@property (nonatomic) BOOL initialized;
@end

@implementation LDZoomBridge

+ (instancetype)shared {
    static LDZoomBridge *s; static dispatch_once_t once;
    dispatch_once(&once, ^{ s = [[LDZoomBridge alloc] init]; });
    return s;
}

+ (BOOL)isSDKAvailable { return YES; }

- (instancetype)init {
    if ((self = [super init])) {
        _videoTargets = [NSMutableDictionary dictionary];
        _state = LDZoomStateIdle;
    }
    return self;
}

- (NSString *)sdkVersion { return [[ZoomSDK sharedSDK] getSDKVersionNumber] ?: @""; }

- (void)setStateAndNotify:(LDZoomState)state message:(NSString *)message {
    self.state = state;
    [self.delegate zoomStateChanged:state message:message ?: @""];
}

- (BOOL)ensureInitialized {
    if (self.initialized) return YES;
    ZoomSDK *sdk = [ZoomSDK sharedSDK];
    ZoomSDKInitParams *params = [[ZoomSDKInitParams alloc] init];
    params.needCustomizedUI = NO;      // Zoom's own meeting window gives the operator full meeting controls
    params.enableLog = YES;
    params.logFileSize = 5;
    params.zoomDomain = @"zoom.us";
    sdk.videoRawDataMode = ZoomSDKRawDataMemoryModeHeap;
    sdk.audioRawDataMode = ZoomSDKRawDataMemoryModeHeap;
    sdk.shareRawDataMode = ZoomSDKRawDataMemoryModeHeap;
    ZoomSDKError err = [sdk initSDKWithParams:params];
    if (err != ZoomSDKError_Success) {
        [self setStateAndNotify:LDZoomStateFailed message:[NSString stringWithFormat:@"Zoom SDK could not start (error %d).", (int)err]];
        return NO;
    }
    self.initialized = YES;
    return YES;
}

- (void)authorizeWithJWT:(NSString *)jwt {
    if (![self ensureInitialized]) return;
    ZoomSDKAuthService *auth = [[ZoomSDK sharedSDK] getAuthService];
    auth.delegate = self;
    if ([auth isAuthorized]) { [self setStateAndNotify:LDZoomStateReady message:@"Zoom is ready."]; return; }
    ZoomSDKAuthContext *ctx = [[ZoomSDKAuthContext alloc] init];
    ctx.jwtToken = jwt;
    ZoomSDKError err = [auth sdkAuth:ctx];
    if (err != ZoomSDKError_Success) {
        [self setStateAndNotify:LDZoomStateFailed message:[NSString stringWithFormat:@"Authorisation could not start (error %d).", (int)err]];
        return;
    }
    [self setStateAndNotify:LDZoomStateAuthorizing message:@"Authorising with Zoom…"];
}

- (void)onZoomSDKAuthReturn:(ZoomSDKAuthError)returnValue {
    if (returnValue == ZoomSDKAuthError_Success) {
        [self setStateAndNotify:LDZoomStateReady message:@"Zoom is ready."];
    } else {
        [self setStateAndNotify:LDZoomStateFailed message:[NSString stringWithFormat:@"Zoom rejected the SDK credentials (auth error %d). Check the SDK Key and Secret.", (int)returnValue]];
    }
}

- (void)onZoomAuthIdentityExpired {
    [self setStateAndNotify:LDZoomStateIdle message:@"The Zoom authorisation expired — authorise again."];
}

- (void)joinMeeting:(NSString *)meetingNumber password:(NSString *)password displayName:(NSString *)displayName
                zak:(NSString *)zak onBehalfToken:(NSString *)onBehalfToken {
    ZoomSDKMeetingService *ms = [[ZoomSDK sharedSDK] getMeetingService];
    if (!ms) { [self setStateAndNotify:LDZoomStateFailed message:@"Zoom meeting service unavailable."]; return; }
    ms.delegate = self;
    ZoomSDKJoinMeetingElements *p = [[ZoomSDKJoinMeetingElements alloc] init];
    p.userType = ZoomSDKUserType_WithoutLogin;
    p.meetingNumber = (long long)[meetingNumber longLongValue];
    p.password = password ?: @"";
    p.displayName = displayName.length ? displayName : @"LiveDeck Studio";
    p.isNoAudio = NO;
    p.isNoVideo = YES;
    // Meetings outside the SDK app's own Zoom account need user attribution (Zoom policy since March 2026)
    if (zak.length) p.zak = zak;
    if (onBehalfToken.length) p.onBehalfToken = onBehalfToken;
    ZoomSDKError err = [ms joinMeeting:p];
    if (err != ZoomSDKError_Success) {
        [self setStateAndNotify:LDZoomStateFailed message:[NSString stringWithFormat:@"Could not join (error %d).", (int)err]];
        return;
    }
    [self setStateAndNotify:LDZoomStateJoining message:@"Joining the meeting…"];
}

- (void)leaveMeeting {
    [self stopAudio];
    for (NSString *t in self.videoTargets.allKeys) [self unsubscribeVideo:t];
    ZoomSDKMeetingService *ms = [[ZoomSDK sharedSDK] getMeetingService];
    [[ms getRecordController] stopRawRecording];
    [ms leaveMeetingWithCmd:LeaveMeetingCmd_Leave];
}

- (void)onMeetingStatusChange:(ZoomSDKMeetingStatus)state meetingError:(ZoomSDKMeetingError)error EndReason:(EndMeetingReason)reason {
    ZoomSDKMeetingService *ms = [[ZoomSDK sharedSDK] getMeetingService];
    switch (state) {
        case ZoomSDKMeetingStatus_Connecting:
            [self setStateAndNotify:LDZoomStateJoining message:@"Connecting…"]; break;
        case ZoomSDKMeetingStatus_WaitingForHost:
            [self setStateAndNotify:LDZoomStateWaiting message:@"Waiting for the host to start the meeting."]; break;
        case ZoomSDKMeetingStatus_InWaitingRoom:
            [self setStateAndNotify:LDZoomStateWaiting message:@"In the waiting room — ask the host to admit “LiveDeck Studio”."]; break;
        case ZoomSDKMeetingStatus_InMeeting: {
            [ms getRecordController].delegate = self;
            [ms getMeetingActionController].delegate = self;
            [self setStateAndNotify:LDZoomStateInMeeting message:@"In the meeting."];
            [self requestRawData];
            [self.delegate zoomParticipantsChanged];
            break;
        }
        case ZoomSDKMeetingStatus_Ended:
            self.rawDataAllowed = NO;
            [self setStateAndNotify:LDZoomStateEnded message:@"The meeting has ended."]; break;
        case ZoomSDKMeetingStatus_Failed:
            [self setStateAndNotify:LDZoomStateFailed message:[NSString stringWithFormat:@"Could not join the meeting (error %d).", (int)error]]; break;
        default: break;
    }
}

- (void)requestRawData {
    ZoomSDKMeetingRecordController *rc = [[[ZoomSDK sharedSDK] getMeetingService] getRecordController];
    if (!rc) return;
    if ([rc canStartRawRecording] == ZoomSDKError_Success) {
        ZoomSDKError e = [rc startRawRecording];
        self.rawDataAllowed = (e == ZoomSDKError_Success);
        [self.delegate zoomRawDataChanged:self.rawDataAllowed
                                  message:self.rawDataAllowed ? @"Video and audio access granted." : [NSString stringWithFormat:@"Raw recording could not start (error %d).", (int)e]];
    } else {
        ZoomSDKError e = [rc requestLocalRecordingPrivilege];
        self.rawDataAllowed = NO;
        [self.delegate zoomRawDataChanged:NO
                                  message:e == ZoomSDKError_Success ? @"Asked the host for recording permission — the host must click Allow."
                                                                    : @"The host must make LiveDeck Studio a co-host or allow it to record, then press Request access."];
    }
}

- (void)onRecordPrivilegeChange:(BOOL)canRec {
    if (canRec) [self requestRawData];
    else {
        self.rawDataAllowed = NO;
        [self.delegate zoomRawDataChanged:NO message:@"The host removed recording permission."];
    }
}

- (void)onLocalRecordingPrivilegeRequestStatus:(ZoomSDKRequestLocalRecordingStatus)status {
    [self requestRawData];
}

- (void)onUserJoin:(NSArray *)array { [self.delegate zoomParticipantsChanged]; }
- (void)onUserLeft:(NSArray *)array { [self.delegate zoomParticipantsChanged]; }
- (void)onUserVideoStatusChange:(BOOL)videoOn UserID:(unsigned int)userID { [self.delegate zoomParticipantsChanged]; }

- (NSArray<LDZoomParticipant *> *)participants {
    ZoomSDKMeetingActionController *ac = [[[ZoomSDK sharedSDK] getMeetingService] getMeetingActionController];
    NSMutableArray *out = [NSMutableArray array];
    for (NSNumber *uid in [ac getParticipantsList] ?: @[]) {
        ZoomSDKUserInfo *info = [ac getUserByUserID:uid.unsignedIntValue];
        if (!info) continue;
        LDZoomParticipant *p = [[LDZoomParticipant alloc] init];
        p.userID = uid.unsignedIntValue;
        p.name = [info getUserName] ?: @"Participant";
        p.isMe = [info isMySelf];
        p.isHost = [info isHost];
        p.videoOn = [info isVideoOn];
        [out addObject:p];
    }
    return out;
}

- (NSString *)subscribeVideoForUser:(unsigned int)userID highQuality:(BOOL)highQuality handler:(LDZoomVideoHandler)handler error:(NSString **)error {
    if (!self.rawDataAllowed) { if (error) *error = @"Video access has not been granted by the host yet."; return nil; }
    ZoomSDKRawDataController *rdc = [[ZoomSDK sharedSDK] getRawDataController];
    ZoomSDKRenderer *renderer = nil;
    ZoomSDKError e = [rdc createRender:&renderer];
    if (e != ZoomSDKError_Success || !renderer) { if (error) *error = [NSString stringWithFormat:@"Could not create a video receiver (error %d).", (int)e]; return nil; }
    LDZoomVideoTarget *target = [[LDZoomVideoTarget alloc] init];
    target.renderer = renderer;
    target.handler = handler;
    renderer.delegate = target;
    [renderer setResolution:highQuality ? ZoomSDKResolution_1080P : ZoomSDKResolution_720P];
    e = [renderer subscribe:userID rawDataType:ZoomSDKRawDataType_Video];
    if (e != ZoomSDKError_Success) {
        [rdc destroyRender:renderer];
        if (error) *error = e == ZoomSDKError_NoLicense
            ? @"This Zoom SDK app has no raw data licence. Enable raw data for the app in the Zoom App Marketplace."
            : [NSString stringWithFormat:@"Could not receive this participant's video (error %d).", (int)e];
        return nil;
    }
    NSString *token = [[NSUUID UUID] UUIDString];
    self.videoTargets[token] = target;
    return token;
}

- (void)unsubscribeVideo:(NSString *)token {
    LDZoomVideoTarget *t = self.videoTargets[token];
    if (!t) return;
    [t.renderer unSubscribe];
    [[[ZoomSDK sharedSDK] getRawDataController] destroyRender:t.renderer];
    t.handler = nil;
    [self.videoTargets removeObjectForKey:token];
}

- (BOOL)startAudio:(LDZoomAudioHandler)handler error:(NSString **)error {
    self.audioHandler = handler;
    if (self.audioHelper) return YES;
    if (!self.rawDataAllowed) { if (error) *error = @"Audio access has not been granted by the host yet."; return NO; }
    ZoomSDKAudioRawDataHelper *helper = nil;
    ZoomSDKError e = [[[ZoomSDK sharedSDK] getRawDataController] getAudioRawDataHelper:&helper];
    if (e != ZoomSDKError_Success || !helper) { if (error) *error = [NSString stringWithFormat:@"Audio unavailable (error %d).", (int)e]; return NO; }
    helper.delegate = self;
    e = [helper subscribe];
    if (e != ZoomSDKError_Success) { if (error) *error = [NSString stringWithFormat:@"Could not receive meeting audio (error %d).", (int)e]; return NO; }
    self.audioHelper = helper;
    return YES;
}

- (void)stopAudio {
    [self.audioHelper unSubscribe];
    self.audioHelper.delegate = nil;
    self.audioHelper = nil;
    self.audioHandler = nil;
}

- (void)deliverAudio:(ZoomSDKAudioRawData *)data user:(unsigned int)userID {
    LDZoomAudioHandler h = self.audioHandler;
    if (!h || !data) return;
    const char *buf = [data getBuffer];
    int channels = MAX(1, (int)[data getChannelNum]);
    int frames = (int)[data getBufferLen] / (2 * channels);
    if (!buf || frames <= 0) return;
    h(userID, (const int16_t *)buf, frames, channels, (int)[data getSampleRate]);
}

- (void)onMixedAudioRawDataReceived:(ZoomSDKAudioRawData *)data { [self deliverAudio:data user:0]; }
- (void)onOneWayAudioRawDataReceived:(ZoomSDKAudioRawData *)data userID:(unsigned int)userID { [self deliverAudio:data user:userID]; }
- (void)onShareAudioRawDataReceived:(ZoomSDKAudioRawData *)data userID:(unsigned int)userID {}
- (void)onOneWayInterpreterAudioRawDataReceived:(ZoomSDKAudioRawData *)data strLanguageName:(NSString *)languageName {}

@end

#else
// ─── stub when the Zoom Meeting SDK is not part of the build ──────────────────────────────
@implementation LDZoomBridge
+ (instancetype)shared { static LDZoomBridge *s; static dispatch_once_t once; dispatch_once(&once, ^{ s = [[LDZoomBridge alloc] init]; }); return s; }
+ (BOOL)isSDKAvailable { return NO; }
- (LDZoomState)state { return LDZoomStateUnavailable; }
- (NSString *)sdkVersion { return @""; }
- (BOOL)rawDataAllowed { return NO; }
- (void)authorizeWithJWT:(NSString *)jwt { [self.delegate zoomStateChanged:LDZoomStateUnavailable message:@"The Zoom Meeting SDK is not included in this build."]; }
- (void)joinMeeting:(NSString *)meetingNumber password:(NSString *)password displayName:(NSString *)displayName zak:(NSString *)zak onBehalfToken:(NSString *)onBehalfToken { [self authorizeWithJWT:@""]; }
- (void)leaveMeeting {}
- (void)requestRawData {}
- (NSArray<LDZoomParticipant *> *)participants { return @[]; }
- (NSString *)subscribeVideoForUser:(unsigned int)userID highQuality:(BOOL)highQuality handler:(LDZoomVideoHandler)handler error:(NSString **)error {
    if (error) *error = @"The Zoom Meeting SDK is not included in this build."; return nil;
}
- (void)unsubscribeVideo:(NSString *)token {}
- (BOOL)startAudio:(LDZoomAudioHandler)handler error:(NSString **)error { if (error) *error = @"The Zoom Meeting SDK is not included in this build."; return NO; }
- (void)stopAudio {}
@end
#endif
