TARGET := iphone:clang:9.3:9.0
ARCHS = armv7
# Old Cydia dpkg reads gzip reliably; also avoids an lzma issue on Fedora.
THEOS_PLATFORM_DEB_COMPRESSION_TYPE = gzip
INSTALL_TARGET_PROCESSES = SpringBoard

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = FreeGrid
FreeGrid_FILES = Tweak.x
FreeGrid_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
FreeGrid_FRAMEWORKS = UIKit

include $(THEOS_MAKE_PATH)/tweak.mk
