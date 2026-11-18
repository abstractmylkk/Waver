// Minimal Audio Unit v2 effect: stereo/mono pass-through that feeds the Swift loudness analyser.
// Implements the AudioComponentPlugInInterface directly (no AudioUnitSDK dependency).

#include "WaverAUBridge.h"
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#define kMaxListeners 32
#define kMaxNotifies 8
#define kMaxChannels 2
#define kViewFactoryClass "WaverAUViewFactory"
#define kBundleID "com.mylkaudio.waver.au"

typedef struct {
    AudioUnitPropertyID prop;
    AudioUnitPropertyListenerProc proc;
    void *refCon;
} Listener;

typedef struct {
    AURenderCallback proc;
    void *refCon;
} RenderNotify;

typedef struct {
    AudioComponentPlugInInterface iface; // must stay first: the host passes this pointer back as `self`
    AudioComponentInstance instance;
    AudioComponentDescription desc;
    void *plugin;

    AudioStreamBasicDescription inFormat;
    AudioStreamBasicDescription outFormat;
    UInt32 maxFrames;
    bool initialized;
    UInt32 bypass;
    UInt32 inPlace;
    UInt32 shouldAllocate[2];

    AURenderCallbackStruct inputCallback;
    AudioUnitConnection connection;
    bool hasConnection;
    HostCallbackInfo host;
    bool hasHost;
    AUPreset preset;

    Listener listeners[kMaxListeners];
    int listenerCount;
    RenderNotify notifies[kMaxNotifies];
    int notifyCount;

    float *storage;
    union {
        AudioBufferList list;
        char bytes[sizeof(AudioBufferList) + sizeof(AudioBuffer) * kMaxChannels];
    } pull;
} WaverAU;

// MARK: - Helpers

static AudioStreamBasicDescription MakeFormat(Float64 rate, UInt32 channels) {
    AudioStreamBasicDescription f = {0};
    f.mSampleRate = rate;
    f.mFormatID = kAudioFormatLinearPCM;
    f.mFormatFlags = kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved;
    f.mBytesPerPacket = 4;
    f.mFramesPerPacket = 1;
    f.mBytesPerFrame = 4;
    f.mChannelsPerFrame = channels;
    f.mBitsPerChannel = 32;
    return f;
}

static bool FormatSupported(const AudioStreamBasicDescription *f) {
    return f->mFormatID == kAudioFormatLinearPCM
        && (f->mFormatFlags & kAudioFormatFlagIsFloat)
        && (f->mFormatFlags & kAudioFormatFlagIsNonInterleaved)
        && f->mBitsPerChannel == 32
        && f->mChannelsPerFrame >= 1 && f->mChannelsPerFrame <= kMaxChannels
        && f->mSampleRate > 0;
}

static void NotifyListeners(WaverAU *au, AudioUnitPropertyID prop, AudioUnitScope scope, AudioUnitElement elem) {
    for (int i = 0; i < au->listenerCount; i++) {
        if (au->listeners[i].prop == prop) {
            au->listeners[i].proc(au->listeners[i].refCon, au->instance, prop, scope, elem);
        }
    }
}

static OSStatus AllocateBuffers(WaverAU *au) {
    free(au->storage);
    au->storage = calloc((size_t)au->maxFrames * kMaxChannels, sizeof(float));
    return au->storage ? noErr : kAudio_MemFullError;
}

// MARK: - Lifecycle

static OSStatus WaverOpen(void *self, AudioComponentInstance instance) {
    WaverAU *au = (WaverAU *)self;
    au->instance = instance;
    AudioComponentGetDescription(AudioComponentInstanceGetComponent(instance), &au->desc);
    au->inFormat = MakeFormat(44100, 2);
    au->outFormat = MakeFormat(44100, 2);
    au->maxFrames = 4096;
    au->inPlace = 1;
    au->shouldAllocate[0] = au->shouldAllocate[1] = 1;
    au->preset.presetNumber = -1;
    au->preset.presetName = CFSTR("Untitled");
    au->plugin = WaverPluginCreate();
    return noErr;
}

static OSStatus WaverClose(void *self) {
    WaverAU *au = (WaverAU *)self;
    free(au->storage);
    if (au->preset.presetName) CFRelease(au->preset.presetName);
    if (au->plugin) WaverPluginDestroy(au->plugin);
    free(au);
    return noErr;
}

