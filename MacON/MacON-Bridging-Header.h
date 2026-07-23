//
//  MacON-Bridging-Header.h
//  MacON
//
//  Private CoreGraphics virtual-display API (reverse-engineered class-dump
//  interfaces — the same ones BetterDisplay / DeskPad use). Lets the Mac host a
//  real, capturable display when the lid is shut with no external monitor: the
//  internal panel can't be lit in clamshell, so instead of fighting that we
//  hand macOS a virtual surface to render onto. ScreenCaptureKit then captures
//  it exactly like a physical screen, and the login window relocates onto it so
//  remote unlock works too.
//
//  Private API: works today, may change in a future macOS. MacON is
//  direct-distributed and non-sandboxed, so that's an acceptable tradeoff here
//  (it would not pass Mac App Store review).
//

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

@interface CGVirtualDisplayMode : NSObject
- (instancetype)initWithWidth:(unsigned int)width
                       height:(unsigned int)height
                  refreshRate:(double)refreshRate;
@property(readonly, nonatomic) unsigned int width;
@property(readonly, nonatomic) unsigned int height;
@property(readonly, nonatomic) double refreshRate;
@end

@interface CGVirtualDisplaySettings : NSObject
@property(nonatomic) unsigned int hiDPI;
@property(retain, nonatomic) NSArray<CGVirtualDisplayMode *> *modes;
@end

@interface CGVirtualDisplayDescriptor : NSObject
@property(retain, nonatomic) dispatch_queue_t queue;
@property(retain, nonatomic) NSString *name;
@property(nonatomic) unsigned int maxPixelsWide;
@property(nonatomic) unsigned int maxPixelsHigh;
@property(nonatomic) CGSize sizeInMillimeters;
@property(nonatomic) unsigned int serialNum;
@property(nonatomic) unsigned int productID;
@property(nonatomic) unsigned int vendorID;
@property(nonatomic) CGPoint redPrimary;
@property(nonatomic) CGPoint greenPrimary;
@property(nonatomic) CGPoint bluePrimary;
@property(nonatomic) CGPoint whitePoint;
@property(copy, nonatomic) void (^terminationHandler)(void);
@end

@interface CGVirtualDisplay : NSObject
- (instancetype)initWithDescriptor:(CGVirtualDisplayDescriptor *)descriptor;
- (BOOL)applySettings:(CGVirtualDisplaySettings *)settings;
@property(readonly, nonatomic) unsigned int displayID;
@end

NS_ASSUME_NONNULL_END
