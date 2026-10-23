// Shapes of the private CoreSimulator, SimulatorKit and
// AccessibilityPlatformTranslation APIs that glovebox calls. Everything is
// declared as a protocol so nothing links against the private frameworks;
// classes are looked up at runtime with NSClassFromString.
//
// Derived from facebook/idb (MIT License, Copyright (c) Meta Platforms, Inc.
// and affiliates) and re-verified against Xcode 27 with nm, otool and the
// Objective-C runtime.
#import <AppKit/AppKit.h>
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - CoreSimulator

@protocol SBSimDeviceIOPortDescriptor <NSObject>
- (id)state;
@end

@protocol SBSimDeviceIOPort <NSObject>
- (id<SBSimDeviceIOPortDescriptor>)descriptor;
@end

@protocol SBSimDeviceIOClient <NSObject>
- (NSArray<id<SBSimDeviceIOPort>> *)ioPorts;
@end

@protocol SBSimDevice <NSObject>
- (NSUUID *)UDID;
- (NSString *)name;
- (NSString *)stateString;
@optional
// Set on every boot. Not in idb; found in CoreSimulator with strings. (Its
// bootSessionUUID is always nil in Xcode 27.)
- (nullable NSDate *)lastBootedAt;
// Looks up a mach service in the simulator's bootstrap and returns a send
// right to it, or MACH_PORT_NULL. Not in idb; found with the ObjC runtime
// (type encoding I32@0:8@16^@24).
- (mach_port_t)lookup:(NSString *)name error:(NSError **)error;
@required
- (id<SBSimDeviceIOClient>)io;
- (void)sendAccessibilityRequestAsync:(id)request
                      completionQueue:(dispatch_queue_t)queue
                    completionHandler:(void (^)(id _Nullable response))handler;
@end

@protocol SBSimDeviceSet <NSObject>
- (NSArray<id<SBSimDevice>> *)devices;
@end

@protocol SBSimServiceContext <NSObject>
+ (nullable id<SBSimServiceContext>)sharedServiceContextForDeveloperDir:(NSString *)developerDir
                                                                 error:(NSError **)error;
- (nullable id<SBSimDeviceSet>)defaultDeviceSetWithError:(NSError **)error;
@end

#pragma mark - Screens (SimScreen / SimDisplayIOSurfaceRenderable)

@protocol SBSimScreenBacklight <NSObject>
- (int)state;
@end

@protocol SBSimScreenMode <NSObject>
- (double)preferredUIScale;
@end

@protocol SBSimScreenProperties <NSObject>
- (unsigned int)screenID;
- (unsigned long long)screenType;
- (int)powerState;
- (CGSize)pixelSize;
- (nullable id<SBSimScreenMode>)currentMode;
- (nullable id<SBSimScreenBacklight>)backlight;
@end

/// The descriptor of a display port. Conforms to the private `SimScreen`,
/// `SimDisplayRenderable` and `SimDisplayIOSurfaceRenderable` protocols.
@protocol SBSimScreen <SBSimDeviceIOPortDescriptor>
- (id<SBSimScreenProperties>)screenProperties;
- (nullable IOSurface *)framebufferSurface;
// Xcode 27 removed the damage-rectangle callbacks; this fires once per frame.
- (void)registerScreenCallbacksWithUUID:(NSUUID *)uuid
                          callbackQueue:(dispatch_queue_t)queue
                          frameCallback:(void (^)(void))frameCallback
                surfacesChangedCallback:(void (^)(IOSurface *_Nullable, IOSurface *_Nullable))surfacesChangedCallback
              propertiesChangedCallback:(void (^)(id))propertiesChangedCallback;
- (void)unregisterScreenCallbacksWithUUID:(NSUUID *)uuid;
@end

#pragma mark - SimulatorKit HID

@protocol SBSimDeviceLegacyHIDClient <NSObject>
- (nullable instancetype)initWithDevice:(id<SBSimDevice>)device error:(NSError **)error;
- (void)sendWithMessage:(void *)message
           freeWhenDone:(BOOL)freeWhenDone
        completionQueue:(dispatch_queue_t)queue
             completion:(void (^)(NSError *_Nullable error))completion;
@end

// Indigo message builders exported by SimulatorKit. Signatures recovered from
// the Xcode 27 disassembly. Each returns a calloc'd message, or NULL.
//
// Mouse: SimulatorKit divides `point` by `size` to get the touch ratio and
// drops drag events that arrive within 16 ms of the previous event.
typedef void *_Nullable (*SBIndigoMouseFn)(CGPoint *point, CGPoint *_Nullable secondPoint, uint32_t target,
                                           NSUInteger eventType, CGSize size, uint32_t edge);
typedef void *_Nullable (*SBIndigoKeyboardFn)(uint32_t usage, uint32_t operation);
typedef void *_Nullable (*SBIndigoButtonFn)(uint32_t source, uint32_t operation, uint32_t target);

#pragma mark - AccessibilityPlatformTranslation

@protocol SBAXPTranslationObject <NSObject>
@property (nonatomic, copy, nullable) NSString *bridgeDelegateToken;
@property (nonatomic) int pid;
@end

@protocol SBAXPMacPlatformElement <NSObject>
- (id<SBAXPTranslationObject>)translation;
- (nullable NSString *)accessibilityRole;
- (nullable id)accessibilityLabel;
- (nullable id)accessibilityValue;
- (nullable NSString *)accessibilityIdentifier;
- (nullable id)accessibilityTitle;
- (nullable id)accessibilityPlaceholderValue;
- (NSRect)accessibilityFrame;
- (NSPoint)accessibilityActivationPoint;
- (BOOL)isAccessibilityEnabled;
- (nullable NSArray *)accessibilityChildren;
@end

@protocol SBAXPTranslator <NSObject>
+ (instancetype)sharedInstance;
@property (nonatomic, weak, nullable) id bridgeTokenDelegate;
@property (nonatomic) BOOL supportsDelegateTokens;
@property (nonatomic) BOOL accessibilityEnabled;
- (nullable id<SBAXPTranslationObject>)frontmostApplicationWithDisplayId:(unsigned int)displayId
                                                     bridgeDelegateToken:(NSString *)token;
- (nullable id<SBAXPTranslationObject>)objectAtPoint:(CGPoint)point
                                           displayId:(unsigned int)displayId
                                 bridgeDelegateToken:(NSString *)token;
- (nullable id<SBAXPMacPlatformElement>)macPlatformElementFromTranslation:(id<SBAXPTranslationObject>)translation;
@end

NS_ASSUME_NONNULL_END
