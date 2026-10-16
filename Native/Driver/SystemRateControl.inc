// System format setters enqueue a control request while streaming. They never
// alter the running PCM format/clock; the owner reconnects through the existing
// stopped-IO RequestDeviceConfigurationChange path after Bluetooth teardown.
static UInt32 gSystemRateMask;
static UInt64 gSystemRateGeneration;
static Boolean gSystemRateEnabled;
static Float64 gSystemRequestedRate;
static SInt64 gSystemRateSerial;

static UInt32 SonoFerryRateMaskLocked(void) {
    return SonoFerryLeaseValid() && gSystemRateGeneration == gLeaseGeneration && gSystemRateMask
        ? gSystemRateMask : (1U << SONOFERRY_RATE_COUNT) - 1;
}

static UInt32 SonoFerryCurrentRates(Float64 *rates) {
    pthread_mutex_lock(&gPlugIn_StateMutex);
    UInt32 mask = SonoFerryRateMaskLocked(), count = 0;
    for (UInt32 i = 0; i < SONOFERRY_RATE_COUNT; ++i)
        if (mask & (1U << i)) { if (rates) rates[count] = gSampleRates[i]; ++count; }
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    return count;
}

static CFDictionaryRef SonoFerryCopyRateControl(void) {
    pthread_mutex_lock(&gPlugIn_StateMutex);
    Boolean enabled = gSystemRateEnabled && !gShuttingDown && SonoFerryLeaseValid() && gSystemRateGeneration == gLeaseGeneration;
    Float64 rate = enabled ? gSystemRequestedRate : 0;
    SInt64 serial = gSystemRateSerial;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    CFNumberRef rateValue = CFNumberCreate(NULL, kCFNumberFloat64Type, &rate);
    CFNumberRef sequence = CFNumberCreate(NULL, kCFNumberSInt64Type, &serial);
    const void *keys[] = {CFSTR("enabled"), CFSTR("requestedRate"), CFSTR("serial")};
    const void *values[] = {enabled ? kCFBooleanTrue : kCFBooleanFalse, rateValue, sequence};
    CFDictionaryRef result = CFDictionaryCreate(NULL, keys, values, 3, &kCFTypeDictionaryKeyCallBacks, &kCFTypeDictionaryValueCallBacks);
    CFRelease(rateValue); CFRelease(sequence);
    return result;
}

static OSStatus SonoFerrySetRateControl(pid_t client, CFPropertyListRef value) {
    if (!value || CFGetTypeID(value) != CFDictionaryGetTypeID() || CFDictionaryGetCount(value) != 2)
        return kAudioHardwareIllegalOperationError;
    CFTypeRef enabled = CFDictionaryGetValue(value, CFSTR("enabled"));
    CFArrayRef rates = CFDictionaryGetValue(value, CFSTR("rates"));
    if (!enabled || CFGetTypeID(enabled) != CFBooleanGetTypeID() || !rates || CFGetTypeID(rates) != CFArrayGetTypeID() ||
        !CFArrayGetCount(rates) || CFArrayGetCount(rates) > SONOFERRY_RATE_COUNT) return kAudioHardwareIllegalOperationError;
    UInt32 mask = 0;
    for (CFIndex i = 0; i < CFArrayGetCount(rates); ++i) {
        CFTypeRef item = CFArrayGetValueAtIndex(rates, i); Float64 rate = 0;
        if (CFGetTypeID(item) != CFNumberGetTypeID() || !CFNumberGetValue(item, kCFNumberFloat64Type, &rate) || !SonoFerrySupportedRate(rate))
            return kAudioDeviceUnsupportedFormatError;
        for (UInt32 j = 0; j < SONOFERRY_RATE_COUNT; ++j) if (gSampleRates[j] == rate) {
            if (mask & (1U << j)) return kAudioHardwareIllegalOperationError;
            mask |= 1U << j;
        }
    }
    if (!SonoFerryClientAuthorized(client)) return kAudioDevicePermissionsError;
    pthread_mutex_lock(&gPlugIn_StateMutex);
    if (gShuttingDown || client != gLeaseOwner || !SonoFerryLeaseValid()) {
        pthread_mutex_unlock(&gPlugIn_StateMutex); return kAudioDevicePermissionsError;
    }
    Boolean changed = mask != SonoFerryRateMaskLocked();
    if (changed && gDevice_IOIsRunning) {
        pthread_mutex_unlock(&gPlugIn_StateMutex); return kAudioHardwareIllegalOperationError;
    }
    gSystemRateMask = mask; gSystemRateGeneration = gLeaseGeneration;
    gSystemRateEnabled = CFBooleanGetValue(enabled); gSystemRequestedRate = 0;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    if (changed) {
        AudioObjectPropertyAddress device = {kAudioDevicePropertyAvailableNominalSampleRates, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
        AudioObjectPropertyAddress stream[] = {
            {kAudioStreamPropertyAvailablePhysicalFormats, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain},
            {kAudioStreamPropertyAvailableVirtualFormats, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain}};
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &device);
        gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Stream_Output, 2, stream);
    }
    return noErr;
}

static OSStatus SonoFerryRequestSystemRate(pid_t client, Float64 rate, Boolean *handled) {
    pthread_mutex_lock(&gPlugIn_StateMutex);
    *handled = gSystemRateEnabled && !gShuttingDown && SonoFerryLeaseValid() && SonoFerryAlive() && gSystemRateGeneration == gLeaseGeneration;
    if (!*handled) { pthread_mutex_unlock(&gPlugIn_StateMutex); return noErr; }
    Boolean supported = false;
    for (UInt32 i = 0; i < SONOFERRY_RATE_COUNT; ++i)
        if (gSampleRates[i] == rate && (SonoFerryRateMaskLocked() & (1U << i))) supported = true;
    if (!supported || client <= 0) {
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        return supported ? kAudioDevicePermissionsError : kAudioDeviceUnsupportedFormatError;
    }
    if (rate == gSystemRequestedRate || (!gSystemRequestedRate && rate == gDevice_SampleRate)) {
        pthread_mutex_unlock(&gPlugIn_StateMutex); return noErr;
    }
    gSystemRequestedRate = rate;
    gSystemRateSerial = gSystemRateSerial == INT64_MAX ? 1 : gSystemRateSerial + 1;
    UInt64 generation = gLeaseGeneration;
    pthread_mutex_unlock(&gPlugIn_StateMutex);
    dispatch_async(gLeaseQueue, ^{
        pthread_mutex_lock(&gPlugIn_StateMutex);
        Boolean valid = gSystemRateEnabled && !gShuttingDown && SonoFerryLeaseValid() && gLeaseGeneration == generation;
        pthread_mutex_unlock(&gPlugIn_StateMutex);
        if (valid) {
            AudioObjectPropertyAddress property = {kSonoFerryRateControl, kAudioObjectPropertyScopeGlobal, kAudioObjectPropertyElementMain};
            gPlugIn_Host->PropertiesChanged(gPlugIn_Host, kObjectID_Device, 1, &property);
        }
    });
    return noErr;
}
