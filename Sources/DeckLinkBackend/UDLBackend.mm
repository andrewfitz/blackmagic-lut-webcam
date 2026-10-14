#import "UDLBackend.h"
#include <atomic>
#include <memory>
#include <cstring>

#if __has_include("DeckLinkAPI.h")
#include "DeckLinkAPI.h"
#include "DeckLinkAPIConfiguration.h"
#include "DeckLinkAPIVersion.h"
#define UDL_HAS_SDK 1
#else
#define UDL_HAS_SDK 0
#endif

@interface UDLMode ()
@property(nonatomic) NSInteger width;
@property(nonatomic) NSInteger height;
@property(nonatomic) CMTime frameDuration;
@property(nonatomic, copy) NSString *name;
@end
@implementation UDLMode
@end

@interface UDLDevice ()
@property(nonatomic, copy) NSString *identifier;
@property(nonatomic, copy) NSString *name;
@property(nonatomic, copy) NSArray<UDLMode *> *modes;
@end
@implementation UDLDevice
@end

static BOOL fail(NSError **error, NSString *message, NSInteger code = 1) {
  if (error) *error = [NSError errorWithDomain:@"org.ultrastudiolut.decklink" code:code
    userInfo:@{NSLocalizedDescriptionKey: message}];
  return NO;
}

#if UDL_HAS_SDK
// Own exactly one COM reference. Discovery/start failure paths release partial
// resources automatically; callback/frame references have independent lives.
template <typename T> struct ComRef {
  T *value = nullptr;
  ~ComRef() { if (value) value->Release(); }
  T **out() { return &value; }
  T *operator->() const { return value; }
  explicit operator bool() const { return value != nullptr; }
  T *take() { T *result = value; value = nullptr; return result; }
};

// Session-only HDMI selection. Never persist device preferences. Restore only
// the value this session still owns, preserving a subsequent outside change.
struct HDMILease {
  ComRef<IDeckLinkConfiguration> configuration;
  int64_t previous = bmdVideoConnectionHDMI;
  bool changed = false;
  ~HDMILease() {
    int64_t current = 0;
    if (changed && configuration && configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &current) == S_OK && current == bmdVideoConnectionHDMI)
      configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, previous);
  }
  HRESULT select(IDeckLink *device) {
    HRESULT status = device->QueryInterface(IID_IDeckLinkConfiguration, reinterpret_cast<void **>(configuration.out()));
    if (status != S_OK) return status;
    status = configuration->GetInt(bmdDeckLinkConfigVideoInputConnection, &previous);
    if (status != S_OK || previous == bmdVideoConnectionHDMI) return status;
    status = configuration->SetInt(bmdDeckLinkConfigVideoInputConnection, bmdVideoConnectionHDMI);
    changed = status == S_OK;
    return status;
  }
};

static NSString *deviceIdentifier(IDeckLink *device, NSUInteger index) {
  ComRef<IDeckLinkProfileAttributes> attributes;
  int64_t persistentID = 0;
  if (device->QueryInterface(IID_IDeckLinkProfileAttributes,
      reinterpret_cast<void **>(attributes.out())) == S_OK &&
      attributes->GetInt(BMDDeckLinkPersistentID, &persistentID) == S_OK) {
    return [NSString stringWithFormat:@"decklink:%016llx", (unsigned long long)persistentID];
  }
  // Legacy devices without persistent IDs are distinguished within the current
  // iterator; start re-enumerates and verifies this same identifier.
  CFStringRef name = nullptr;
  device->GetDisplayName(&name);
  NSString *result = [NSString stringWithFormat:@"decklink:%@:%lu",
    name ? (__bridge NSString *)name : @"Unknown", (unsigned long)index];
  if (name) CFRelease(name);
  return result;
}

