#import <Foundation/Foundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

NS_ASSUME_NONNULL_BEGIN

@interface UDLMode : NSObject
@property(nonatomic, readonly) NSInteger width;
@property(nonatomic, readonly) NSInteger height;
@property(nonatomic, readonly) CMTime frameDuration;
@property(nonatomic, readonly, copy) NSString *name;
@end

@interface UDLDevice : NSObject
@property(nonatomic, readonly, copy) NSString *identifier;
@property(nonatomic, readonly, copy) NSString *name;
@property(nonatomic, readonly, copy) NSArray<UDLMode *> *modes;
@end

// Calls start/stop on one control queue. Handlers execute on Blackmagic's
// callback thread and must return promptly: reject a frame while processing is
// busy, then retain the CVPixelBuffer for any accepted asynchronous work. The
// pixel buffer owns the underlying DeckLink frame until its final release.
// Never call stop() synchronously from a handler (it waits for callbacks).
@interface UDLBackend : NSObject
+ (nullable NSArray<UDLDevice *> *)devicesWithError:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(devices());
- (BOOL)startWithDeviceID:(NSString *)deviceID
               inputFast:(BOOL)inputFast
            frameHandler:(void (^)(CVPixelBufferRef pixelBuffer, CMTime presentationTime, BOOL signalValid))frameHandler
            eventHandler:(void (^)(NSString *message))eventHandler
                   error:(NSError *_Nullable *_Nullable)error
  NS_SWIFT_NAME(start(deviceID:inputFast:frameHandler:eventHandler:));
- (void)stop;
@end

#if defined(UDL_BACKEND_TESTING)
// Synthetic SDK callbacks only; never opens hardware or saves video.
FOUNDATION_EXPORT BOOL UDLRunSyntheticChecks(NSError *_Nullable *_Nullable error);
#endif

NS_ASSUME_NONNULL_END
