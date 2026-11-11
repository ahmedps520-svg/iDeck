#import "IDSpiceClient.h"

// The no-USB product of CocoaSpice (the one UTM links on iOS) is a symlinked
// copy of the CocoaSpice target, so its module is named CocoaSpiceNoUsb.
@import CocoaSpiceNoUsb;

@interface IDSpiceClient () <CSConnectionDelegate>
@property (nonatomic, strong) CSConnection *connection;
@property (nonatomic, strong, nullable) CSDisplay *display;
@property (nonatomic, strong, nullable) CSInput *input;
@property (nonatomic, strong, nullable) CSMetalRenderer *renderer;
@property (nonatomic, weak, nullable) MTKView *view;
@property (nonatomic, readwrite) BOOL connected;
@property (nonatomic, readwrite) BOOL relativeMouseMode;
@end

@implementation IDSpiceClient

+ (BOOL)startSpiceMain {
    static BOOL started = NO;
    if (!started) started = [CSMain.sharedInstance spiceStart];
    return started;
}

- (instancetype)initWithSocketPath:(NSString *)path {
    if (self = [super init]) {
        _connection = [[CSConnection alloc] initWithUnixSocketFile:[NSURL fileURLWithPath:path]];
        _connection.delegate = self;
        _connection.audioEnabled = YES;
        _audioEnabled = YES;
    }
    return self;
}

- (void)setAudioEnabled:(BOOL)audioEnabled {
    _audioEnabled = audioEnabled;
    self.connection.audioEnabled = audioEnabled;
}

- (BOOL)connect {
    if (![IDSpiceClient startSpiceMain]) return NO;
    return [self.connection connect];
}

- (void)disconnect {
    [self detachFromView];
    [self.connection disconnect];
}

- (CGSize)displaySize {
    return self.display ? self.display.displaySize : CGSizeZero;
}

#pragma mark - Rendering

- (void)attachToView:(MTKView *)view {
    if (self.view == view && self.renderer) return;
    [self detachFromView];
    view.device = view.device ?: MTLCreateSystemDefaultDevice();
    view.colorPixelFormat = MTLPixelFormatBGRA8Unorm;
    view.clearColor = MTLClearColorMake(0.04, 0.04, 0.05, 1.0);
    // Present on display refresh (ProMotion up to 120 Hz); CocoaSpice only
    // draws when the guest delivered a new frame.
    view.preferredFramesPerSecond = 120;
    self.renderer = [[CSMetalRenderer alloc] initWithMetalKitView:view];
    [self.renderer changeUpscaler:MTLSamplerMinMagFilterLinear downscaler:MTLSamplerMinMagFilterLinear];
    view.delegate = self.renderer;
    self.view = view;
    if (self.display) [self.display addRenderer:self.renderer];
    [self updateViewport];
}

- (void)detachFromView {
    if (self.renderer && self.display) [self.display removeRenderer:self.renderer];
    if (self.view) self.view.delegate = nil;
    self.renderer = nil;
    self.view = nil;
}

- (void)updateViewport {
    if (!self.renderer || !self.view || !self.display) return;
    CGSize drawable = self.view.drawableSize;
    CGSize guest = self.display.displaySize;
    if (guest.width <= 0 || guest.height <= 0 || drawable.width <= 0) return;
    // Aspect-fit the guest framebuffer into the view, centred.
    CGFloat scale = MIN(drawable.width / guest.width, drawable.height / guest.height);
    self.renderer.viewportScale = scale;
    self.renderer.viewportOrigin = CGPointZero;
}

- (void)requestResolution:(CGSize)size {
    if (!self.display) return;
    [self.display requestResolution:CGRectMake(0, 0, size.width, size.height)];
}

#pragma mark - Input

static CSInputButton CSButtons(IDMouseButton b) {
    CSInputButton m = kCSInputButtonNone;
    if (b & IDMouseButtonLeft) m |= kCSInputButtonLeft;
    if (b & IDMouseButtonMiddle) m |= kCSInputButtonMiddle;
    if (b & IDMouseButtonRight) m |= kCSInputButtonRight;
    return m;
}