static NSArray<UDLMode *> *supportedModes(IDeckLinkInput *input) {
  NSMutableArray<UDLMode *> *result = [NSMutableArray array];
  ComRef<IDeckLinkDisplayModeIterator> iterator;
  if (input->GetDisplayModeIterator(iterator.out()) != S_OK) return result;
  IDeckLinkDisplayMode *raw = nullptr;
  while (iterator->Next(&raw) == S_OK) {
    ComRef<IDeckLinkDisplayMode> mode; mode.value = raw;
    BMDTimeValue duration = 0; BMDTimeScale scale = 0;
    mode->GetFrameRate(&duration, &scale);
    if (mode->GetWidth() != 3840 || mode->GetHeight() != 2160 || scale <= 0 ||
        (CMTimeCompare(CMTimeMake(duration, (int32_t)scale), CMTimeMake(1001, 30000)) != 0 &&
         CMTimeCompare(CMTimeMake(duration, (int32_t)scale), CMTimeMake(1001, 60000)) != 0)) continue;
    bool supported = false;
    if (input->DoesSupportVideoMode(bmdVideoConnectionHDMI, mode->GetDisplayMode(),
      bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported) != S_OK || !supported) continue;
    UDLMode *description = [UDLMode new];
    description.width = mode->GetWidth(); description.height = mode->GetHeight();
    description.frameDuration = CMTimeMake(duration, (int32_t)scale);
    CFStringRef name = nullptr; mode->GetName(&name);
    description.name = name ? (__bridge NSString *)name : @"4K";
    if (name) CFRelease(name);
    [result addObject:description];
  }
  return result;
}

static bool sameIID(REFIID a, CFUUIDBytes b) { return std::memcmp(&a, &b, sizeof(a)) == 0; }

class CaptureCallback final : public IDeckLinkInputCallback {
 public:
  std::atomic<ULONG> references{1};
  std::atomic<bool> accepting{true};
  std::atomic<int> signalState{-1};
  std::atomic<bool> fatalReported{false};
  BMDDisplayMode requestedMode;
  CMTimeScale timeScale;
  void (^frameHandler)(CVPixelBufferRef, CMTime, BOOL);
  void (^eventHandler)(NSString *);
  CaptureCallback(BMDDisplayMode mode, CMTimeScale scale,
    void (^frames)(CVPixelBufferRef, CMTime, BOOL), void (^events)(NSString *))
    : requestedMode(mode), timeScale(scale), frameHandler([frames copy]), eventHandler([events copy]) {}
  HRESULT QueryInterface(REFIID iid, LPVOID *object) override {
    if (!object) return E_INVALIDARG;
    *object = nullptr;
    if (sameIID(iid, CFUUIDGetUUIDBytes(IUnknownUUID)) || sameIID(iid, IID_IDeckLinkInputCallback)) {
      *object = static_cast<IDeckLinkInputCallback *>(this); AddRef(); return S_OK;
    }
    return E_NOINTERFACE;
  }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG remaining = --references; if (!remaining) delete this; return remaining; }
  void reportFatal(NSString *message) {
    accepting = false;
    if (!fatalReported.exchange(true)) eventHandler(message);
  }
  HRESULT VideoInputFormatChanged(BMDVideoInputFormatChangedEvents,
    IDeckLinkDisplayMode *mode, BMDDetectedVideoInputFormatFlags) override {
    @autoreleasepool {
      if (!accepting) return S_OK;
      if (!mode || mode->GetDisplayMode() != requestedMode) {
        reportFatal(@"Input changed from the selected 4K 10-bit YUV mode. Check the FX3 HDMI output and selected frame rate, then restart.");
      }
    }
    return S_OK;
  }
  HRESULT VideoInputFrameArrived(IDeckLinkVideoInputFrame *frame, IDeckLinkAudioInputPacket *) override {
    @autoreleasepool {
      if (!accepting || !frame) return S_OK;
      bool valid = !(frame->GetFlags() & bmdFrameHasNoInputSource);
      int prior = signalState.exchange(valid ? 1 : 0);
      if (!valid) {
        if (prior != 0) eventHandler(@"No video signal. Check the FX3 HDMI output and selected frame rate.");
        return S_OK;
      }
      if (frame->GetWidth() != 3840 || frame->GetHeight() != 2160 || frame->GetPixelFormat() != bmdFormat10BitYUV) {
        reportFatal(@"UltraStudio supplied a frame outside the 4K 10-bit 4:2:2 contract."); return S_OK;
      }
      BMDTimeValue timestamp = 0, duration = 0;
      if (frame->GetStreamTime(&timestamp, &duration, timeScale) != S_OK || duration <= 0) {
        reportFatal(@"UltraStudio supplied an invalid frame timestamp."); return S_OK;
      }
      CVPixelBufferRef buffer = nullptr;
#if BLACKMAGIC_DECKLINK_API_VERSION >= 0x0e030000
      ComRef<IDeckLinkMacVideoBuffer> macBuffer;
      if (frame->QueryInterface(IID_IDeckLinkMacVideoBuffer,
        reinterpret_cast<void **>(macBuffer.out())) != S_OK ||
        macBuffer->CreateCVPixelBufferRef(reinterpret_cast<void **>(&buffer)) != S_OK || !buffer) {
        reportFatal(@"Desktop Video could not expose its native 10-bit pixel buffer. Update the Desktop Video driver."); return S_OK;
      }
      // SDK14.3+ carries a reference to the frame and allocation internally.
#else
      // SDK12 uses the versioned legacy frame interface. Retain the native
      // frame until the CVPixelBuffer's final release; do not copy ~22 MB/frame.
      void *bytes = nullptr;
      if (frame->GetBytes(&bytes) != S_OK || !bytes || frame->GetRowBytes() < 10240) {
        reportFatal(@"Desktop Video could not expose its native 10-bit frame bytes."); return S_OK;
      }
      frame->AddRef();
      CVReturn result = CVPixelBufferCreateWithBytes(kCFAllocatorDefault, 3840, 2160,
        kCVPixelFormatType_422YpCbCr10, bytes, frame->GetRowBytes(),
        [](void *context, const void *) { static_cast<IDeckLinkVideoInputFrame *>(context)->Release(); },
        frame, nullptr, &buffer);
      if (result != kCVReturnSuccess || !buffer) {
        frame->Release(); reportFatal(@"Cannot wrap the native UltraStudio 10-bit frame."); return S_OK;
      }
#endif
      // Swift retaining the buffer safely extends the native frame lifetime.
      if (accepting) frameHandler(buffer, CMTimeMake(timestamp, timeScale), YES);
      CVPixelBufferRelease(buffer);
    }
    return S_OK;
  }
};
// Driver setup/teardown stays ordered and is independently exercised with a
// fake SDK input in tests. Disable callbacks before a synchronous driver stop.
static void stopInput(IDeckLinkInput *input, CaptureCallback *callback) {
  if (callback) callback->accepting = false;
  if (input) { input->StopStreams(); input->SetCallback(nullptr); input->DisableVideoInput(); }
}

