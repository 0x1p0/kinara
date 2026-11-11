#include "MultitouchBridge.h"
#include <dlfcn.h>
#include <math.h>
#include <pthread.h>
#include <stddef.h>

typedef void *MTDeviceRef;
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint position, velocity; } MTVector;

// Reverse-engineered ABI, verified against the original TouchSynthesis header:
// https://github.com/calftrail/Touch/blob/master/TouchSynthesis/MultitouchSupport.h
// and the independently published raw contact example:
// https://gist.github.com/rmhsilva/61cc45587ed34707da34818a76476e11
// The complete 96-byte record is essential even when reading only x/y/identity:
// a truncated struct silently gives the WRONG stride for contacts[1] and later.
typedef struct {
    int32_t frame;
    double timestamp;
    int32_t pathIndex;
    int32_t state;
    int32_t fingerID;
    int32_t handID;
    MTVector normalized;
    float zTotal;
    int32_t field9;
    float angle;
    float majorAxis;
    float minorAxis;
    MTVector absolute;
    int32_t field14;
    int32_t field15;
    float zDensity;
} MTContact;

_Static_assert(sizeof(MTContact) == 96, "Unexpected MultitouchSupport contact stride");
_Static_assert(offsetof(MTContact, normalized) == 32, "Unexpected position offset");
_Static_assert(offsetof(MTContact, pathIndex) == 16, "Unexpected contact ID offset");

typedef void (*MTContactCallback)(MTDeviceRef, MTContact *, int32_t, double, int32_t);
typedef CFArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterCallbackFn)(MTDeviceRef, MTContactCallback);
typedef int32_t (*MTDeviceStartFn)(MTDeviceRef, int32_t);
typedef int32_t (*MTDeviceStopFn)(MTDeviceRef);
static MTDeviceCreateListFn g_createList;
static MTRegisterCallbackFn g_registerCallback;
static MTRegisterCallbackFn g_unregisterCallback; // optional

enum { maximumDevices = 32, maximumContacts = 16 };
static pthread_mutex_t g_lock = PTHREAD_MUTEX_INITIALIZER;
static CFArrayRef g_deviceList;
static MTDeviceRef g_devices[maximumDevices];
static int g_deviceCount;
static int g_needsLift[maximumDevices];
static MTDeviceRef g_activeDevice;
static int g_running;
static uint64_t g_generation;
static MTFrameCallback g_frameCallback;
static MTDeviceStartFn g_startDevice;
static MTDeviceStopFn g_stopDevice;
static MTDeviceRef g_lastTouchedDevice;

static void mt_callback(MTDeviceRef device, MTContact *contacts, int32_t count,
                        double timestamp, int32_t frame) {
    (void)frame;
    pthread_mutex_lock(&g_lock);
    if (!g_running || !g_frameCallback) { pthread_mutex_unlock(&g_lock); return; }
    int deviceIndex = -1;
    for (int i = 0; i < g_deviceCount; i++) {
        if (g_devices[i] == device) { deviceIndex = i; break; }
    }
    if (deviceIndex < 0) { pthread_mutex_unlock(&g_lock); return; }

    MTBridgeContact copied[maximumContacts];
    int touching = 0;
    int allMaking = 1;
    int valid = count >= 0 && count <= maximumContacts && (count == 0 || contacts != NULL) && isfinite(timestamp);
    if (valid) {
        for (int i = 0; i < count; i++) {
            if (contacts[i].state < 0 || contacts[i].state > 7) { valid = 0; break; }
            // States 1/2 are approaching/hovering; 5/6/7 are breaking/leaving.
            // Only 3 (making contact) and 4 (touching) are actual fingers down.
            if (contacts[i].state != 3 && contacts[i].state != 4) continue;
            const MTPoint position = contacts[i].normalized.position;
            if (!isfinite(position.x) || !isfinite(position.y) ||
                position.x < 0 || position.x > 1 || position.y < 0 || position.y > 1) {
                valid = 0;
                break;
            }
            const float major = contacts[i].majorAxis, minor = contacts[i].minorAxis;
            const int shaped = isfinite(major) && isfinite(minor) && major > 0 && minor > 0 && major < 200 && minor < 200;
            copied[touching++] = (MTBridgeContact){contacts[i].pathIndex, position.x, position.y,
                                                   shaped ? major : 0, shaped ? minor : 0};
            if (contacts[i].state != 3) allMaking = 0;
        }
    }
    if (!valid) {
        g_needsLift[deviceIndex] = 1;
        if (g_activeDevice == device) {
            // A malformed record cancels, rather than masquerading as a lift.
            MTBridgeContact invalid = {-1, NAN, NAN, 0, 0};
            g_frameCallback(1, &invalid, timestamp, g_generation);
        }
        pthread_mutex_unlock(&g_lock);
        return;
    }
    if (touching == 0) {
        g_needsLift[deviceIndex] = 0;
        if (g_activeDevice == device) {
            g_activeDevice = NULL;
            g_frameCallback(0, NULL, timestamp, g_generation);
        }
        pthread_mutex_unlock(&g_lock);
        return;
    }
    // On resume, an already resting finger cannot become a new gesture.
    if (g_needsLift[deviceIndex]) {
        if (allMaking) g_needsLift[deviceIndex] = 0;
        else { pthread_mutex_unlock(&g_lock); return; }
    }
    if (g_activeDevice != NULL && g_activeDevice != device) {
        // A touch on another device must lift before it can take ownership.
        g_needsLift[deviceIndex] = 1;
        pthread_mutex_unlock(&g_lock);
        return;
    }
    g_activeDevice = device;
    g_lastTouchedDevice = device;
    // The Swift trampoline only copies data and queues work. Calling it while
    // locked makes Stop a delivery barrier without retaining a Swift object.
    g_frameCallback(touching, copied, timestamp, g_generation);
    pthread_mutex_unlock(&g_lock);
}