static OSStatus WaverInitialize(void *self) {
    WaverAU *au = (WaverAU *)self;
    if (au->inFormat.mChannelsPerFrame != au->outFormat.mChannelsPerFrame) return kAudioUnitErr_FormatNotSupported;
    OSStatus err = AllocateBuffers(au);
    if (err) return err;
    WaverPluginPrepare(au->plugin, au->outFormat.mSampleRate);
    au->initialized = true;
    return noErr;
}

static OSStatus WaverUninitialize(void *self) {
    WaverAU *au = (WaverAU *)self;
    au->initialized = false;
    free(au->storage);
    au->storage = NULL;
    return noErr;
}

static OSStatus WaverReset(void *self, AudioUnitScope scope, AudioUnitElement elem) {
    return noErr;
}

// MARK: - Properties

static OSStatus PropertyInfo(WaverAU *au, AudioUnitPropertyID prop, AudioUnitScope scope, AudioUnitElement elem,
                             UInt32 *size, Boolean *writable) {
    bool io = scope == kAudioUnitScope_Input || scope == kAudioUnitScope_Output;
    switch (prop) {
    case kAudioUnitProperty_StreamFormat:
        if (!io) return kAudioUnitErr_InvalidScope;
        if (elem != 0) return kAudioUnitErr_InvalidElement;
        *size = sizeof(AudioStreamBasicDescription); *writable = true; return noErr;
    case kAudioUnitProperty_SampleRate:
        if (!io) return kAudioUnitErr_InvalidScope;
        if (elem != 0) return kAudioUnitErr_InvalidElement;
        *size = sizeof(Float64); *writable = true; return noErr;
    case kAudioUnitProperty_ShouldAllocateBuffer:
        if (!io) return kAudioUnitErr_InvalidScope;
        if (elem != 0) return kAudioUnitErr_InvalidElement;
        *size = sizeof(UInt32); *writable = true; return noErr;
    case kAudioUnitProperty_ElementCount:
        *size = sizeof(UInt32); *writable = false; return noErr;
    case kAudioUnitProperty_ParameterList:
        *size = 0; *writable = false; return noErr;
    case kAudioUnitProperty_SetRenderCallback:
        if (scope != kAudioUnitScope_Input) return kAudioUnitErr_InvalidScope;
        if (elem != 0) return kAudioUnitErr_InvalidElement;
        *size = sizeof(AURenderCallbackStruct); *writable = true; return noErr;
    case kAudioUnitProperty_MakeConnection:
        if (scope != kAudioUnitScope_Input) return kAudioUnitErr_InvalidScope;
        if (elem != 0) return kAudioUnitErr_InvalidElement;
        *size = sizeof(AudioUnitConnection); *writable = true; return noErr;
    default:
        break;
    }

    if (scope != kAudioUnitScope_Global) return kAudioUnitErr_InvalidProperty;
    switch (prop) {
    case kAudioUnitProperty_ClassInfo: *size = sizeof(CFPropertyListRef); *writable = true; return noErr;
    case kAudioUnitProperty_MaximumFramesPerSlice: *size = sizeof(UInt32); *writable = true; return noErr;
    case kAudioUnitProperty_SupportedNumChannels: *size = 2 * sizeof(AUChannelInfo); *writable = false; return noErr;
    case kAudioUnitProperty_Latency: *size = sizeof(Float64); *writable = false; return noErr;
    case kAudioUnitProperty_TailTime: *size = sizeof(Float64); *writable = false; return noErr;
    case kAudioUnitProperty_BypassEffect: *size = sizeof(UInt32); *writable = true; return noErr;
    case kAudioUnitProperty_InPlaceProcessing: *size = sizeof(UInt32); *writable = true; return noErr;
    case kAudioUnitProperty_LastRenderError: *size = sizeof(OSStatus); *writable = false; return noErr;
    case kAudioUnitProperty_CocoaUI: *size = sizeof(AudioUnitCocoaViewInfo); *writable = false; return noErr;
    case kAudioUnitProperty_HostCallbacks: *size = sizeof(HostCallbackInfo); *writable = true; return noErr;
    case kAudioUnitProperty_PresentPreset: *size = sizeof(AUPreset); *writable = true; return noErr;
    case kWaverProperty_Plugin: *size = sizeof(void *); *writable = false; return noErr;
    default: return kAudioUnitErr_InvalidProperty;
    }
}

