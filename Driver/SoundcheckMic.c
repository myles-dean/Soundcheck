//
//  SoundcheckMic.c
//  Soundcheck's virtual microphone: an AudioServerPlugIn (HAL plug-in) that coreaudiod loads.
//
//  Copyright (c) 2026 Myles Dean. MIT License, see LICENSE.
//
//  The plug-in publishes two devices that share one clock and one ring buffer:
//
//    "Soundcheck Mic"       Input only, visible. Apps like Zoom or Discord pick it as their
//                           microphone.
//    "Soundcheck Mic Feed"  Output only, hidden. Soundcheck plays its mix (the real mic plus
//                           the apps the user chose) into it.
//
//  What the feed is given for sample time T, the microphone hands out at sample time T. Both
//  devices report the same zero time stamps (one anchor, one period), so a sample time means the
//  same instant on both. The Host writes output ahead of "now" and reads input from behind it, so
//  the microphone naturally runs a buffer or two behind the feed.
//
//  This code runs inside coreaudiod's driver host: a crash or a bad answer here breaks audio for
//  the whole Mac. Every entry point checks its arguments, sizes are checked before anything is
//  written to a caller's buffer, and the IO path neither allocates nor takes locks.
//

#include <CoreAudio/AudioServerPlugIn.h>
#include <mach/mach_time.h>
#include <os/lock.h>
#include <math.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
#include <string.h>

#pragma mark - Constants

// Object IDs. The plug-in's own ID is fixed by Core Audio; the rest are ours to choose.
enum {
    kObjectID_PlugIn     = kAudioObjectPlugInObject,
    kObjectID_Mic        = 2,
    kObjectID_MicStream  = 3,
    kObjectID_Feed       = 4,
    kObjectID_FeedStream = 5
};

#define kSampleRate     48000.0
#define kChannels       2u
#define kBytesPerFrame  ((UInt32)(kChannels * sizeof(Float32)))

// Frames in the shared ring buffer; also the zero time stamp period. A power of two, so a sample
// time (negative ones included) maps to a ring position with a mask. 65536 frames is 1.37 s.
#define kRingFrames     65536u
#define kRingMask       (kRingFrames - 1u)
_Static_assert((kRingFrames & kRingMask) == 0, "The ring size must be a power of two");
_Static_assert(kRingFrames >= 10923, "Core Audio's minimum zero time stamp period is 10923 frames");

// Devices with the same nonzero clock domain can be synchronised in hardware. Ours share a clock
// outright, so an aggregate of the two needs no drift correction.
#define kClockDomain    0x5363686Bu // 'Schk'

// Sample times come in as Float64. They're turned into frame numbers only within +/- 2^60 (24
// million years at 48 kHz), which keeps all the frame arithmetic below far from overflowing.
#define kMaxSampleTime  1152921504606846976.0

// gFeedEnd before the feed has written anything since the clock (re)started.
#define kNoFeedData     INT64_MIN

#define kManufacturer   CFSTR("Soundcheck")

#pragma mark - Devices

typedef struct {
    AudioObjectID               deviceID;
    AudioObjectID               streamID;
    CFStringRef                 name;
    CFStringRef                 uid;
    CFStringRef                 modelUID;
    AudioObjectPropertyScope    scope;          // the one direction the device has
    UInt32                      direction;      // kAudioStreamPropertyDirection: 1 input, 0 output
    UInt32                      terminalType;
    UInt32                      ioOperation;    // the one IO operation the device performs
    UInt32                      canBeDefault;   // as the default device for its direction
    UInt32                      isHidden;
} DeviceInfo;

enum { kMic = 0, kFeed = 1, kDeviceCount = 2 };

static const DeviceInfo gDevices[kDeviceCount] = {
    [kMic] = {
        .deviceID       = kObjectID_Mic,
        .streamID       = kObjectID_MicStream,
        .name           = CFSTR("Soundcheck Mic"),
        .uid            = CFSTR("com.mylesdean.Soundcheck.Microphone"),
        .modelUID       = CFSTR("com.mylesdean.Soundcheck.Microphone.model"),
        .scope          = kAudioObjectPropertyScopeInput,
        .direction      = 1,
        .terminalType   = kAudioStreamTerminalTypeMicrophone,
        .ioOperation    = kAudioServerPlugInIOOperationReadInput,
        .canBeDefault   = 1,
        .isHidden       = 0
    },
    [kFeed] = {
        .deviceID       = kObjectID_Feed,
        .streamID       = kObjectID_FeedStream,
        .name           = CFSTR("Soundcheck Mic Feed"),
        .uid            = CFSTR("com.mylesdean.Soundcheck.MicrophoneFeed"),
        .modelUID       = CFSTR("com.mylesdean.Soundcheck.MicrophoneFeed.model"),
        .scope          = kAudioObjectPropertyScopeOutput,
        .direction      = 0,
        .terminalType   = kAudioStreamTerminalTypeSpeaker,
        .ioOperation    = kAudioServerPlugInIOOperationWriteMix,
        .canBeDefault   = 0,
        .isHidden       = 1
    }
};

// Both streams: interleaved stereo Float32 at 48 kHz, and nothing else.
static const AudioStreamBasicDescription gFormat = {
    .mSampleRate        = kSampleRate,
    .mFormatID          = kAudioFormatLinearPCM,
    .mFormatFlags       = kAudioFormatFlagsNativeFloatPacked,
    .mBytesPerPacket    = kBytesPerFrame,
    .mFramesPerPacket   = 1,
    .mBytesPerFrame     = kBytesPerFrame,
    .mChannelsPerFrame  = kChannels,
    .mBitsPerChannel    = 32,
    .mReserved          = 0
};

