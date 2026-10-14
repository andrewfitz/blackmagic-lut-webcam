// Included only with UDL_BACKEND_TESTING; no mock code in the shipped app.
#include <vector>
#include <string>

#if BLACKMAGIC_DECKLINK_API_VERSION < 0x0e030000
class FakeFrame final : public IDeckLinkVideoInputFrame {
 public:
  std::atomic<ULONG> references{1};
  bool *destroyed;
  std::vector<uint8_t> bytes = std::vector<uint8_t>(10240 * 2160, 0);
  bool noSignal = false, invalidTime = false, badBytes = false;
  long width = 3840;
  FakeFrame(bool *result) : destroyed(result) {}
  ~FakeFrame() override { *destroyed = true; }
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { ULONG n = --references; if (!n) delete this; return n; }
  long GetWidth() override { return width; }
  long GetHeight() override { return 2160; }
  long GetRowBytes() override { return 10240; }
  BMDPixelFormat GetPixelFormat() override { return bmdFormat10BitYUV; }
  BMDFrameFlags GetFlags() override { return noSignal ? bmdFrameHasNoInputSource : bmdFrameFlagDefault; }
  HRESULT GetBytes(void **result) override { *result = bytes.data(); return badBytes ? E_FAIL : S_OK; }
  HRESULT GetTimecode(BMDTimecodeFormat, IDeckLinkTimecode **) override { return E_NOTIMPL; }
  HRESULT GetAncillaryData(IDeckLinkVideoFrameAncillary **) override { return E_NOTIMPL; }
  HRESULT GetStreamTime(BMDTimeValue *pts, BMDTimeValue *duration, BMDTimeScale) override {
    *pts = 123123; *duration = 1001; return invalidTime ? E_FAIL : S_OK;
  }
  HRESULT GetHardwareReferenceTimestamp(BMDTimeScale, BMDTimeValue *, BMDTimeValue *) override { return E_NOTIMPL; }
};

class FakeMode final : public IDeckLinkDisplayMode {
 public:
  ULONG references = 1;
  BMDDisplayMode mode = bmdMode4K2160p5994;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT GetName(CFStringRef *name) override { *name = CFSTR("Synthetic 4K"); CFRetain(*name); return S_OK; }
  BMDDisplayMode GetDisplayMode() override { return mode; }
  long GetWidth() override { return 3840; }
  long GetHeight() override { return 2160; }
  HRESULT GetFrameRate(BMDTimeValue *duration, BMDTimeScale *scale) override { *duration = 1001; *scale = 60000; return S_OK; }
  BMDFieldDominance GetFieldDominance() override { return bmdProgressiveFrame; }
  BMDDisplayModeFlags GetFlags() override { return bmdDisplayModeColorspaceRec709; }
};

class FakeInput final : public IDeckLinkInput {
 public:
  ULONG references = 1;
  std::vector<std::string> calls;
  HRESULT enableResult = S_OK, startResult = S_OK, callbackResult = S_OK;
  IDeckLinkInputCallback *callback = nullptr;
  ~FakeInput() override { if (callback) callback->Release(); }
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT DoesSupportVideoMode(BMDVideoConnection, BMDDisplayMode, BMDPixelFormat, BMDVideoInputConversionMode,
    BMDSupportedVideoModeFlags, BMDDisplayMode *, bool *) override { return E_NOTIMPL; }
  HRESULT GetDisplayMode(BMDDisplayMode, IDeckLinkDisplayMode **) override { return E_NOTIMPL; }
  HRESULT GetDisplayModeIterator(IDeckLinkDisplayModeIterator **) override { return E_NOTIMPL; }
  HRESULT SetScreenPreviewCallback(IDeckLinkScreenPreviewCallback *) override { return E_NOTIMPL; }
  HRESULT EnableVideoInput(BMDDisplayMode mode, BMDPixelFormat format, BMDVideoInputFlags) override {
    calls.push_back("enable");
    if (mode != bmdMode4K2160p5994 || format != bmdFormat10BitYUV) return E_INVALIDARG;
    return enableResult;
  }
  HRESULT DisableVideoInput() override { calls.push_back("disable"); return S_OK; }
  HRESULT GetAvailableVideoFrameCount(uint32_t *) override { return E_NOTIMPL; }
  HRESULT SetVideoInputFrameMemoryAllocator(IDeckLinkMemoryAllocator *) override { return E_NOTIMPL; }
  HRESULT EnableAudioInput(BMDAudioSampleRate, BMDAudioSampleType, uint32_t) override { return E_NOTIMPL; }
  HRESULT DisableAudioInput() override { return E_NOTIMPL; }
  HRESULT GetAvailableAudioSampleFrameCount(uint32_t *) override { return E_NOTIMPL; }
  HRESULT StartStreams() override { calls.push_back("start"); return startResult; }
  HRESULT StopStreams() override { calls.push_back("stop"); return S_OK; }
  HRESULT PauseStreams() override { return E_NOTIMPL; }
  HRESULT FlushStreams() override { return E_NOTIMPL; }
  HRESULT SetCallback(IDeckLinkInputCallback *value) override {
    calls.push_back(value ? "callback" : "clear");
    if (value && callbackResult != S_OK) return callbackResult;
    if (value) value->AddRef(); if (callback) callback->Release(); callback = value; return S_OK;
  }
  HRESULT GetHardwareReferenceClock(BMDTimeScale, BMDTimeValue *, BMDTimeValue *, BMDTimeValue *) override { return E_NOTIMPL; }
};

