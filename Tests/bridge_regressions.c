// Exercise the actual native callback with recorded-layout synthetic frames.
// No private framework is opened, no devices started, no hardware is changed.
#include "../Sway/MultitouchBridge.c"
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
    return 0;
}
