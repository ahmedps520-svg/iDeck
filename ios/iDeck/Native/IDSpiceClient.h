// iDeck — SPICE client: display, keyboard/mouse input and audio playback
// for the guest, via CocoaSpice (spice-gtk). The frame arrives as a Metal
// texture backed by the GPU work virglrenderer submitted (ANGLE/MoltenVK),
// and is drawn into an MTKView with no CPU copy.
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <MetalKit/MetalKit.h>

NS_ASSUME_NONNULL_BEGIN

@protocol IDSpiceClientDelegate <NSObject>
- (void)spiceClientDidConnect;
- (void)spiceClientDidDisconnect;
- (void)spiceClientDidFail:(NSString *)message;
- (void)spiceClientDisplaySizeChanged:(CGSize)size;
- (void)spiceClientAgentConnected:(BOOL)connected;
@end

typedef NS_OPTIONS(NSUInteger, IDMouseButton) {
    IDMouseButtonLeft = 1 << 0,
    IDMouseButtonMiddle = 1 << 1,
    IDMouseButtonRight = 1 << 2,
};

@interface IDSpiceClient : NSObject

@property (nonatomic, weak, nullable) id<IDSpiceClientDelegate> delegate;
@property (nonatomic, readonly) BOOL connected;
@property (nonatomic, readonly) CGSize displaySize;
@property (nonatomic) BOOL audioEnabled;

/// Starts the shared spice-glib main loop (idempotent).
+ (BOOL)startSpiceMain;

- (instancetype)init NS_UNAVAILABLE;
- (instancetype)initWithSocketPath:(NSString *)path NS_DESIGNATED_INITIALIZER;
- (BOOL)connect;
- (void)disconnect;

- (void)attachToView:(MTKView *)view NS_SWIFT_NAME(attach(to:));
- (void)detachFromView;
/// Asks the guest (spice-vdagent) to change resolution.
- (void)requestResolution:(CGSize)size NS_SWIFT_NAME(requestResolution(_:));

/// `usage` is a USB HID keyboard usage (UIKeyboardHIDUsage).
- (void)sendKeyUsage:(NSInteger)usage pressed:(BOOL)pressed NS_SWIFT_NAME(sendKeyUsage(_:pressed:));
- (void)releaseAllKeys;
/// Absolute position in guest display pixels (touch / pointer).
- (void)sendMouseAbsolute:(CGPoint)point buttons:(IDMouseButton)buttons NS_SWIFT_NAME(sendMouseAbsolute(_:buttons:));
/// Relative motion (captured mouse for games).
- (void)sendMouseRelative:(CGPoint)delta buttons:(IDMouseButton)buttons NS_SWIFT_NAME(sendMouseRelative(_:buttons:));
- (void)sendMouseButton:(IDMouseButton)button pressed:(BOOL)pressed buttons:(IDMouseButton)buttons NS_SWIFT_NAME(sendMouseButton(_:pressed:buttons:));
- (void)sendScroll:(CGFloat)dy buttons:(IDMouseButton)buttons NS_SWIFT_NAME(sendScroll(_:buttons:));
/// YES: relative (server) mouse mode for games; NO: absolute (client).
- (void)requestRelativeMouse:(BOOL)relative NS_SWIFT_NAME(requestRelativeMouse(_:));
@property (nonatomic, readonly) BOOL relativeMouseMode;

@end

/// PC XT (set 1) scancode for a USB HID keyboard usage, as spice-gtk expects
/// (E0-prefixed keys are returned as 0x100 | code). 0 if unmapped.
int IDScancodeForHIDUsage(NSInteger usage);

NS_ASSUME_NONNULL_END