#pragma mark - State

static AudioServerPlugInHostRef gHost;      // unused: nothing here changes at runtime
static _Atomic UInt32           gRefCount;

// Guards StartIO/StopIO, which change the counts and may restart the shared clock.
static os_unfair_lock           gStateLock = OS_UNFAIR_LOCK_INIT;
static _Atomic UInt32           gIORunning[kDeviceCount];   // StartIO calls minus StopIO calls

// The shared clock: host time of sample time 0, and host ticks per frame (set by the factory).
static _Atomic UInt64           gAnchorHostTime;
static Float64                  gHostTicksPerFrame;

// The shared ring buffer. For every sample time t in [gFeedEnd - kRingFrames, gFeedEnd), the
// frame at ring position t holds what the feed was given for t (or silence). Only the feed's IO
// thread moves gFeedEnd, and it publishes with release after writing the frames; the
// microphone's IO thread reads it with acquire before copying them out.
static _Atomic SInt64           gFeedEnd = kNoFeedData;
static Float32                  gRing[kRingFrames * kChannels];

#pragma mark - Interface

static HRESULT  SoundcheckMic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface);
static ULONG    SoundcheckMic_AddRef(void* inDriver);
static ULONG    SoundcheckMic_Release(void* inDriver);
static OSStatus SoundcheckMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost);
static OSStatus SoundcheckMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID);
static OSStatus SoundcheckMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID);
static OSStatus SoundcheckMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus SoundcheckMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo);
static OSStatus SoundcheckMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static OSStatus SoundcheckMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo);
static Boolean  SoundcheckMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress);
static OSStatus SoundcheckMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable);
static OSStatus SoundcheckMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize);
static OSStatus SoundcheckMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData);
static OSStatus SoundcheckMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData);
static OSStatus SoundcheckMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SoundcheckMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID);
static OSStatus SoundcheckMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) CA_REALTIME_API;
static OSStatus SoundcheckMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace);
static OSStatus SoundcheckMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) CA_REALTIME_API;
static OSStatus SoundcheckMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) CA_REALTIME_API;
static OSStatus SoundcheckMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) CA_REALTIME_API;

static AudioServerPlugInDriverInterface gDriverInterface = {
    NULL,
    SoundcheckMic_QueryInterface,
    SoundcheckMic_AddRef,
    SoundcheckMic_Release,
    SoundcheckMic_Initialize,
    SoundcheckMic_CreateDevice,
    SoundcheckMic_DestroyDevice,
    SoundcheckMic_AddDeviceClient,
    SoundcheckMic_RemoveDeviceClient,
    SoundcheckMic_PerformDeviceConfigurationChange,
    SoundcheckMic_AbortDeviceConfigurationChange,
    SoundcheckMic_HasProperty,
    SoundcheckMic_IsPropertySettable,
    SoundcheckMic_GetPropertyDataSize,
    SoundcheckMic_GetPropertyData,
    SoundcheckMic_SetPropertyData,
    SoundcheckMic_StartIO,
    SoundcheckMic_StopIO,
    SoundcheckMic_GetZeroTimeStamp,
    SoundcheckMic_WillDoIOOperation,
    SoundcheckMic_BeginIOOperation,
    SoundcheckMic_DoIOOperation,
    SoundcheckMic_EndIOOperation
};
static AudioServerPlugInDriverInterface*    gDriverInterfacePtr = &gDriverInterface;
static AudioServerPlugInDriverRef           gDriverRef = &gDriverInterfacePtr;

#pragma mark - Helpers

static inline UInt32 MinU32(UInt32 a, UInt32 b) { return a < b ? a : b; }
static inline SInt64 MinS64(SInt64 a, SInt64 b) { return a < b ? a : b; }
static inline SInt64 MaxS64(SInt64 a, SInt64 b) { return a > b ? a : b; }

static const DeviceInfo* DeviceWithID(AudioObjectID inObjectID) CA_REALTIME_API {
    for (UInt32 i = 0; i < kDeviceCount; i++) {
        if (gDevices[i].deviceID == inObjectID) return &gDevices[i];
    }
    return NULL;
}

static const DeviceInfo* DeviceWithStreamID(AudioObjectID inObjectID) {
    for (UInt32 i = 0; i < kDeviceCount; i++) {
        if (gDevices[i].streamID == inObjectID) return &gDevices[i];
    }
    return NULL;
}

static size_t DeviceIndex(const DeviceInfo* inDevice) {
    return (size_t)(inDevice - gDevices);
}

// mach_absolute_time() reads the commpage: fine on the IO thread, it just isn't annotated as such.
static inline UInt64 HostTimeNow(void) CA_REALTIME_API {
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wfunction-effects"
    return mach_absolute_time();
#pragma clang diagnostic pop
}

static void SetUpHostClock(void) {
    mach_timebase_info_data_t timebase = { 0, 0 };
    if (mach_timebase_info(&timebase) != KERN_SUCCESS || timebase.numer == 0 || timebase.denom == 0) {
        timebase.numer = 1;
        timebase.denom = 1;
    }
    Float64 ticksPerSecond = 1.0e9 * (Float64)timebase.denom / (Float64)timebase.numer;
    gHostTicksPerFrame = ticksPerSecond / kSampleRate;
}