static OSStatus WaverGetPropertyInfo(void *self, AudioUnitPropertyID prop, AudioUnitScope scope, AudioUnitElement elem,
                                     UInt32 *outSize, Boolean *outWritable) {
    UInt32 size = 0;
    Boolean writable = false;
    OSStatus err = PropertyInfo((WaverAU *)self, prop, scope, elem, &size, &writable);
    if (err) return err;
    if (outSize) *outSize = size;
    if (outWritable) *outWritable = writable;
    return noErr;
}

static CFDictionaryRef CopyClassInfo(WaverAU *au) {
    CFMutableDictionaryRef d = CFDictionaryCreateMutable(NULL, 0, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    SInt32 version = 0, type = (SInt32)au->desc.componentType, subtype = (SInt32)au->desc.componentSubType,
           manufacturer = (SInt32)au->desc.componentManufacturer;
    CFNumberRef n;
    n = CFNumberCreate(NULL, kCFNumberSInt32Type, &version); CFDictionarySetValue(d, CFSTR(kAUPresetVersionKey), n); CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberSInt32Type, &type); CFDictionarySetValue(d, CFSTR(kAUPresetTypeKey), n); CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberSInt32Type, &subtype); CFDictionarySetValue(d, CFSTR(kAUPresetSubtypeKey), n); CFRelease(n);
    n = CFNumberCreate(NULL, kCFNumberSInt32Type, &manufacturer); CFDictionarySetValue(d, CFSTR(kAUPresetManufacturerKey), n); CFRelease(n);
    CFDictionarySetValue(d, CFSTR(kAUPresetNameKey), au->preset.presetName ? au->preset.presetName : CFSTR("Untitled"));
    CFDictionaryRef state = WaverPluginCopyState(au->plugin);
    if (state) { CFDictionarySetValue(d, CFSTR("waver"), state); CFRelease(state); }
    return d;
}

static bool MatchesNumber(CFDictionaryRef d, CFStringRef key, UInt32 expected) {
    CFNumberRef n = CFDictionaryGetValue(d, key);
    SInt32 v = 0;
    return n && CFGetTypeID(n) == CFNumberGetTypeID() && CFNumberGetValue(n, kCFNumberSInt32Type, &v) && (UInt32)v == expected;
}

static OSStatus RestoreClassInfo(WaverAU *au, CFPropertyListRef plist) {
    if (!plist || CFGetTypeID(plist) != CFDictionaryGetTypeID()) return kAudioUnitErr_InvalidPropertyValue;
    CFDictionaryRef d = (CFDictionaryRef)plist;
    if (!MatchesNumber(d, CFSTR(kAUPresetVersionKey), 0)
        || !MatchesNumber(d, CFSTR(kAUPresetTypeKey), au->desc.componentType)
        || !MatchesNumber(d, CFSTR(kAUPresetSubtypeKey), au->desc.componentSubType)
        || !MatchesNumber(d, CFSTR(kAUPresetManufacturerKey), au->desc.componentManufacturer)) {
        return kAudioUnitErr_InvalidPropertyValue;
    }
    CFStringRef name = CFDictionaryGetValue(d, CFSTR(kAUPresetNameKey));
    if (name && CFGetTypeID(name) == CFStringGetTypeID()) {
        if (au->preset.presetName) CFRelease(au->preset.presetName);
        au->preset.presetName = CFStringCreateCopy(NULL, name);
        au->preset.presetNumber = -1;
    }
    CFDictionaryRef state = CFDictionaryGetValue(d, CFSTR("waver"));
    if (state && CFGetTypeID(state) == CFDictionaryGetTypeID()) WaverPluginSetState(au->plugin, state);
    NotifyListeners(au, kAudioUnitProperty_PresentPreset, kAudioUnitScope_Global, 0);
    return noErr;
}