class FakeConfiguration final : public IDeckLinkConfiguration {
 public:
  ULONG references = 1;
  int64_t connection = bmdVideoConnectionSDI;
  int writes = 0, persistentWrites = 0;
  HRESULT QueryInterface(REFIID, LPVOID *result) override { *result = nullptr; return E_NOINTERFACE; }
  ULONG AddRef() override { return ++references; }
  ULONG Release() override { return --references; }
  HRESULT SetFlag(BMDDeckLinkConfigurationID, bool) override { return E_NOTIMPL; }
  HRESULT GetFlag(BMDDeckLinkConfigurationID, bool *) override { return E_NOTIMPL; }
  HRESULT SetInt(BMDDeckLinkConfigurationID key, int64_t value) override {
    if (key != bmdDeckLinkConfigVideoInputConnection) return E_INVALIDARG;
    connection = value; ++writes; return S_OK;
  }
  HRESULT GetInt(BMDDeckLinkConfigurationID key, int64_t *value) override {
    if (key != bmdDeckLinkConfigVideoInputConnection) return E_INVALIDARG;
    *value = connection; return S_OK;
  }
  HRESULT SetFloat(BMDDeckLinkConfigurationID, double) override { return E_NOTIMPL; }
  HRESULT GetFloat(BMDDeckLinkConfigurationID, double *) override { return E_NOTIMPL; }
  HRESULT SetString(BMDDeckLinkConfigurationID, CFStringRef) override { return E_NOTIMPL; }
  HRESULT GetString(BMDDeckLinkConfigurationID, CFStringRef *) override { return E_NOTIMPL; }
  HRESULT WriteConfigurationToPreferences() override { ++persistentWrites; return S_OK; }
};