- (void)sendKeyUsage:(NSInteger)usage pressed:(BOOL)pressed {
    int code = IDScancodeForHIDUsage(usage);
    if (!code || !self.input) return;
    if (usage == 0x48) {  // Pause has its own sequence
        [self.input sendPause:pressed ? kCSInputKeyPress : kCSInputKeyRelease];
        return;
    }
    [self.input sendKey:pressed ? kCSInputKeyPress : kCSInputKeyRelease code:code];
}

- (void)releaseAllKeys {
    [self.input releaseKeys];
}

- (void)sendMouseAbsolute:(CGPoint)point buttons:(IDMouseButton)buttons {
    [self.input sendMousePosition:CSButtons(buttons) absolutePoint:point];
}

- (void)sendMouseRelative:(CGPoint)delta buttons:(IDMouseButton)buttons {
    [self.input sendMouseMotion:CSButtons(buttons) relativePoint:delta];
}

- (void)sendMouseButton:(IDMouseButton)button pressed:(BOOL)pressed buttons:(IDMouseButton)buttons {
    [self.input sendMouseButton:CSButtons(button) mask:CSButtons(buttons) pressed:pressed];
}

- (void)sendScroll:(CGFloat)dy buttons:(IDMouseButton)buttons {
    [self.input sendMouseScroll:kCSInputScrollSmooth buttonMask:CSButtons(buttons) dy:dy];
}

- (void)requestRelativeMouse:(BOOL)relative {
    self.relativeMouseMode = relative;
    [self.input requestMouseMode:relative];
}

#pragma mark - CSConnectionDelegate (called on the SPICE thread)

- (void)onMain:(dispatch_block_t)block {
    dispatch_async(dispatch_get_main_queue(), block);
}

- (void)spiceConnected:(CSConnection *)connection {
    [self onMain:^{
        self.connected = YES;
        [self.delegate spiceClientDidConnect];
    }];
}

- (void)spiceDisconnected:(CSConnection *)connection {
    [self onMain:^{
        self.connected = NO;
        self.display = nil;
        self.input = nil;
        [self.delegate spiceClientDidDisconnect];
    }];
}

- (void)spiceError:(CSConnection *)connection code:(CSConnectionError)code message:(NSString *)message {
    NSString *m = message ?: [NSString stringWithFormat:@"SPICE error %ld", (long)code];
    [self onMain:^{
        [self.delegate spiceClientDidFail:m];
    }];
}

- (void)spiceInputAvailable:(CSConnection *)connection input:(CSInput *)input {
    [self onMain:^{
        self.input = input;
        if (self.relativeMouseMode) [input requestMouseMode:YES];
    }];
}

- (void)spiceInputUnavailable:(CSConnection *)connection input:(CSInput *)input {
    [self onMain:^{
        if (self.input == input) self.input = nil;
    }];
}

- (void)spiceDisplayCreated:(CSConnection *)connection display:(CSDisplay *)display {
    [self onMain:^{
        if (!display.isPrimaryDisplay) return;
        self.display = display;
        if (self.renderer) [display addRenderer:self.renderer];
        [self updateViewport];
        [self.delegate spiceClientDisplaySizeChanged:display.displaySize];
    }];
}

- (void)spiceDisplayUpdated:(CSConnection *)connection display:(CSDisplay *)display {
    [self onMain:^{
        if (display != self.display) return;
        [self updateViewport];
        [self.delegate spiceClientDisplaySizeChanged:display.displaySize];
    }];
}

- (void)spiceDisplayDestroyed:(CSConnection *)connection display:(CSDisplay *)display {
    [self onMain:^{
        if (display != self.display) return;
        if (self.renderer) [display removeRenderer:self.renderer];
        self.display = nil;
    }];
}

- (void)spiceAgentConnected:(CSConnection *)connection supportingFeatures:(CSConnectionAgentFeature)features {
    [self onMain:^{
        [self.delegate spiceClientAgentConnected:YES];
    }];
}

- (void)spiceAgentDisconnected:(CSConnection *)connection {
    [self onMain:^{
        [self.delegate spiceClientAgentConnected:NO];
    }];
}

- (void)spiceForwardedPortOpened:(CSConnection *)connection port:(CSPort *)port {
}

- (void)spiceForwardedPortClosed:(CSConnection *)connection port:(CSPort *)port {
}

