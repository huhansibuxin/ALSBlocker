export TARGET = iphone:clang:latest:15.0
export ARCHS = arm64e

INSTALL_TARGET_PROCESSES = backboardd
export _THEOS_PLATFORM_DPKG_DEB_COMPRESSION = gzip
export THEOS_PACKAGE_SCHEME = rootless

TWEAK_NAME = ALSBlocker

ALSBlocker_FILES = Tweak.xm
ALSBlocker_CFLAGS = -fobjc-arc
ALSBlocker_FRAMEWORKS = IOKit

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