static bool IsOurFormat(const AudioStreamBasicDescription* inFormat) {
    return inFormat->mSampleRate > kSampleRate - 0.5 && inFormat->mSampleRate < kSampleRate + 0.5
        && inFormat->mFormatID == gFormat.mFormatID
        && (inFormat->mFormatFlags & ~(AudioFormatFlags)kAudioFormatFlagIsAlignedHigh) == gFormat.mFormatFlags
        && inFormat->mBytesPerPacket == gFormat.mBytesPerPacket
        && inFormat->mFramesPerPacket == gFormat.mFramesPerPacket
        && inFormat->mBytesPerFrame == gFormat.mBytesPerFrame
        && inFormat->mChannelsPerFrame == gFormat.mChannelsPerFrame
        && inFormat->mBitsPerChannel == gFormat.mBitsPerChannel;
}

#pragma mark - Ring Buffer

static inline UInt32 RingIndex(SInt64 inFrame) CA_REALTIME_API {
    return (UInt32)((UInt64)inFrame & kRingMask);
}

// Each of these touches `inCount` frames (at most a ring's worth) from sample time `inFrame`,
// wrapping around the end of the ring.

static void RingZero(SInt64 inFrame, UInt32 inCount) CA_REALTIME_API {
    UInt32 count = MinU32(inCount, kRingFrames);
    UInt32 start = RingIndex(inFrame);
    UInt32 first = MinU32(count, kRingFrames - start);
    memset(&gRing[(size_t)start * kChannels], 0, (size_t)first * kBytesPerFrame);
    memset(&gRing[0], 0, (size_t)(count - first) * kBytesPerFrame);
}

static void RingWrite(SInt64 inFrame, UInt32 inCount, const Float32* inSource) CA_REALTIME_API {
    UInt32 count = MinU32(inCount, kRingFrames);
    UInt32 start = RingIndex(inFrame);
    UInt32 first = MinU32(count, kRingFrames - start);
    memcpy(&gRing[(size_t)start * kChannels], inSource, (size_t)first * kBytesPerFrame);
    memcpy(&gRing[0], inSource + (size_t)first * kChannels, (size_t)(count - first) * kBytesPerFrame);
}

// Copies frames out and silences them in the ring, so nothing is ever heard twice.
static void RingTake(SInt64 inFrame, UInt32 inCount, Float32* outDestination) CA_REALTIME_API {
    UInt32 count = MinU32(inCount, kRingFrames);
    UInt32 start = RingIndex(inFrame);
    UInt32 first = MinU32(count, kRingFrames - start);
    memcpy(outDestination, &gRing[(size_t)start * kChannels], (size_t)first * kBytesPerFrame);
    memset(&gRing[(size_t)start * kChannels], 0, (size_t)first * kBytesPerFrame);
    memcpy(outDestination + (size_t)first * kChannels, &gRing[0], (size_t)(count - first) * kBytesPerFrame);
    memset(&gRing[0], 0, (size_t)(count - first) * kBytesPerFrame);
}

static bool FrameForSampleTime(Float64 inSampleTime, SInt64* outFrame) CA_REALTIME_API {
    // Also false for NaN.
    if (!(inSampleTime > -kMaxSampleTime && inSampleTime < kMaxSampleTime)) return false;
    Float64 whole = floor(inSampleTime);
    *outFrame = (SInt64)whole;
    return true;
}

// The feed's WriteMix: store the mix for [start, start + frames).
static void FeedWrite(Float64 inSampleTime, UInt32 inFrames, const Float32* inSource) CA_REALTIME_API {
    SInt64 start;
    if (inFrames == 0 || !FrameForSampleTime(inSampleTime, &start)) return;
    UInt32 frames = inFrames;
    const Float32* source = inSource;
    if (frames > kRingFrames) {
        // Only the newest ring's worth can be kept.
        source += (size_t)(frames - kRingFrames) * kChannels;
        start += frames - kRingFrames;
        frames = kRingFrames;
    }

    SInt64 end = atomic_load_explicit(&gFeedEnd, memory_order_relaxed);
    if (end == kNoFeedData || start < end - (SInt64)kRingFrames) {
        // First write since the clock started (the ring is already silent), or the timeline jumped
        // back by more than the ring holds. In the second case nothing in the ring belongs to the
        // new timeline: hide it from the microphone, then clear it.
        if (end != kNoFeedData) {
            atomic_store_explicit(&gFeedEnd, kNoFeedData, memory_order_release);
            RingZero(0, kRingFrames);
        }
        end = start;
    } else if (start > end) {
        // A gap since the last write (the feed was stopped, or the Host skipped ahead). Silence it
        // so that audio from a ring's length ago can't be played in its place.
        SInt64 gapStart = MaxS64(end, start - (SInt64)kRingFrames);
        RingZero(gapStart, (UInt32)(start - gapStart));
    }
    // A small step back (start < end) just overwrites frames that are still in the window.

    RingWrite(start, frames, source);
    atomic_store_explicit(&gFeedEnd, MaxS64(end, start + (SInt64)frames), memory_order_release);
}

