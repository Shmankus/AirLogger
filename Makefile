export THEOS_PACKAGE_SCHEME = rootless

# Device config for `make do` / `make install` lives in Makefile.local (gitignored).
# Copy the example below into Makefile.local and set your own device:
#   THEOS_DEVICE_IP = 192.x.x.x
#   THEOS_DEVICE_PORT = 22
#   THEOS_DEVICE_USER = root
-include Makefile.local

ARCHS = arm64
TARGET = iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

APPLICATION_NAME = AirLogger

AirLogger_FILES = main.m ALAppDelegate.m ALDevice.m ALWiFiScanner.m ALBluetoothScanner.m ALDatabase.m ALLocationProvider.m ALDeviceCell.m ALRootViewController.m ALDetailViewController.m ALHistoryViewController.m ALMapViewController.m
AirLogger_FRAMEWORKS = UIKit Foundation CoreFoundation CoreBluetooth CoreLocation MapKit WebKit
AirLogger_LIBRARIES = sqlite3
AirLogger_CFLAGS = -fobjc-arc
AirLogger_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache -a"