@end

#pragma mark - HID usage -> PC XT scancode

int IDScancodeForHIDUsage(NSInteger usage) {
    // USB HID Usage Tables, Keyboard page (0x07) -> scancode set 1.
    static const uint16_t table[0xE8] = {
        [0x04] = 0x1E, [0x05] = 0x30, [0x06] = 0x2E, [0x07] = 0x20, [0x08] = 0x12, [0x09] = 0x21, // a-f
        [0x0A] = 0x22, [0x0B] = 0x23, [0x0C] = 0x17, [0x0D] = 0x24, [0x0E] = 0x25, [0x0F] = 0x26, // g-l
        [0x10] = 0x32, [0x11] = 0x31, [0x12] = 0x18, [0x13] = 0x19, [0x14] = 0x10, [0x15] = 0x13, // m-r
        [0x16] = 0x1F, [0x17] = 0x14, [0x18] = 0x16, [0x19] = 0x2F, [0x1A] = 0x11, [0x1B] = 0x2D, // s-x
        [0x1C] = 0x15, [0x1D] = 0x2C,                                                             // y z
        [0x1E] = 0x02, [0x1F] = 0x03, [0x20] = 0x04, [0x21] = 0x05, [0x22] = 0x06, [0x23] = 0x07, // 1-6
        [0x24] = 0x08, [0x25] = 0x09, [0x26] = 0x0A, [0x27] = 0x0B,                               // 7-0
        [0x28] = 0x1C, [0x29] = 0x01, [0x2A] = 0x0E, [0x2B] = 0x0F, [0x2C] = 0x39,                // ret esc bs tab space
        [0x2D] = 0x0C, [0x2E] = 0x0D, [0x2F] = 0x1A, [0x30] = 0x1B, [0x31] = 0x2B, [0x32] = 0x2B, // - = [ ] \ #
        [0x33] = 0x27, [0x34] = 0x28, [0x35] = 0x29, [0x36] = 0x33, [0x37] = 0x34, [0x38] = 0x35, // ; ' ` , . /
        [0x39] = 0x3A,                                                                             // caps
        [0x3A] = 0x3B, [0x3B] = 0x3C, [0x3C] = 0x3D, [0x3D] = 0x3E, [0x3E] = 0x3F, [0x3F] = 0x40, // F1-F6
        [0x40] = 0x41, [0x41] = 0x42, [0x42] = 0x43, [0x43] = 0x44, [0x44] = 0x57, [0x45] = 0x58, // F7-F12
        [0x46] = 0x137, [0x47] = 0x46, [0x48] = 0x45,                                              // prtsc scroll pause
        [0x49] = 0x152, [0x4A] = 0x147, [0x4B] = 0x149, [0x4C] = 0x153, [0x4D] = 0x14F, [0x4E] = 0x151, // ins home pgup del end pgdn
        [0x4F] = 0x14D, [0x50] = 0x14B, [0x51] = 0x150, [0x52] = 0x148,                           // right left down up
        [0x53] = 0x45, [0x54] = 0x135, [0x55] = 0x37, [0x56] = 0x4A, [0x57] = 0x4E, [0x58] = 0x11C, // numlock kp/ kp* kp- kp+ kpenter
        [0x59] = 0x4F, [0x5A] = 0x50, [0x5B] = 0x51, [0x5C] = 0x4B, [0x5D] = 0x4C, [0x5E] = 0x4D, // kp1-6
        [0x5F] = 0x47, [0x60] = 0x48, [0x61] = 0x49, [0x62] = 0x52, [0x63] = 0x53,                // kp7-9 kp0 kp.
        [0x64] = 0x56, [0x65] = 0x15D,                                                             // non-US \ , menu
        [0xE0] = 0x1D, [0xE1] = 0x2A, [0xE2] = 0x38, [0xE3] = 0x15B,                               // lctrl lshift lalt lgui
        [0xE4] = 0x11D, [0xE5] = 0x36, [0xE6] = 0x138, [0xE7] = 0x15C,                             // rctrl rshift ralt rgui
    };
    if (usage < 0 || usage >= (NSInteger)(sizeof(table) / sizeof(table[0]))) return 0;
    return table[usage];
}