BOOL UDLRunSyntheticChecks(NSError **error) {
  @autoreleasepool {
    __block CVPixelBufferRef retained = nullptr;
    __block int frames = 0, events = 0;
    __block CMTime timestamp = kCMTimeInvalid;
    auto framesBlock = ^(CVPixelBufferRef buffer, CMTime pts, BOOL valid) {
      if (valid) { ++frames; timestamp = pts; retained = CVPixelBufferRetain(buffer); }
    };
    auto eventsBlock = ^(NSString *) { ++events; };
    auto callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
    bool destroyed = false;
    auto frame = new FakeFrame(&destroyed);
    callback->VideoInputFrameArrived(frame, nullptr);
    if (frames != 1 || !retained || CMTimeCompare(timestamp, CMTimeMake(123123, 60000)) != 0 ||
      CVPixelBufferGetPixelFormatType(retained) != kCVPixelFormatType_422YpCbCr10 || frame->references != 2)
      return fail(error, @"Native frame format/timing/reference test failed.");
    frame->Release();
    if (destroyed) return fail(error, @"Native frame was freed while Swift retained its pixel buffer.");
    callback->accepting = false;
    CVPixelBufferRelease(retained); retained = nullptr;
    if (!destroyed) return fail(error, @"Native frame leaked after final pixel buffer release.");
    callback->Release();

    // Lost signal is reported once per transition; stop rejects late frames.
    destroyed = false; frame = new FakeFrame(&destroyed); frame->noSignal = true;
    callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
    callback->VideoInputFrameArrived(frame, nullptr); callback->VideoInputFrameArrived(frame, nullptr);
    if (events != 1 || frames != 1) return fail(error, @"No-signal event deduplication failed.");
    callback->accepting = false; frame->noSignal = false;
    callback->VideoInputFrameArrived(frame, nullptr);
    if (frames != 1) return fail(error, @"Stopped callback delivered a late frame.");
    frame->Release(); callback->Release();

    for (int scenario = 0; scenario != 3; ++scenario) {
      destroyed = false; frame = new FakeFrame(&destroyed);
      if (scenario == 0) frame->width = 1920;
      if (scenario == 1) frame->invalidTime = true;
      if (scenario == 2) frame->badBytes = true;
      events = 0;
      callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
      callback->VideoInputFrameArrived(frame, nullptr); callback->VideoInputFrameArrived(frame, nullptr);
      if (events != 1 || callback->accepting || frames != 1) return fail(error, @"Invalid native frame did not stop with one error.");
      frame->Release(); callback->Release();
      if (!destroyed) return fail(error, @"Rejected native frame leaked.");
    }
    // Success and every partial startup failure must detach the callback and
    // disable the input; restart constructs a fresh accepting callback.
    for (int scenario = 0; scenario != 4; ++scenario) {
      FakeInput input;
      if (scenario == 1) input.callbackResult = E_FAIL;
      if (scenario == 2) input.enableResult = E_ACCESSDENIED;
      if (scenario == 3) input.startResult = E_FAIL;
      callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
      HRESULT status = startInput(&input, callback, bmdMode4K2160p5994, bmdVideoInputFlagDefault);
      if ((scenario == 0) != (status == S_OK)) return fail(error, @"SDK startup did not preserve failure status.");
      if (scenario == 0) stopInput(&input, callback);
      if (input.callback || callback->accepting || callback->references != 1 || input.calls.size() < 4 ||
        input.calls[input.calls.size() - 3] != "stop" || input.calls[input.calls.size() - 2] != "clear" || input.calls.back() != "disable")
        return fail(error, @"SDK teardown order or callback references failed.");
      callback->Release();
    }
    events = 0;
    callback = new CaptureCallback(bmdMode4K2160p5994, 60000, framesBlock, eventsBlock);
    FakeMode mode;
    callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, bmdDetectedVideoInputYCbCr422);
    if (events || !callback->accepting) return fail(error, @"Matching input detection incorrectly stopped capture.");
    mode.mode = bmdMode4K2160p2997;
    callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, bmdDetectedVideoInputYCbCr422);
    callback->VideoInputFormatChanged(bmdVideoInputDisplayModeChanged, &mode, bmdDetectedVideoInputYCbCr422);
    if (events != 1 || callback->accepting) return fail(error, @"Mode change did not reject frames with one error.");
    callback->Release();

    FakeConfiguration configuration;
    {
      HDMILease lease; lease.configuration.value = &configuration; configuration.AddRef();
      lease.previous = bmdVideoConnectionSDI; lease.changed = true;
      configuration.connection = bmdVideoConnectionHDMI;
    }
    if (configuration.connection != bmdVideoConnectionSDI || configuration.writes != 1 || configuration.references != 1)
      return fail(error, @"HDMI lease failed to restore the original connection.");
    {
      HDMILease lease; lease.configuration.value = &configuration; configuration.AddRef();
      lease.previous = bmdVideoConnectionSDI; lease.changed = true;
      configuration.connection = bmdVideoConnectionOpticalSDI;
    }
    if (configuration.connection != bmdVideoConnectionOpticalSDI || configuration.writes != 1 || configuration.persistentWrites != 0)
      return fail(error, @"HDMI lease clobbered a later owner or persisted settings.");
    return YES;
  }
}
#else
BOOL UDLRunSyntheticChecks(NSError **error) {
  return fail(error, @"Synthetic SDK frame mocks currently require the pinned SDK12 interfaces.");
}
#endif