// The microphone's ReadInput: hand out [start, start + frames), silence for anything the feed
// hasn't written (or wrote too long ago).
static void MicRead(Float64 inSampleTime, UInt32 inFrames, Float32* outDestination) CA_REALTIME_API {
    SInt64 end = atomic_load_explicit(&gFeedEnd, memory_order_acquire);
    SInt64 start;
    if (end == kNoFeedData || !FrameForSampleTime(inSampleTime, &start)) {
        memset(outDestination, 0, (size_t)inFrames * kBytesPerFrame);
        return;
    }
    SInt64 from = MaxS64(start, end - (SInt64)kRingFrames);
    SInt64 to = MinS64(start + (SInt64)inFrames, end);
    if (from >= to) {
        memset(outDestination, 0, (size_t)inFrames * kBytesPerFrame);
        return;
    }
    UInt32 lead = (UInt32)(from - start);
    UInt32 count = (UInt32)(to - from);     // at most kRingFrames: the window is that wide
    UInt32 tail = inFrames - lead - count;
    memset(outDestination, 0, (size_t)lead * kBytesPerFrame);
    RingTake(from, count, outDestination + (size_t)lead * kChannels);
    memset(outDestination + (size_t)(lead + count) * kChannels, 0, (size_t)tail * kBytesPerFrame);
}

// Called with gStateLock held when neither device is running, so no IO thread is using the ring.
static void RestartClock(void) {
    memset(gRing, 0, sizeof gRing);
    atomic_store_explicit(&gFeedEnd, kNoFeedData, memory_order_relaxed);
    atomic_store_explicit(&gAnchorHostTime, mach_absolute_time(), memory_order_release);
}

#pragma mark - Property Plumbing

// One request serves HasProperty, IsPropertySettable, GetPropertyDataSize and GetPropertyData, so
// the size reported and the data returned can't disagree.
typedef struct {
    const AudioObjectPropertyAddress*   address;
    UInt32                              qualifierSize;
    const void*                         qualifier;
    UInt32                              capacity;   // bytes available at data
    void*                               data;       // NULL when only the size is wanted
    UInt32                              size;       // out: the value's size, or bytes written
} PropertyRequest;

static OSStatus ReturnValue(PropertyRequest* ioRequest, const void* inValue, UInt32 inSize) {
    if (ioRequest->data != NULL) {
        if (ioRequest->capacity < inSize) return kAudioHardwareBadPropertySizeError;
        memcpy(ioRequest->data, inValue, inSize);
    }
    ioRequest->size = inSize;
    return kAudioHardwareNoError;
}

static OSStatus ReturnUInt32(PropertyRequest* ioRequest, UInt32 inValue) {
    return ReturnValue(ioRequest, &inValue, (UInt32)sizeof inValue);
}

static OSStatus ReturnFloat64(PropertyRequest* ioRequest, Float64 inValue) {
    return ReturnValue(ioRequest, &inValue, (UInt32)sizeof inValue);
}

// The caller releases the string; CFSTR constants ignore retain and release.
static OSStatus ReturnString(PropertyRequest* ioRequest, CFStringRef inValue) {
    return ReturnValue(ioRequest, &inValue, (UInt32)sizeof inValue);
}

// Arrays: as many whole items as fit.
static OSStatus ReturnArray(PropertyRequest* ioRequest, const void* inItems, UInt32 inItemSize, UInt32 inCount) {
    UInt32 count = inCount;
    if (ioRequest->data != NULL) {
        count = MinU32(count, ioRequest->capacity / inItemSize);
        if (count > 0) memcpy(ioRequest->data, inItems, (size_t)count * inItemSize);
    }
    ioRequest->size = count * inItemSize;
    return kAudioHardwareNoError;
}

// kAudioObjectPropertyOwnedObjects may carry a qualifier: a list of classes to filter by.
static bool ClassIsWanted(const PropertyRequest* inRequest, AudioClassID inClass) {
    if (inRequest->qualifier == NULL || inRequest->qualifierSize < sizeof(AudioClassID)) return true;
    UInt32 count = inRequest->qualifierSize / (UInt32)sizeof(AudioClassID);
    for (UInt32 i = 0; i < count; i++) {
        AudioClassID wanted;
        memcpy(&wanted, (const UInt8*)inRequest->qualifier + (size_t)i * sizeof(AudioClassID), sizeof wanted);
        if (wanted == inClass || wanted == kAudioObjectClassID) return true;
    }
    return false;
}

static OSStatus ReturnOwnedObjects(PropertyRequest* ioRequest, const AudioObjectID* inIDs, AudioClassID inClass, UInt32 inCount) {
    AudioObjectID ids[kDeviceCount];
    UInt32 count = 0;
    if (ClassIsWanted(ioRequest, inClass)) {
        for (UInt32 i = 0; i < inCount && count < kDeviceCount; i++) ids[count++] = inIDs[i];
    }
    return ReturnArray(ioRequest, ids, (UInt32)sizeof(AudioObjectID), count);
}

static AudioObjectID DeviceIDForUID(CFStringRef inUID) {
    if (inUID == NULL || CFGetTypeID(inUID) != CFStringGetTypeID()) return kAudioObjectUnknown;
    for (UInt32 i = 0; i < kDeviceCount; i++) {
        if (CFStringCompare(inUID, gDevices[i].uid, 0) == kCFCompareEqualTo) return gDevices[i].deviceID;
    }
    return kAudioObjectUnknown;
}

#pragma mark - Plug-in Properties