static OSStatus WaverGetProperty(void *self, AudioUnitPropertyID prop, AudioUnitScope scope, AudioUnitElement elem,
                                 void *outData, UInt32 *ioSize) {
    WaverAU *au = (WaverAU *)self;
    UInt32 size = 0;
    Boolean writable = false;
    OSStatus err = PropertyInfo(au, prop, scope, elem, &size, &writable);
    if (err) return err;
    if (!ioSize) return kAudio_ParamError;
    if (size == 0) { *ioSize = 0; return noErr; }
    if (!outData) return kAudio_ParamError;
    if (*ioSize < size) return kAudioUnitErr_InvalidPropertyValue;

    switch (prop) {
    case kAudioUnitProperty_StreamFormat:
        *(AudioStreamBasicDescription *)outData = scope == kAudioUnitScope_Input ? au->inFormat : au->outFormat;
        break;
    case kAudioUnitProperty_SampleRate:
        *(Float64 *)outData = (scope == kAudioUnitScope_Input ? au->inFormat : au->outFormat).mSampleRate;
        break;
    case kAudioUnitProperty_ShouldAllocateBuffer:
        *(UInt32 *)outData = au->shouldAllocate[scope == kAudioUnitScope_Input ? 0 : 1];
        break;
    case kAudioUnitProperty_ElementCount:
        *(UInt32 *)outData = 1;
        break;
    case kAudioUnitProperty_SetRenderCallback:
    case kAudioUnitProperty_MakeConnection:
        return kAudioUnitErr_InvalidProperty; // write-only
    case kAudioUnitProperty_ClassInfo:
        *(CFPropertyListRef *)outData = CopyClassInfo(au);
        break;
    case kAudioUnitProperty_MaximumFramesPerSlice:
        *(UInt32 *)outData = au->maxFrames;
        break;
    case kAudioUnitProperty_SupportedNumChannels: {
        AUChannelInfo *info = (AUChannelInfo *)outData;
        info[0].inChannels = 1; info[0].outChannels = 1;
        info[1].inChannels = 2; info[1].outChannels = 2;
        break;
    }
    case kAudioUnitProperty_Latency:
    case kAudioUnitProperty_TailTime:
        *(Float64 *)outData = 0;
        break;
    case kAudioUnitProperty_BypassEffect:
        *(UInt32 *)outData = au->bypass;
        break;
    case kAudioUnitProperty_InPlaceProcessing:
        *(UInt32 *)outData = au->inPlace;
        break;
    case kAudioUnitProperty_LastRenderError:
        *(OSStatus *)outData = noErr;
        break;
    case kAudioUnitProperty_CocoaUI: {
        CFBundleRef bundle = CFBundleGetBundleWithIdentifier(CFSTR(kBundleID));
        if (!bundle) return kAudioUnitErr_InvalidProperty;
        AudioUnitCocoaViewInfo *info = (AudioUnitCocoaViewInfo *)outData;
        info->mCocoaAUViewBundleLocation = CFBundleCopyBundleURL(bundle);
        info->mCocoaAUViewClass[0] = CFStringCreateCopy(NULL, CFSTR(kViewFactoryClass));
        break;
    }
    case kAudioUnitProperty_HostCallbacks:
        *(HostCallbackInfo *)outData = au->host;
        break;
    case kAudioUnitProperty_PresentPreset: {
        AUPreset *p = (AUPreset *)outData;
        p->presetNumber = au->preset.presetNumber;
        p->presetName = au->preset.presetName ? CFStringCreateCopy(NULL, au->preset.presetName) : NULL;
        break;
    }
    case kWaverProperty_Plugin:
        *(void **)outData = au->plugin;
        break;
    default:
        return kAudioUnitErr_InvalidProperty;
    }
    *ioSize = size;
    return noErr;
}