void MTBridge_SetFrameCallback(MTFrameCallback callback) {
    pthread_mutex_lock(&g_lock);
    g_frameCallback = callback;
    pthread_mutex_unlock(&g_lock);
}

// Everything below is called on the main thread. The framework stays loaded for
// the process lifetime; the device list is kept until its devices stop starting.
static int load_framework(void) {
    if (!g_createList) {
        void *library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
        if (!library) return 0;
        g_createList = (MTDeviceCreateListFn)dlsym(library, "MTDeviceCreateList");
        g_registerCallback = (MTRegisterCallbackFn)dlsym(library, "MTRegisterContactFrameCallback");
        g_unregisterCallback = (MTRegisterCallbackFn)dlsym(library, "MTUnregisterContactFrameCallback");
        g_startDevice = (MTDeviceStartFn)dlsym(library, "MTDeviceStart");
        g_stopDevice = (MTDeviceStopFn)dlsym(library, "MTDeviceStop");
    }
    return g_createList && g_registerCallback && g_startDevice && g_stopDevice;
}

// Asks macOS for the trackpads now present and listens to each, exactly once.
static int load_devices(void) {
    CFArrayRef list = g_createList();
    if (!list) return 0;
    CFIndex count = CFArrayGetCount(list);
    if (count == 0) { CFRelease(list); return 0; }
    pthread_mutex_lock(&g_lock);
    g_deviceList = list;
    g_deviceCount = (int)(count < maximumDevices ? count : maximumDevices);
    for (int i = 0; i < g_deviceCount; i++) g_devices[i] = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
    pthread_mutex_unlock(&g_lock);
    for (int i = 0; i < g_deviceCount; i++) g_registerCallback(g_devices[i], mt_callback);
    return g_deviceCount;
}

// Lets go of the devices in hand. Across sleep macOS can replace a trackpad's
// device (seen on a MacBook Air M1), and the old one never starts again.
static void forget_devices(void) {
    MTDeviceRef old[maximumDevices];
    pthread_mutex_lock(&g_lock);
    CFArrayRef list = g_deviceList;
    int count = g_deviceCount;
    for (int i = 0; i < count; i++) old[i] = g_devices[i];
    g_deviceList = NULL;
    g_deviceCount = 0;
    g_activeDevice = NULL;
    g_lastTouchedDevice = NULL;
    pthread_mutex_unlock(&g_lock);
    if (g_unregisterCallback) {
        for (int i = 0; i < count; i++) g_unregisterCallback(old[i], mt_callback);
    }
    if (list) CFRelease(list);
}

// Starts every device in hand; the number that started.
static int start_devices(uint64_t generation) {
    pthread_mutex_lock(&g_lock);
    if (g_running) { pthread_mutex_unlock(&g_lock); return g_deviceCount; }
    g_generation = generation;
    g_activeDevice = NULL;
    for (int i = 0; i < g_deviceCount; i++) g_needsLift[i] = 1;
    g_running = 1;
    int count = g_deviceCount;
    pthread_mutex_unlock(&g_lock);
    int started = 0;
    for (int i = 0; i < count; i++) {
        if (g_startDevice(g_devices[i], 0) == 0) started++;
    }
    if (started == 0) {
        pthread_mutex_lock(&g_lock);
        g_running = 0;
        pthread_mutex_unlock(&g_lock);
    }
    return started;
}

int MTBridge_Start(uint64_t generation) {
    if (!load_framework()) return 0;
    if (!g_deviceList && load_devices() == 0) return 0;
    int started = start_devices(generation);
    if (started == 0) {
        // None of the devices in hand answered: ask macOS again for the ones
        // present now, and try those once.
        forget_devices();
        if (load_devices() > 0) started = start_devices(generation);
    }
    if (started == 0) MTBridge_Stop();
    return started;
}

void MTBridge_Stop(void) {
    pthread_mutex_lock(&g_lock);
    int wasRunning = g_running;
    g_running = 0;
    g_frameCallback = NULL;
    g_activeDevice = NULL;
    g_generation++;
    pthread_mutex_unlock(&g_lock);
    // Never call into the framework while locked: Stop can drain callbacks.
    if (wasRunning && g_stopDevice) {
        for (int i = 0; i < g_deviceCount; i++) g_stopDevice(g_devices[i]);
    }
}