static OSStatus PlugInProperty(PropertyRequest* ioRequest) {
    static const AudioObjectID kDeviceIDs[kDeviceCount] = { kObjectID_Mic, kObjectID_Feed };

    switch (ioRequest->address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            return ReturnUInt32(ioRequest, kAudioObjectClassID);
        case kAudioObjectPropertyClass:
            return ReturnUInt32(ioRequest, kAudioPlugInClassID);
        case kAudioObjectPropertyOwner:
            return ReturnUInt32(ioRequest, kAudioObjectUnknown);
        case kAudioObjectPropertyManufacturer:
            return ReturnString(ioRequest, kManufacturer);
        case kAudioObjectPropertyOwnedObjects:
            return ReturnOwnedObjects(ioRequest, kDeviceIDs, kAudioDeviceClassID, kDeviceCount);
        case kAudioPlugInPropertyDeviceList:
            return ReturnArray(ioRequest, kDeviceIDs, (UInt32)sizeof(AudioObjectID), kDeviceCount);
        case kAudioPlugInPropertyTranslateUIDToDevice: {
            // The qualifier is the UID, a CFStringRef. Unknown UIDs map to kAudioObjectUnknown.
            AudioObjectID found = kAudioObjectUnknown;
            if (ioRequest->data != NULL) {
                if (ioRequest->qualifier == NULL || ioRequest->qualifierSize < sizeof(CFStringRef)) {
                    return kAudioHardwareBadPropertySizeError;
                }
                CFStringRef uid;
                memcpy(&uid, ioRequest->qualifier, sizeof uid);
                found = DeviceIDForUID(uid);
            }
            return ReturnUInt32(ioRequest, found);
        }
        case kAudioPlugInPropertyResourceBundle:
            // Relative to the plug-in's bundle: the bundle itself.
            return ReturnString(ioRequest, CFSTR(""));
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Device Properties

static OSStatus DeviceProperty(const DeviceInfo* inDevice, PropertyRequest* ioRequest) {
    AudioObjectPropertyScope scope = ioRequest->address->mScope;
    // Streams exist only in the device's own direction (and in the global scope, which covers all).
    bool inDirection = scope == kAudioObjectPropertyScopeGlobal || scope == inDevice->scope;

    switch (ioRequest->address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            return ReturnUInt32(ioRequest, kAudioObjectClassID);
        case kAudioObjectPropertyClass:
            return ReturnUInt32(ioRequest, kAudioDeviceClassID);
        case kAudioObjectPropertyOwner:
            return ReturnUInt32(ioRequest, kObjectID_PlugIn);
        case kAudioObjectPropertyName:
            return ReturnString(ioRequest, inDevice->name);
        case kAudioObjectPropertyManufacturer:
            return ReturnString(ioRequest, kManufacturer);
        case kAudioObjectPropertyOwnedObjects:
            // The stream; there are no controls.
            return ReturnOwnedObjects(ioRequest, &inDevice->streamID, kAudioStreamClassID, inDirection ? 1 : 0);
        case kAudioDevicePropertyDeviceUID:
            return ReturnString(ioRequest, inDevice->uid);
        case kAudioDevicePropertyModelUID:
            return ReturnString(ioRequest, inDevice->modelUID);
        case kAudioDevicePropertyTransportType:
            return ReturnUInt32(ioRequest, kAudioDeviceTransportTypeVirtual);
        case kAudioDevicePropertyRelatedDevices:
            return ReturnArray(ioRequest, &inDevice->deviceID, (UInt32)sizeof(AudioObjectID), 1);
        case kAudioDevicePropertyClockDomain:
            return ReturnUInt32(ioRequest, kClockDomain);
        case kAudioDevicePropertyDeviceIsAlive:
            return ReturnUInt32(ioRequest, 1);
        case kAudioDevicePropertyDeviceIsRunning: {
            UInt32 running = atomic_load_explicit(&gIORunning[DeviceIndex(inDevice)], memory_order_relaxed);
            return ReturnUInt32(ioRequest, running > 0 ? 1 : 0);
        }
        case kAudioDevicePropertyDeviceCanBeDefaultDevice:
            return ReturnUInt32(ioRequest, inDirection ? inDevice->canBeDefault : 0);
        case kAudioDevicePropertyDeviceCanBeDefaultSystemDevice:
            return ReturnUInt32(ioRequest, 0);
        case kAudioDevicePropertyLatency:
            return ReturnUInt32(ioRequest, 0);
        case kAudioDevicePropertyStreams:
            return ReturnArray(ioRequest, &inDevice->streamID, (UInt32)sizeof(AudioObjectID), inDirection ? 1 : 0);
        case kAudioObjectPropertyControlList:
            return ReturnArray(ioRequest, NULL, (UInt32)sizeof(AudioObjectID), 0);
        case kAudioDevicePropertySafetyOffset:
            return ReturnUInt32(ioRequest, 0);
        case kAudioDevicePropertyNominalSampleRate:
            return ReturnFloat64(ioRequest, kSampleRate);
        case kAudioDevicePropertyAvailableNominalSampleRates: {
            static const AudioValueRange kRates[] = { { kSampleRate, kSampleRate } };
            return ReturnArray(ioRequest, kRates, (UInt32)sizeof(AudioValueRange), 1);
        }
        case kAudioDevicePropertyIsHidden:
            return ReturnUInt32(ioRequest, inDevice->isHidden);
        case kAudioDevicePropertyPreferredChannelsForStereo: {
            static const UInt32 kStereo[2] = { 1, 2 };
            return ReturnArray(ioRequest, kStereo, (UInt32)sizeof(UInt32), 2);
        }
        case kAudioDevicePropertyPreferredChannelLayout: {
            // An AudioChannelLayout with room for both channel descriptions.
            struct {
                AudioChannelLayoutTag   mChannelLayoutTag;
                AudioChannelBitmap      mChannelBitmap;
                UInt32                  mNumberChannelDescriptions;
                AudioChannelDescription mChannelDescriptions[kChannels];
            } layout;
            _Static_assert(offsetof(__typeof__(layout), mChannelDescriptions) == offsetof(AudioChannelLayout, mChannelDescriptions),
                           "The stereo layout must match AudioChannelLayout");
            memset(&layout, 0, sizeof layout);
            layout.mChannelLayoutTag = kAudioChannelLayoutTag_UseChannelDescriptions;
            layout.mNumberChannelDescriptions = kChannels;
            layout.mChannelDescriptions[0].mChannelLabel = kAudioChannelLabel_Left;
            layout.mChannelDescriptions[1].mChannelLabel = kAudioChannelLabel_Right;
            return ReturnValue(ioRequest, &layout, (UInt32)sizeof layout);
        }
        case kAudioDevicePropertyZeroTimeStampPeriod:
            return ReturnUInt32(ioRequest, kRingFrames);
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

#pragma mark - Stream Properties

static OSStatus StreamProperty(const DeviceInfo* inDevice, PropertyRequest* ioRequest) {
    switch (ioRequest->address->mSelector) {
        case kAudioObjectPropertyBaseClass:
            return ReturnUInt32(ioRequest, kAudioObjectClassID);
        case kAudioObjectPropertyClass:
            return ReturnUInt32(ioRequest, kAudioStreamClassID);
        case kAudioObjectPropertyOwner:
            return ReturnUInt32(ioRequest, inDevice->deviceID);
        case kAudioObjectPropertyOwnedObjects:
            return ReturnArray(ioRequest, NULL, (UInt32)sizeof(AudioObjectID), 0);
        case kAudioStreamPropertyIsActive:
            return ReturnUInt32(ioRequest, 1);
        case kAudioStreamPropertyDirection:
            return ReturnUInt32(ioRequest, inDevice->direction);
        case kAudioStreamPropertyTerminalType:
            return ReturnUInt32(ioRequest, inDevice->terminalType);
        case kAudioStreamPropertyStartingChannel:
            return ReturnUInt32(ioRequest, 1);
        case kAudioStreamPropertyLatency:
            return ReturnUInt32(ioRequest, 0);
        case kAudioStreamPropertyVirtualFormat:
        case kAudioStreamPropertyPhysicalFormat:
            return ReturnValue(ioRequest, &gFormat, (UInt32)sizeof gFormat);
        case kAudioStreamPropertyAvailableVirtualFormats:
        case kAudioStreamPropertyAvailablePhysicalFormats: {
            static const AudioStreamRangedDescription kFormats[] = {
                { .mFormat = gFormat, .mSampleRateRange = { kSampleRate, kSampleRate } }
            };
            return ReturnArray(ioRequest, kFormats, (UInt32)sizeof(AudioStreamRangedDescription), 1);
        }
        default:
            return kAudioHardwareUnknownPropertyError;
    }
}

static OSStatus ObjectProperty(AudioObjectID inObjectID, PropertyRequest* ioRequest) {
    if (inObjectID == kObjectID_PlugIn) return PlugInProperty(ioRequest);
    const DeviceInfo* device = DeviceWithID(inObjectID);
    if (device != NULL) return DeviceProperty(device, ioRequest);
    device = DeviceWithStreamID(inObjectID);
    if (device != NULL) return StreamProperty(device, ioRequest);
    return kAudioHardwareBadObjectError;
}

#pragma mark - Factory

// Named in Info.plist's CFPlugInFactories. Hands out the one driver object.
__attribute__((visibility("default")))
void* SoundcheckMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID);

void* SoundcheckMic_Create(CFAllocatorRef inAllocator, CFUUIDRef inRequestedTypeUUID) {
    (void)inAllocator;
    if (inRequestedTypeUUID == NULL || !CFEqual(inRequestedTypeUUID, kAudioServerPlugInTypeUUID)) return NULL;
    SetUpHostClock();
    return gDriverRef;
}

#pragma mark - IUnknown

static HRESULT SoundcheckMic_QueryInterface(void* inDriver, REFIID inUUID, LPVOID* outInterface) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (outInterface == NULL) return kAudioHardwareIllegalOperationError;

    CFUUIDRef requested = CFUUIDCreateFromUUIDBytes(NULL, inUUID);
    if (requested == NULL) return kAudioHardwareIllegalOperationError;
    HRESULT result;
    // The driver interface is a subclass of IUnknown, so both are answered with the same object.
    if (CFEqual(requested, IUnknownUUID) || CFEqual(requested, kAudioServerPlugInDriverInterfaceUUID)) {
        SoundcheckMic_AddRef(inDriver);
        *outInterface = gDriverRef;
        result = S_OK;
    } else {
        *outInterface = NULL;
        result = E_NOINTERFACE;
    }
    CFRelease(requested);
    return result;
}

// The driver object is static, so the count only guards against going out of range.
static ULONG SoundcheckMic_AddRef(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    UInt32 count = atomic_load_explicit(&gRefCount, memory_order_relaxed);
    while (count < UINT32_MAX
           && !atomic_compare_exchange_weak_explicit(&gRefCount, &count, count + 1, memory_order_relaxed, memory_order_relaxed)) {}
    return count < UINT32_MAX ? count + 1 : count;
}

static ULONG SoundcheckMic_Release(void* inDriver) {
    if (inDriver != gDriverRef) return 0;
    UInt32 count = atomic_load_explicit(&gRefCount, memory_order_relaxed);
    while (count > 0
           && !atomic_compare_exchange_weak_explicit(&gRefCount, &count, count - 1, memory_order_relaxed, memory_order_relaxed)) {}
    return count > 0 ? count - 1 : 0;
}

#pragma mark - Basic Operations

static OSStatus SoundcheckMic_Initialize(AudioServerPlugInDriverRef inDriver, AudioServerPlugInHostRef inHost) {
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    // Nothing here ever changes on its own, so the plug-in never calls back into the Host (which
    // is also why a NULL host is tolerated).
    gHost = inHost;
    return kAudioHardwareNoError;
}

static OSStatus SoundcheckMic_CreateDevice(AudioServerPlugInDriverRef inDriver, CFDictionaryRef inDescription, const AudioServerPlugInClientInfo* inClientInfo, AudioObjectID* outDeviceObjectID) {
    (void)inDriver; (void)inDescription; (void)inClientInfo; (void)outDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SoundcheckMic_DestroyDevice(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID) {
    (void)inDriver; (void)inDeviceObjectID;
    return kAudioHardwareUnsupportedOperationError;
}

static OSStatus SoundcheckMic_AddDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (DeviceWithID(inDeviceObjectID) == NULL) return kAudioHardwareBadDeviceError;
    return kAudioHardwareNoError;
}

static OSStatus SoundcheckMic_RemoveDeviceClient(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, const AudioServerPlugInClientInfo* inClientInfo) {
    (void)inClientInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (DeviceWithID(inDeviceObjectID) == NULL) return kAudioHardwareBadDeviceError;
    return kAudioHardwareNoError;
}

// The devices never ask for a configuration change, so there's never one to perform or abort.
static OSStatus SoundcheckMic_PerformDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (DeviceWithID(inDeviceObjectID) == NULL) return kAudioHardwareBadDeviceError;
    return kAudioHardwareNoError;
}

static OSStatus SoundcheckMic_AbortDeviceConfigurationChange(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt64 inChangeAction, void* inChangeInfo) {
    (void)inChangeAction; (void)inChangeInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (DeviceWithID(inDeviceObjectID) == NULL) return kAudioHardwareBadDeviceError;
    return kAudioHardwareNoError;
}

#pragma mark - Property Operations

static Boolean SoundcheckMic_HasProperty(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef || inAddress == NULL) return false;
    PropertyRequest request = { .address = inAddress };
    return ObjectProperty(inObjectID, &request) == kAudioHardwareNoError;
}

