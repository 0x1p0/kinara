// Exercise the actual native callback with recorded-layout synthetic frames.
// No private framework is opened, no devices started, no hardware is changed.
#include "../Kinara/MultitouchBridge.c"
#include <assert.h>
#include <stdio.h>

static int deliveries;
static int lastCount;
static uint64_t lastGeneration;
static MTBridgeContact lastContacts[maximumContacts];

static void record(int count, const MTBridgeContact *contacts, double timestamp, uint64_t generation) {
    (void)timestamp;
    deliveries++;
    lastCount = count;
    lastGeneration = generation;
    for (int i = 0; i < count; i++) lastContacts[i] = contacts[i];
}

// A fake MultitouchSupport: each list it hands out holds one device, and a
// device starts only if it is in `working` (GitHub issue #3: after sleep an
// M1's old trackpad device never starts again; a fresh list has one that does).
static MTDeviceRef nextDevice, working;
static int listsMade, registered, unregistered, started;
static CFArrayRef fake_createList(void) {
    listsMade++;
    if (!nextDevice) return CFArrayCreate(NULL, NULL, 0, NULL);
    const void *values[1] = {nextDevice};
    return CFArrayCreate(NULL, values, 1, NULL);
}
static void fake_register(MTDeviceRef device, MTContactCallback callback) { (void)device; (void)callback; registered++; }
static void fake_unregister(MTDeviceRef device, MTContactCallback callback) { (void)device; (void)callback; unregistered++; }
static int32_t fake_start(MTDeviceRef device, int32_t mode) { (void)mode; if (device != working) return -1; started++; return 0; }
static int32_t fake_stop(MTDeviceRef device) { (void)device; return 0; }

// A fake actuator: opening makes a fresh object; actuating answers `answers`.
static int actuatorsMade, answers = 1;
static int32_t fake_deviceID(MTDeviceRef device, uint64_t *identifier) { *identifier = (uint64_t)(uintptr_t)device; return 0; }
static CFTypeRef fake_createActuator(uint64_t identifier) { (void)identifier; actuatorsMade++; return CFStringCreateWithCString(NULL, "actuator", kCFStringEncodingUTF8); }
static int32_t fake_openActuator(CFTypeRef actuator) { (void)actuator; return 0; }
static int32_t fake_actuate(CFTypeRef actuator, int32_t id, uint32_t unknown, float a, float b) { (void)actuator; (void)id; (void)unknown; (void)a; (void)b; return answers ? 0 : -1; }