// Haptics through the same private framework's actuator: the strongest
// waveforms are beyond NSHapticFeedbackManager's three public patterns.
// Signatures follow the published HapticKey header; every symbol is optional
// and any failure leaves the caller on the public patterns.
typedef int32_t (*MTDeviceGetDeviceIDFn)(MTDeviceRef, uint64_t *);
typedef CFTypeRef (*MTActuatorCreateFn)(uint64_t);
typedef int32_t (*MTActuatorOpenFn)(CFTypeRef);
typedef int32_t (*MTActuatorActuateFn)(CFTypeRef, int32_t, uint32_t, float, float);

enum { maximumActuators = 4 };
static pthread_mutex_t g_actuatorLock = PTHREAD_MUTEX_INITIALIZER;
static int g_actuatorsLoaded;
static CFArrayRef g_actuatorDevices;
static uint64_t g_actuatorIDs[maximumActuators];
static CFTypeRef g_actuators[maximumActuators];
static int g_actuatorWorked[maximumActuators];
static int g_actuatorCount;
static MTDeviceGetDeviceIDFn g_deviceID;
static MTActuatorCreateFn g_createActuator;
static MTActuatorOpenFn g_openActuator;
static MTActuatorActuateFn g_actuate;

// Opened actuators are kept for the process lifetime, like the device list.
static CFTypeRef actuator_for_device(MTDeviceRef device) {
    uint64_t identifier = 0;
    if (!device || g_deviceID(device, &identifier) != 0) return NULL;
    for (int i = 0; i < g_actuatorCount; i++) {
        if (g_actuatorIDs[i] == identifier) return g_actuators[i];
    }
    if (g_actuatorCount >= maximumActuators) return NULL;
    CFTypeRef actuator = g_createActuator(identifier);
    if (!actuator) return NULL;
    if (g_openActuator(actuator) != 0) { CFRelease(actuator); return NULL; }
    g_actuatorIDs[g_actuatorCount] = identifier;
    g_actuators[g_actuatorCount] = actuator;
    g_actuatorWorked[g_actuatorCount] = 0;
    g_actuatorCount++;
    return actuator;
}

int MTBridge_Actuate(int32_t actuationID, float unknown1, float unknown2) {
    if (actuationID < 1 || actuationID > 16 || !isfinite(unknown1) || !isfinite(unknown2)) return 0;
    pthread_mutex_lock(&g_lock);
    MTDeviceRef touched = g_lastTouchedDevice;
    pthread_mutex_unlock(&g_lock);
    pthread_mutex_lock(&g_actuatorLock);
    if (!g_actuatorsLoaded) {
        g_actuatorsLoaded = 1;
        void *library = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_NOW | RTLD_LOCAL);
        MTDeviceCreateListFn createList = library ? (MTDeviceCreateListFn)dlsym(library, "MTDeviceCreateList") : NULL;
        g_deviceID = library ? (MTDeviceGetDeviceIDFn)dlsym(library, "MTDeviceGetDeviceID") : NULL;
        g_createActuator = library ? (MTActuatorCreateFn)dlsym(library, "MTActuatorCreateFromDeviceID") : NULL;
        g_openActuator = library ? (MTActuatorOpenFn)dlsym(library, "MTActuatorOpen") : NULL;
        g_actuate = library ? (MTActuatorActuateFn)dlsym(library, "MTActuatorActuate") : NULL;
        if (createList && g_deviceID && g_createActuator && g_openActuator && g_actuate) g_actuatorDevices = createList();
    }
    CFTypeRef actuator = NULL;
    if (g_actuatorDevices && g_actuate) {
        actuator = actuator_for_device(touched);
        // Before any gesture (for example the Haptics preview), use the first
        // trackpad whose actuator opens.
        CFIndex count = CFArrayGetCount(g_actuatorDevices);
        for (CFIndex i = 0; !actuator && !touched && i < count && i < maximumDevices; i++) {
            actuator = actuator_for_device((MTDeviceRef)CFArrayGetValueAtIndex(g_actuatorDevices, i));
        }
    }
    int fired = actuator && g_actuate(actuator, actuationID, 0, unknown1, unknown2) == 0;
    for (int i = 0; actuator && i < g_actuatorCount; i++) {
        if (g_actuators[i] != actuator) continue;
        if (fired) { g_actuatorWorked[i] = 1; break; }
        // One that worked and then stopped answering was opened before sleep, on a
        // trackpad device macOS has since replaced: let go of it, so the next tick
        // opens a fresh one. One that never worked is kept, so it isn't reopened
        // on every tick.
        if (!g_actuatorWorked[i]) break;
        CFRelease(actuator);
        g_actuatorCount--;
        g_actuators[i] = g_actuators[g_actuatorCount];
        g_actuatorIDs[i] = g_actuatorIDs[g_actuatorCount];
        g_actuatorWorked[i] = g_actuatorWorked[g_actuatorCount];
        break;
    }
    pthread_mutex_unlock(&g_actuatorLock);
    return fired;
}