static OSStatus SoundcheckMic_IsPropertySettable(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, Boolean* outIsSettable) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outIsSettable == NULL) return kAudioHardwareIllegalOperationError;
    PropertyRequest request = { .address = inAddress };
    OSStatus status = ObjectProperty(inObjectID, &request);
    // Nothing is settable: one format, one rate, no controls.
    if (status == kAudioHardwareNoError) *outIsSettable = false;
    return status;
}

static OSStatus SoundcheckMic_GetPropertyDataSize(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32* outDataSize) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL) return kAudioHardwareIllegalOperationError;
    PropertyRequest request = {
        .address = inAddress,
        .qualifierSize = inQualifierData != NULL ? inQualifierDataSize : 0,
        .qualifier = inQualifierData
    };
    OSStatus status = ObjectProperty(inObjectID, &request);
    if (status == kAudioHardwareNoError) *outDataSize = request.size;
    return status;
}

static OSStatus SoundcheckMic_GetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, UInt32* outDataSize, void* outData) {
    (void)inClientProcessID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL || outDataSize == NULL || outData == NULL) return kAudioHardwareIllegalOperationError;
    PropertyRequest request = {
        .address = inAddress,
        .qualifierSize = inQualifierData != NULL ? inQualifierDataSize : 0,
        .qualifier = inQualifierData,
        .capacity = inDataSize,
        .data = outData
    };
    OSStatus status = ObjectProperty(inObjectID, &request);
    if (status == kAudioHardwareNoError) *outDataSize = request.size;
    return status;
}

