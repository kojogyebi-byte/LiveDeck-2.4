// LiveDeck ↔ Zoom Meeting SDK for macOS.
// This header has no Zoom types, so Swift can always see it. LDZoomBridge.m talks to ZoomSDK.framework when
// it is present at build time (AppStore/Vendor/ZoomSDK); otherwise it compiles to a stub that reports "not installed".
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, LDZoomState) {
    LDZoomStateUnavailable = 0,   // SDK not in this build
    LDZoomStateIdle,              // SDK loaded, not authorised yet
    LDZoomStateAuthorizing,
    LDZoomStateReady,             // authorised, can join
    LDZoomStateJoining,
    LDZoomStateWaiting,           // waiting room / waiting for host
    LDZoomStateInMeeting,
    LDZoomStateEnded,
    LDZoomStateFailed
};

@interface LDZoomParticipant : NSObject
@property (nonatomic) unsigned int userID;
@property (nonatomic, copy) NSString *name;
@property (nonatomic) BOOL isMe;
@property (nonatomic) BOOL isHost;
@property (nonatomic) BOOL videoOn;
@end

@protocol LDZoomBridgeDelegate <NSObject>
- (void)zoomStateChanged:(LDZoomState)state message:(NSString *)message;
- (void)zoomParticipantsChanged;
- (void)zoomRawDataChanged:(BOOL)allowed message:(NSString *)message;
@end

/// Planar I420 frame; pointers are valid only during the call.
typedef void (^LDZoomVideoHandler)(const uint8_t *y, const uint8_t *u, const uint8_t *v, int width, int height);
/// 16-bit PCM, interleaved; userID 0 = mixed meeting audio. Valid only during the call.
typedef void (^LDZoomAudioHandler)(unsigned int userID, const int16_t *pcm, int frames, int channels, int sampleRate);

@interface LDZoomBridge : NSObject

+ (instancetype)shared;
+ (BOOL)isSDKAvailable;

@property (nonatomic, weak, nullable) id<LDZoomBridgeDelegate> delegate;
@property (nonatomic, readonly) LDZoomState state;
@property (nonatomic, readonly, copy) NSString *sdkVersion;
@property (nonatomic, readonly) BOOL rawDataAllowed;

- (void)authorizeWithJWT:(NSString *)jwt;
/// zak / onBehalfToken: needed for meetings hosted outside the Zoom account that owns the SDK app (empty otherwise).
- (void)joinMeeting:(NSString *)meetingNumber password:(NSString *)password displayName:(NSString *)displayName
                zak:(NSString *)zak onBehalfToken:(NSString *)onBehalfToken;
- (void)leaveMeeting;

/// Asks for raw video/audio access: starts raw recording if allowed, otherwise asks the host for local recording permission.
- (void)requestRawData;

- (NSArray<LDZoomParticipant *> *)participants;

/// Returns a token for unsubscribing, or nil (error explains why).
- (nullable NSString *)subscribeVideoForUser:(unsigned int)userID highQuality:(BOOL)highQuality
                                     handler:(LDZoomVideoHandler)handler error:(NSString * _Nullable * _Nullable)error;
- (void)unsubscribeVideo:(NSString *)token;

/// Audio for all subscribers (mixed and per participant) arrives through one handler.
- (BOOL)startAudio:(LDZoomAudioHandler)handler error:(NSString * _Nullable * _Nullable)error;
- (void)stopAudio;

@end

NS_ASSUME_NONNULL_END