int main(void) {
    MTDeviceRef firstDevice = (MTDeviceRef)(uintptr_t)1;
    MTDeviceRef secondDevice = (MTDeviceRef)(uintptr_t)2;
    g_devices[0] = firstDevice;
    g_devices[1] = secondDevice;
    g_deviceCount = 2;
    g_needsLift[0] = 1;
    g_needsLift[1] = 1;
    g_running = 1;
    g_generation = 42;
    MTBridge_SetFrameCallback(record);

    MTContact contacts[2] = {0};
    contacts[0].pathIndex = 17;
    contacts[0].state = 4;
    contacts[0].normalized.position = (MTPoint){0.1f, 0.2f};
    contacts[0].majorAxis = 9.5f;
    contacts[0].minorAxis = 8.0f;
    contacts[1].pathIndex = 81;
    contacts[1].state = 4;
    contacts[1].normalized.position = (MTPoint){0.15f, 0.75f};
    contacts[1].majorAxis = 24.0f;
    contacts[1].minorAxis = 15.5f;

    mt_callback(firstDevice, contacts, 2, 1, 1);
    assert(deliveries == 0); // Already-resting contacts at start cannot activate.
    mt_callback(firstDevice, NULL, 0, 1.1, 2);
    mt_callback(firstDevice, contacts, 2, 1.2, 3);
    assert(deliveries == 1 && lastCount == 2 && lastGeneration == 42);
    assert(lastContacts[0].identifier == 17 && lastContacts[1].identifier == 81);
    assert(lastContacts[1].x == 0.15f && lastContacts[1].y == 0.75f); // Full96-byte stride.
    // Palm rejection reads each contact's own ellipse, at the right offset.
    assert(lastContacts[0].majorAxis == 9.5f && lastContacts[0].minorAxis == 8.0f);
    assert(lastContacts[1].majorAxis == 24.0f && lastContacts[1].minorAxis == 15.5f);

    mt_callback(secondDevice, NULL, 0, 1.21, 1);
    assert(deliveries == 1); // Idle second trackpad cannot end the gesture.
    contacts[0].state = 3;
    mt_callback(secondDevice, contacts, 1, 1.22, 2);
    assert(deliveries == 1); // Active-device ownership.
    mt_callback(firstDevice, NULL, 0, 1.3, 4);
    assert(deliveries == 2 && lastCount == 0);
    contacts[0].state = 4;
    mt_callback(secondDevice, contacts, 1, 1.31, 3);
    assert(deliveries == 2); // Mid-touch ownership cannot migrate across devices.
    mt_callback(secondDevice, NULL, 0, 1.4, 4);
    mt_callback(secondDevice, contacts, 1, 1.5, 5);
    assert(deliveries == 3 && lastCount == 1);

    contacts[0].majorAxis = NAN;
    contacts[0].minorAxis = -3;
    mt_callback(secondDevice, contacts, 1, 1.505, 5);
    assert(lastCount == 1 && lastContacts[0].majorAxis == 0 && lastContacts[0].minorAxis == 0); // No shape, never garbage.
    contacts[0].majorAxis = 9.5f;
    contacts[0].minorAxis = 8.0f;
    contacts[1].state = 2;
    mt_callback(secondDevice, contacts, 2, 1.51, 6);
    assert(lastCount == 1); // Hover is not a finger down.
    contacts[0].state = 5;
    mt_callback(secondDevice, contacts, 2, 1.52, 7);
    assert(lastCount == 0); // Breaking and hovering contacts are a true lift.
    contacts[0].state = 3;
    mt_callback(secondDevice, contacts, 1, 1.6, 8);
    contacts[0].normalized.position.x = NAN;
    mt_callback(secondDevice, contacts, 1, 1.61, 9);
    assert(lastCount == 1 && isnan(lastContacts[0].x)); // Corruption cancels; never fake lift.
    int beforeStop = deliveries;
    MTBridge_Stop();
    mt_callback(secondDevice, contacts, 1, 1.7, 10);
    assert(deliveries == beforeStop && g_frameCallback == NULL && !g_running);
    puts("PASS: native bridge stride, state, identity, contact shape, device ownership and stop barrier");

    // Waking: the device in hand has gone stale, so starting asks macOS again.
    g_createList = fake_createList;
    g_registerCallback = fake_register;
    g_unregisterCallback = fake_unregister;
    g_startDevice = fake_start;
    g_stopDevice = fake_stop;
    g_deviceCount = 0;
    MTDeviceRef stale = (MTDeviceRef)(uintptr_t)10, fresh = (MTDeviceRef)(uintptr_t)20;
    nextDevice = stale;
    working = stale;
    MTBridge_SetFrameCallback(record);
    assert(MTBridge_Start(50) == 1 && listsMade == 1 && registered == 1); // Before sleep: the first list works.
    MTBridge_Stop();
    // After sleep, the old device never starts again and macOS has a new one.
    working = fresh;
    nextDevice = fresh;
    MTBridge_SetFrameCallback(record);
    assert(MTBridge_Start(51) == 1);
    assert(listsMade == 2 && unregistered == 1 && registered == 2); // The stale one was let go, the fresh one listened to.
    assert(g_deviceCount == 1 && g_devices[0] == fresh && g_running && g_frameCallback == record);
    int beforeFresh = deliveries;
    contacts[0].state = 3;
    contacts[0].normalized.position = (MTPoint){0.5f, 0.5f};
    mt_callback(stale, contacts, 1, 2.0, 1);
    assert(deliveries == beforeFresh); // The stale device is no longer heard.
    mt_callback(fresh, contacts, 1, 2.1, 1);
    assert(deliveries == beforeFresh + 1 && lastGeneration == 51); // The fresh one is.
    MTBridge_Stop();
    // With no trackpad at all, starting fails cleanly, so Kinara can try again later.
    working = NULL;
    nextDevice = NULL;
    MTBridge_SetFrameCallback(record);
    assert(MTBridge_Start(52) == 0 && !g_running && g_frameCallback == NULL && g_deviceCount == 0);
    puts("PASS: a stale trackpad device is replaced by a fresh one; none at all fails cleanly");

    // Haptics: an actuator that worked and then stops answering is reopened; one
    // that never worked is kept, so it isn't reopened on every tick.
    g_actuatorsLoaded = 1;
    g_actuatorDevices = CFArrayCreate(NULL, (const void *[]){fresh}, 1, NULL);
    g_deviceID = fake_deviceID;
    g_createActuator = fake_createActuator;
    g_openActuator = fake_openActuator;
    g_actuate = fake_actuate;
    g_lastTouchedDevice = fresh;
    assert(MTBridge_Actuate(6, 0, 1) == 1 && actuatorsMade == 1);
    answers = 0;
    assert(MTBridge_Actuate(6, 0, 1) == 0 && g_actuatorCount == 0); // Stale after sleep: let go.
    answers = 1;
    assert(MTBridge_Actuate(6, 0, 1) == 1 && actuatorsMade == 2); // A fresh one, and it works.
    g_actuatorWorked[0] = 0;
    answers = 0;
    assert(MTBridge_Actuate(6, 0, 1) == 0 && MTBridge_Actuate(6, 0, 1) == 0 && actuatorsMade == 2 && g_actuatorCount == 1);
    puts("PASS: a haptic actuator that stops answering after sleep is reopened");
    return 0;
}