static OSStatus SoundcheckMic_SetPropertyData(AudioServerPlugInDriverRef inDriver, AudioObjectID inObjectID, pid_t inClientProcessID, const AudioObjectPropertyAddress* inAddress, UInt32 inQualifierDataSize, const void* inQualifierData, UInt32 inDataSize, const void* inData) {
    (void)inClientProcessID; (void)inQualifierDataSize; (void)inQualifierData;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (inAddress == NULL) return kAudioHardwareIllegalOperationError;
    PropertyRequest request = { .address = inAddress };
    OSStatus status = ObjectProperty(inObjectID, &request);
    if (status != kAudioHardwareNoError) return status;
    if (inData == NULL) return kAudioHardwareIllegalOperationError;

    // Nothing can change, but some apps set the rate or format without checking first, so setting
    // the value a property already has is accepted.
    if (DeviceWithID(inObjectID) != NULL && inAddress->mSelector == kAudioDevicePropertyNominalSampleRate) {
        Float64 rate;
        if (inDataSize < sizeof rate) return kAudioHardwareBadPropertySizeError;
        memcpy(&rate, inData, sizeof rate);
        return rate > kSampleRate - 0.5 && rate < kSampleRate + 0.5 ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    if (DeviceWithStreamID(inObjectID) != NULL
        && (inAddress->mSelector == kAudioStreamPropertyVirtualFormat || inAddress->mSelector == kAudioStreamPropertyPhysicalFormat)) {
        AudioStreamBasicDescription format;
        if (inDataSize < sizeof format) return kAudioHardwareBadPropertySizeError;
        memcpy(&format, inData, sizeof format);
        return IsOurFormat(&format) ? kAudioHardwareNoError : kAudioDeviceUnsupportedFormatError;
    }
    return kAudioHardwareUnsupportedOperationError;
}

#pragma mark - IO Operations

static OSStatus SoundcheckMic_StartIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    const DeviceInfo* device = DeviceWithID(inDeviceObjectID);
    if (device == NULL) return kAudioHardwareBadDeviceError;
    size_t index = DeviceIndex(device);

    OSStatus status = kAudioHardwareNoError;
    os_unfair_lock_lock(&gStateLock);
    UInt32 mine = atomic_load_explicit(&gIORunning[index], memory_order_relaxed);
    UInt32 other = atomic_load_explicit(&gIORunning[1 - index], memory_order_relaxed);
    if (mine == UINT32_MAX) {
        status = kAudioHardwareIllegalOperationError;
    } else {
        // The clock is shared: it starts with whichever device starts first and keeps going until
        // both have stopped, so the two timelines always line up.
        if (mine == 0 && other == 0) RestartClock();
        atomic_store_explicit(&gIORunning[index], mine + 1, memory_order_relaxed);
    }
    os_unfair_lock_unlock(&gStateLock);
    return status;
}