static OSStatus WaverSetProperty(void *self, AudioUnitPropertyID prop, AudioUnitScope scope, AudioUnitElement elem,
                                 const void *inData, UInt32 inSize) {
    WaverAU *au = (WaverAU *)self;
    UInt32 size = 0;
    Boolean writable = false;
    OSStatus err = PropertyInfo(au, prop, scope, elem, &size, &writable);
    if (err) return err;
    if (!writable) return kAudioUnitErr_PropertyNotWritable;

    // NULL data with a callback/connection property means "disconnect".
    if (prop == kAudioUnitProperty_SetRenderCallback) {
        if (inData && inSize >= size) au->inputCallback = *(const AURenderCallbackStruct *)inData;
        else memset(&au->inputCallback, 0, sizeof(au->inputCallback));
        au->hasConnection = false;
        return noErr;
    }
    if (prop == kAudioUnitProperty_MakeConnection) {
        if (inData && inSize >= size && ((const AudioUnitConnection *)inData)->sourceAudioUnit) {
            au->connection = *(const AudioUnitConnection *)inData;
            au->hasConnection = true;
            memset(&au->inputCallback, 0, sizeof(au->inputCallback));
        } else {
            au->hasConnection = false;
        }
        return noErr;
    }
    if (!inData || inSize < size) return kAudio_ParamError;

    switch (prop) {
    case kAudioUnitProperty_StreamFormat: {
        const AudioStreamBasicDescription *f = inData;
        if (!FormatSupported(f)) return kAudioUnitErr_FormatNotSupported;
        AudioStreamBasicDescription *target = scope == kAudioUnitScope_Input ? &au->inFormat : &au->outFormat;
        if (au->initialized) {
            if (f->mChannelsPerFrame != target->mChannelsPerFrame || f->mSampleRate != target->mSampleRate)
                return kAudioUnitErr_Initialized;
            return noErr;
        }
        *target = MakeFormat(f->mSampleRate, f->mChannelsPerFrame);
        // Keep both sides on the same sample rate.
        AudioStreamBasicDescription *other = scope == kAudioUnitScope_Input ? &au->outFormat : &au->inFormat;
        bool otherChanged = other->mSampleRate != f->mSampleRate;
        other->mSampleRate = f->mSampleRate;
        NotifyListeners(au, prop, scope, 0);
        if (otherChanged)
            NotifyListeners(au, prop, scope == kAudioUnitScope_Input ? kAudioUnitScope_Output : kAudioUnitScope_Input, 0);
        return noErr;
    }
    case kAudioUnitProperty_SampleRate: {
        Float64 rate = *(const Float64 *)inData;
        if (rate <= 0) return kAudioUnitErr_InvalidPropertyValue;
        if (au->initialized) return rate == au->outFormat.mSampleRate ? noErr : kAudioUnitErr_Initialized;
        au->inFormat.mSampleRate = rate;
        au->outFormat.mSampleRate = rate;
        NotifyListeners(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0);
        NotifyListeners(au, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output, 0);
        return noErr;
    }
    case kAudioUnitProperty_ShouldAllocateBuffer:
        au->shouldAllocate[scope == kAudioUnitScope_Input ? 0 : 1] = *(const UInt32 *)inData;
        return noErr;
    case kAudioUnitProperty_ClassInfo:
        return RestoreClassInfo(au, *(const CFPropertyListRef *)inData);
    case kAudioUnitProperty_MaximumFramesPerSlice: {
        UInt32 frames = *(const UInt32 *)inData;
        if (frames == 0) return kAudioUnitErr_InvalidPropertyValue;
        if (frames == au->maxFrames) return noErr;
        au->maxFrames = frames;
        if (au->initialized) { err = AllocateBuffers(au); if (err) return err; }
        NotifyListeners(au, prop, kAudioUnitScope_Global, 0);
        return noErr;
    }
    case kAudioUnitProperty_BypassEffect:
        au->bypass = *(const UInt32 *)inData;
        NotifyListeners(au, prop, kAudioUnitScope_Global, 0);
        return noErr;
    case kAudioUnitProperty_InPlaceProcessing:
        au->inPlace = *(const UInt32 *)inData;
        return noErr;
    case kAudioUnitProperty_HostCallbacks:
        memset(&au->host, 0, sizeof(au->host));
        memcpy(&au->host, inData, inSize < sizeof(HostCallbackInfo) ? inSize : sizeof(HostCallbackInfo));
        au->hasHost = true;
        return noErr;
    case kAudioUnitProperty_PresentPreset: {
        const AUPreset *p = inData;
        if (p->presetNumber >= 0) return kAudioUnitErr_InvalidPropertyValue; // no factory presets
        if (au->preset.presetName) CFRelease(au->preset.presetName);
        au->preset.presetNumber = p->presetNumber;
        au->preset.presetName = p->presetName ? CFStringCreateCopy(NULL, p->presetName) : CFSTR("Untitled");
        NotifyListeners(au, prop, kAudioUnitScope_Global, 0);
        return noErr;
    }
    default:
        return kAudioUnitErr_InvalidProperty;
    }
}

static OSStatus WaverAddPropertyListener(void *self, AudioUnitPropertyID prop, AudioUnitPropertyListenerProc proc, void *refCon) {
    WaverAU *au = (WaverAU *)self;
    if (au->listenerCount >= kMaxListeners) return kAudio_MemFullError;
    au->listeners[au->listenerCount++] = (Listener){prop, proc, refCon};
    return noErr;
}

