ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = rootless
INSTALL_TARGET_PROCESSES = MobilePhone mediaserverd

include $(THEOS)/makefiles/common.mk

TOOL_NAME = k7bridged
k7bridged_FILES = Daemon/main.mm Daemon/StateMachine.mm Daemon/SMSStore.mm Daemon/Pairing.mm Daemon/ControlServer.mm Daemon/RelayClient.mm Daemon/DeviceStatus.mm Daemon/Diagnostics.mm Shared/BridgeIPC.mm
k7bridged_FRAMEWORKS = Foundation CoreTelephony Network Security UIKit
k7bridged_LIBRARIES = sqlite3 sodium
k7bridged_CFLAGS = -fobjc-arc -IHeaders -Wno-nullability-completeness -Wno-module-import-in-extern-c -Wno-deprecated-declarations
k7bridged_CODESIGN_FLAGS = -Sentitlements.plist
k7bridged_INSTALL_PATH = /usr/local/libexec

TWEAK_NAME = K7TelephonyBridge K7AudioBridge
K7TelephonyBridge_FILES = TelephonyBridge/Tweak.xm Shared/BridgeIPC.mm
K7TelephonyBridge_FRAMEWORKS = Foundation CoreFoundation
K7TelephonyBridge_CFLAGS = -fobjc-arc -IHeaders -Wno-nullability-completeness
K7AudioBridge_FILES = AudioBridge/Tweak.xm
K7AudioBridge_FRAMEWORKS = Foundation AudioToolbox
K7AudioBridge_CFLAGS = -fobjc-arc -IHeaders -Wno-nullability-completeness

include $(THEOS_MAKE_PATH)/tool.mk
include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "launchctl kickstart -k system/com.k7bridge.gateway || true"