static OSStatus SoundcheckMic_StopIO(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    const DeviceInfo* device = DeviceWithID(inDeviceObjectID);
    if (device == NULL) return kAudioHardwareBadDeviceError;
    size_t index = DeviceIndex(device);

    OSStatus status = kAudioHardwareNoError;
    os_unfair_lock_lock(&gStateLock);
    UInt32 mine = atomic_load_explicit(&gIORunning[index], memory_order_relaxed);
    if (mine == 0) {
        status = kAudioHardwareNotRunningError;
    } else {
        atomic_store_explicit(&gIORunning[index], mine - 1, memory_order_relaxed);
    }
    os_unfair_lock_unlock(&gStateLock);
    return status;
}

static OSStatus SoundcheckMic_GetZeroTimeStamp(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, Float64* outSampleTime, UInt64* outHostTime, UInt64* outSeed) CA_REALTIME_API {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (DeviceWithID(inDeviceObjectID) == NULL) return kAudioHardwareBadDeviceError;
    if (outSampleTime == NULL || outHostTime == NULL || outSeed == NULL) return kAudioHardwareIllegalOperationError;

    // Worked out from the shared anchor rather than counted per device, so both devices give the
    // same answer at the same moment: the latest whole period that has begun.
    UInt64 anchor = atomic_load_explicit(&gAnchorHostTime, memory_order_acquire);
    UInt64 now = HostTimeNow();
    Float64 ticksPerPeriod = gHostTicksPerFrame * (Float64)kRingFrames;
    Float64 periods = 0;
    if (now > anchor && ticksPerPeriod > 0) periods = floor((Float64)(now - anchor) / ticksPerPeriod);
    *outSampleTime = periods * (Float64)kRingFrames;
    *outHostTime = anchor + (UInt64)(periods * ticksPerPeriod);
    *outSeed = 1;
    return kAudioHardwareNoError;
}

static OSStatus SoundcheckMic_WillDoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, Boolean* outWillDo, Boolean* outWillDoInPlace) {
    (void)inClientID;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    const DeviceInfo* device = DeviceWithID(inDeviceObjectID);
    if (device == NULL) return kAudioHardwareBadDeviceError;
    if (outWillDo == NULL || outWillDoInPlace == NULL) return kAudioHardwareIllegalOperationError;
    // The microphone only reads input, the feed only writes the mix, both in place.
    *outWillDo = inOperationID == device->ioOperation;
    *outWillDoInPlace = true;
    return kAudioHardwareNoError;
}

static OSStatus SoundcheckMic_BeginIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) CA_REALTIME_API {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (DeviceWithID(inDeviceObjectID) == NULL) return kAudioHardwareBadDeviceError;
    return kAudioHardwareNoError;
}

static OSStatus SoundcheckMic_DoIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, AudioObjectID inStreamObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo, void* ioMainBuffer, void* ioSecondaryBuffer) CA_REALTIME_API {
    (void)inClientID; (void)ioSecondaryBuffer;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    const DeviceInfo* device = DeviceWithID(inDeviceObjectID);
    if (device == NULL) return kAudioHardwareBadDeviceError;
    if (inStreamObjectID != device->streamID) return kAudioHardwareBadStreamError;
    if (inOperationID != device->ioOperation) return kAudioHardwareNoError;
    if (ioMainBuffer == NULL || inIOCycleInfo == NULL) return kAudioHardwareIllegalOperationError;

    if (device->deviceID == kObjectID_Mic) {
        MicRead(inIOCycleInfo->mInputTime.mSampleTime, inIOBufferFrameSize, (Float32*)ioMainBuffer);
    } else {
        FeedWrite(inIOCycleInfo->mOutputTime.mSampleTime, inIOBufferFrameSize, (const Float32*)ioMainBuffer);
    }
    return kAudioHardwareNoError;
}

static OSStatus SoundcheckMic_EndIOOperation(AudioServerPlugInDriverRef inDriver, AudioObjectID inDeviceObjectID, UInt32 inClientID, UInt32 inOperationID, UInt32 inIOBufferFrameSize, const AudioServerPlugInIOCycleInfo* inIOCycleInfo) CA_REALTIME_API {
    (void)inClientID; (void)inOperationID; (void)inIOBufferFrameSize; (void)inIOCycleInfo;
    if (inDriver != gDriverRef) return kAudioHardwareBadObjectError;
    if (DeviceWithID(inDeviceObjectID) == NULL) return kAudioHardwareBadDeviceError;
    return kAudioHardwareNoError;
}