static void RemoveListeners(WaverAU *au, AudioUnitPropertyID prop, AudioUnitPropertyListenerProc proc, bool matchRef, void *refCon) {
    int w = 0;
    for (int i = 0; i < au->listenerCount; i++) {
        Listener l = au->listeners[i];
        bool match = l.prop == prop && l.proc == proc && (!matchRef || l.refCon == refCon);
        if (!match) au->listeners[w++] = l;
    }
    au->listenerCount = w;
}

static OSStatus WaverRemovePropertyListener(void *self, AudioUnitPropertyID prop, AudioUnitPropertyListenerProc proc) {
    RemoveListeners((WaverAU *)self, prop, proc, false, NULL);
    return noErr;
}

static OSStatus WaverRemovePropertyListenerWithUserData(void *self, AudioUnitPropertyID prop, AudioUnitPropertyListenerProc proc, void *refCon) {
    RemoveListeners((WaverAU *)self, prop, proc, true, refCon);
    return noErr;
}

static OSStatus WaverAddRenderNotify(void *self, AURenderCallback proc, void *refCon) {
    WaverAU *au = (WaverAU *)self;
    if (au->notifyCount >= kMaxNotifies) return kAudio_MemFullError;
    au->notifies[au->notifyCount++] = (RenderNotify){proc, refCon};
    return noErr;
}

static OSStatus WaverRemoveRenderNotify(void *self, AURenderCallback proc, void *refCon) {
    WaverAU *au = (WaverAU *)self;
    int w = 0;
    for (int i = 0; i < au->notifyCount; i++) {
        if (!(au->notifies[i].proc == proc && au->notifies[i].refCon == refCon)) au->notifies[w++] = au->notifies[i];
    }
    au->notifyCount = w;
    return noErr;
}

// MARK: - Parameters (none)

static OSStatus WaverGetParameter(void *self, AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement elem, AudioUnitParameterValue *value) {
    return kAudioUnitErr_InvalidParameter;
}

static OSStatus WaverSetParameter(void *self, AudioUnitParameterID id, AudioUnitScope scope, AudioUnitElement elem, AudioUnitParameterValue value, UInt32 offset) {
    return kAudioUnitErr_InvalidParameter;
}

static OSStatus WaverScheduleParameters(void *self, const AudioUnitParameterEvent *events, UInt32 count) {
    return noErr;
}

// MARK: - Render

static int32_t TransportState(WaverAU *au) {
    if (!au->hasHost) return -1;
    Boolean playing = false, changed = false, cycling = false, recording = false;
    Float64 sample = 0, cycleStart = 0, cycleEnd = 0;
    if (au->host.transportStateProc2) {
        if (au->host.transportStateProc2(au->host.hostUserData, &playing, &recording, &changed, &sample, &cycling, &cycleStart, &cycleEnd) == noErr)
            return playing ? 1 : 0;
    } else if (au->host.transportStateProc) {
        if (au->host.transportStateProc(au->host.hostUserData, &playing, &changed, &sample, &cycling, &cycleStart, &cycleEnd) == noErr)
            return playing ? 1 : 0;
    }
    return -1;
}