static HRESULT startInput(IDeckLinkInput *input, CaptureCallback *callback,
  BMDDisplayMode mode, BMDVideoInputFlags flags) {
  HRESULT status = input->SetCallback(callback);
  if (status == S_OK) status = input->EnableVideoInput(mode, bmdFormat10BitYUV, flags);
  if (status == S_OK) status = input->StartStreams();
  if (status != S_OK) stopInput(input, callback);
  return status;
}

#if defined(UDL_BACKEND_TESTING)
#include "BackendTestSupport.inc"
#endif

#endif

@implementation UDLBackend {
#if UDL_HAS_SDK
  IDeckLinkInput *_input;
  CaptureCallback *_callback;
  std::unique_ptr<HDMILease> _connection;
#endif
}

+ (NSArray<UDLDevice *> *)devicesWithError:(NSError **)error {
#if UDL_HAS_SDK
  ComRef<IDeckLinkIterator> iterator; iterator.value = CreateDeckLinkIteratorInstance();
  if (!iterator) { fail(error, @"Blackmagic Desktop Video is not available. Install the compatible Desktop Video driver."); return nil; }
  NSMutableArray<UDLDevice *> *result = [NSMutableArray array];
  IDeckLink *raw = nullptr; NSUInteger index = 0;
  while (iterator->Next(&raw) == S_OK) {
    ComRef<IDeckLink> device; device.value = raw;
    NSString *identifier = deviceIdentifier(device.value, index++);
    ComRef<IDeckLinkInput> input;
    if (device->QueryInterface(IID_IDeckLinkInput, reinterpret_cast<void **>(input.out())) != S_OK) continue;
    UDLDevice *description = [UDLDevice new]; description.identifier = identifier;
    CFStringRef name = nullptr; device->GetDisplayName(&name);
    description.name = name ? (__bridge NSString *)name : @"Blackmagic capture device";
    if (name) CFRelease(name);
    description.modes = supportedModes(input.value);
    [result addObject:description];
  }
  return result;
#else
  fail(error, @"This app was built without the Blackmagic Desktop Video SDK. Configure DECKLINK_SDK_DIR and rebuild."); return nil;
#endif
}

