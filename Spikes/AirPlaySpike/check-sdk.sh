#!/bin/zsh
# check-sdk.sh -- the long-form SDK check for #0050. Read-only; always exits 0.
SDK=$(xcrun --sdk macosx --show-sdk-path)
H="$SDK/System/Library/Frameworks"
echo "sdk: $SDK"
echo "--- AVAudioSession.h: routeSharingPolicy lines"
grep -n 'routeSharingPolicy\|RouteSharingPolicy' "$H/AVFAudio.framework/Headers/AVAudioSession.h" | head -20
echo "--- AVAudioSession.h: macos availability on those declarations"
if grep -n 'routeSharingPolicy\|RouteSharingPolicy' "$H/AVFAudio.framework/Headers/AVAudioSession.h" | grep -q 'API_AVAILABLE([^)]*macos('; then
  echo "result: some routeSharingPolicy declaration is API_AVAILABLE on macos"
else
  echo "result: no routeSharingPolicy declaration is available on macos"
fi
echo "--- AVAudioSession.h: API_UNAVAILABLE(macos) count"
grep -c 'API_UNAVAILABLE([^)]*macos' "$H/AVFAudio.framework/Headers/AVAudioSession.h"
echo "--- AVAudioSessionTypes.h: AVInitialRouteSharingPolicy"
grep -n 'AVInitialRouteSharingPolicy' "$H/AVFAudio.framework/Headers/AVAudioSessionTypes.h" | head -10
echo "--- AVRoutePickerView.h: discussion"
grep -n 'can be routed to compatible AirPlay' "$H/AVKit.framework/Headers/AVRoutePickerView.h"
exit 0