static OSStatus WaverRender(void *self, AudioUnitRenderActionFlags *ioFlags, const AudioTimeStamp *ts,
                            UInt32 bus, UInt32 frames, AudioBufferList *ioData) {
    WaverAU *au = (WaverAU *)self;
    if (!au->initialized || !au->storage) return kAudioUnitErr_Uninitialized;
    if (bus != 0) return kAudioUnitErr_InvalidElement;
    if (frames > au->maxFrames) return kAudioUnitErr_TooManyFramesToProcess;
    if (!ioData || !ioFlags) return kAudio_ParamError;

    for (int i = 0; i < au->notifyCount; i++) {
        AudioUnitRenderActionFlags f = *ioFlags | kAudioUnitRenderAction_PreRender;
        au->notifies[i].proc(au->notifies[i].refCon, &f, ts, bus, frames, ioData);
    }

    // Pull input into our own buffers.
    UInt32 channels = au->inFormat.mChannelsPerFrame;
    AudioBufferList *pull = &au->pull.list;
    pull->mNumberBuffers = channels;
    for (UInt32 c = 0; c < channels; c++) {
        pull->mBuffers[c].mNumberChannels = 1;
        pull->mBuffers[c].mDataByteSize = frames * sizeof(float);
        pull->mBuffers[c].mData = au->storage + (size_t)c * au->maxFrames;
    }
    AudioUnitRenderActionFlags pullFlags = 0;
    OSStatus err;
    if (au->inputCallback.inputProc) {
        err = au->inputCallback.inputProc(au->inputCallback.inputProcRefCon, &pullFlags, ts, 0, frames, pull);
    } else if (au->hasConnection) {
        err = AudioUnitRender(au->connection.sourceAudioUnit, &pullFlags, ts, au->connection.sourceOutputNumber, frames, pull);
    } else {
        err = kAudioUnitErr_NoConnection;
    }

    if (err == noErr) {
        // Pass-through to the output.
        for (UInt32 c = 0; c < ioData->mNumberBuffers; c++) {
            AudioBuffer *out = &ioData->mBuffers[c];
            const AudioBuffer *in = &pull->mBuffers[c < pull->mNumberBuffers ? c : pull->mNumberBuffers - 1];
            if (out->mData == NULL) {
                out->mData = in->mData;
            } else if (out->mData != in->mData) {
                memcpy(out->mData, in->mData, frames * sizeof(float));
            }
            out->mDataByteSize = frames * sizeof(float);
        }
        if (pullFlags & kAudioUnitRenderAction_OutputIsSilence) *ioFlags |= kAudioUnitRenderAction_OutputIsSilence;

        const float *left = pull->mBuffers[0].mData;
        const float *right = pull->mNumberBuffers > 1 ? pull->mBuffers[1].mData : left;
        WaverPluginProcess(au->plugin, left, right, frames, TransportState(au));
    }

    for (int i = 0; i < au->notifyCount; i++) {
        AudioUnitRenderActionFlags f = *ioFlags | kAudioUnitRenderAction_PostRender;
        if (err) f |= kAudioUnitRenderAction_PostRenderError;
        au->notifies[i].proc(au->notifies[i].refCon, &f, ts, bus, frames, ioData);
    }
    return err;
}

// MARK: - Dispatch

static AudioComponentMethod WaverLookup(SInt16 selector) {
    switch (selector) {
    case kAudioUnitInitializeSelect: return (AudioComponentMethod)WaverInitialize;
    case kAudioUnitUninitializeSelect: return (AudioComponentMethod)WaverUninitialize;
    case kAudioUnitGetPropertyInfoSelect: return (AudioComponentMethod)WaverGetPropertyInfo;
    case kAudioUnitGetPropertySelect: return (AudioComponentMethod)WaverGetProperty;
    case kAudioUnitSetPropertySelect: return (AudioComponentMethod)WaverSetProperty;
    case kAudioUnitAddPropertyListenerSelect: return (AudioComponentMethod)WaverAddPropertyListener;
    case kAudioUnitRemovePropertyListenerSelect: return (AudioComponentMethod)WaverRemovePropertyListener;
    case kAudioUnitRemovePropertyListenerWithUserDataSelect: return (AudioComponentMethod)WaverRemovePropertyListenerWithUserData;
    case kAudioUnitAddRenderNotifySelect: return (AudioComponentMethod)WaverAddRenderNotify;
    case kAudioUnitRemoveRenderNotifySelect: return (AudioComponentMethod)WaverRemoveRenderNotify;
    case kAudioUnitGetParameterSelect: return (AudioComponentMethod)WaverGetParameter;
    case kAudioUnitSetParameterSelect: return (AudioComponentMethod)WaverSetParameter;
    case kAudioUnitScheduleParametersSelect: return (AudioComponentMethod)WaverScheduleParameters;
    case kAudioUnitRenderSelect: return (AudioComponentMethod)WaverRender;
    case kAudioUnitResetSelect: return (AudioComponentMethod)WaverReset;
    default: return NULL;
    }
}

__attribute__((visibility("default")))
void *WaverAUFactory(const AudioComponentDescription *desc) {
    WaverAU *au = calloc(1, sizeof(WaverAU));
    if (!au) return NULL;
    au->iface.Open = WaverOpen;
    au->iface.Close = WaverClose;
    au->iface.Lookup = WaverLookup;
    au->iface.reserved = NULL;
    return au;
}