- (BOOL)startWithDeviceID:(NSString *)deviceID inputFast:(BOOL)inputFast
  frameHandler:(void (^)(CVPixelBufferRef, CMTime, BOOL))frameHandler
  eventHandler:(void (^)(NSString *))eventHandler error:(NSError **)error {
  [self stop];
#if UDL_HAS_SDK
  ComRef<IDeckLinkIterator> iterator; iterator.value = CreateDeckLinkIteratorInstance();
  if (!iterator) return fail(error, @"Blackmagic Desktop Video is not available.");
  ComRef<IDeckLinkInput> input; IDeckLink *raw = nullptr; NSUInteger index = 0;
  auto connection = std::make_unique<HDMILease>();
  BMDVideoInputFlags inputFlags = bmdVideoInputFlagDefault;
  while (iterator->Next(&raw) == S_OK) {
    ComRef<IDeckLink> device; device.value = raw;
    NSString *identifier = deviceIdentifier(device.value, index++);
    if (![identifier isEqualToString:deviceID]) continue;
    if (device->QueryInterface(IID_IDeckLinkInput, reinterpret_cast<void **>(input.out())) != S_OK)
      return fail(error, @"The selected Blackmagic device has no capture input.");
    HRESULT connectionStatus = connection->select(device.value);
    if (connectionStatus != S_OK) return fail(error, @"Cannot select the UltraStudio HDMI input. Close other capture apps, then restart.", connectionStatus);
    ComRef<IDeckLinkProfileAttributes> attributes;
    bool detectsFormat = false;
    if (device->QueryInterface(IID_IDeckLinkProfileAttributes, reinterpret_cast<void **>(attributes.out())) == S_OK &&
        attributes->GetFlag(BMDDeckLinkSupportsInputFormatDetection, &detectsFormat) == S_OK && detectsFormat)
      inputFlags = bmdVideoInputEnableFormatDetection;
    break;
  }
  if (!input) return fail(error, @"UltraStudio is disconnected. Refresh the input list.");
  BMDDisplayMode requestedMode = inputFast ? bmdMode4K2160p5994 : bmdMode4K2160p2997;
  bool supported = false;
  HRESULT status = input->DoesSupportVideoMode(bmdVideoConnectionHDMI, requestedMode,
    bmdFormat10BitYUV, bmdNoVideoInputConversion, bmdSupportedVideoModeDefault, nullptr, &supported);
  if (status != S_OK || !supported)
    return fail(error, @"UltraStudio does not support 3840 × 2160 10-bit 4:2:2 at the selected frame rate.", status);
  auto callback = new CaptureCallback(requestedMode, inputFast ? 60000 : 30000, frameHandler, eventHandler);
  status = startInput(input.value, callback, requestedMode, inputFlags);
  if (status != S_OK) {
    callback->Release();
    return fail(error, status == E_ACCESSDENIED ?
      @"UltraStudio is in use by another app. Close the other capture app, then restart." :
      [NSString stringWithFormat:@"UltraStudio could not start the 4K 10-bit input (0x%08x). Check Desktop Video and HDMI settings.", (unsigned)status], status);
  }
  _input = input.take(); _callback = callback; _connection = std::move(connection);
  return YES;
#else
  return fail(error, @"This app was built without the Blackmagic Desktop Video SDK. Configure DECKLINK_SDK_DIR and rebuild.");
#endif
}

- (void)stop {
#if UDL_HAS_SDK
  stopInput(_input, _callback);
  if (_input) { _input->Release(); _input = nullptr; }
  if (_callback) { _callback->Release(); _callback = nullptr; }
  _connection.reset();
#endif
}

- (void)dealloc { [self stop]; }
@end
