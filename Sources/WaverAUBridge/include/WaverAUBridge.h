#pragma once
#include <AudioToolbox/AudioToolbox.h>

/// Global-scope property returning the Swift `WaverPlugin` pointer (used by the editor view).
#define kWaverProperty_Plugin 64000

/// AudioComponent factory named in Info.plist (`factoryFunction`).
void *WaverAUFactory(const AudioComponentDescription *desc);

// ---- Implemented in Swift (WaverPlugin target) ----
void *WaverPluginCreate(void);
void WaverPluginDestroy(void *plugin);
void WaverPluginPrepare(void *plugin, double sampleRate);
/// transportState: -1 unknown, 0 stopped, 1 playing.
void WaverPluginProcess(void *plugin, const float *left, const float *right, uint32_t frames, int32_t transportState);
/// Returns a +1 retained CFDictionary of plug-in settings.
CFDictionaryRef WaverPluginCopyState(void *plugin);
void WaverPluginSetState(void *plugin, CFDictionaryRef state);
