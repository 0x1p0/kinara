#pragma once
#include <CoreFoundation/CoreFoundation.h>
#include <stdint.h>

// A copied, public bridge record; its layout is NOT the private framework ABI.
typedef struct {
    int32_t identifier;
    float x;
    float y;
    // The contact's ellipse in millimetres, as the sensor measured it. Zero
    // when a device reports no shape; palm rejection then has no evidence.
    float majorAxis;
    float minorAxis;
} MTBridgeContact;

// Callbacks occur on the framework thread. The array is valid only until return.
typedef void (*MTFrameCallback)(int count, const MTBridgeContact *contacts,
                                double timestamp, uint64_t generation);
void MTBridge_SetFrameCallback(MTFrameCallback callback);
// Returns the number of successfully started devices (zero means unavailable).
int MTBridge_Start(uint64_t generation);
void MTBridge_Stop(void);
// Fires one actuator waveform on the trackpad last touched (or the first one
// that opens). Returns 1 on success, 0 if unavailable. Main thread only.
int MTBridge_Actuate(int32_t actuationID, float unknown1, float unknown2);
