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
AirLogger_RESOURCES_FOLDER = Resources
# Sources/<Category>/*.m — every folder is also on the include path, so imports
# stay flat (#import "ALDevice.h") and new files are picked up automatically.
SOURCE_DIRS = $(wildcard Sources/*)
AirLogger_FILES = $(wildcard Sources/*/*.m)
AirLogger_FRAMEWORKS = UIKit Foundation CoreFoundation CoreBluetooth CoreLocation MapKit WebKit NetworkExtension
AirLogger_LIBRARIES = sqlite3
AirLogger_CFLAGS = -fobjc-arc $(addprefix -I,$(SOURCE_DIRS))
AirLogger_CODESIGN_FLAGS = -Sentitlements.plist

include $(THEOS_MAKE_PATH)/application.mk

after-install::
	install.exec "uicache -p /var/jb/Applications/AirLogger.app"
