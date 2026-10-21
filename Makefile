export TARGET = iphone:clang:latest:16.3
export ARCHS = arm64 arm64e
export DEBUG = 0
export FINALPACKAGE = 1

TWEAK_NAME = ProfileButtons
ProfileButtons_FILES = ProfileButtons.m
ProfileButtons_CFLAGS = -fobjc-arc -Wall -Wno-deprecated-declarations
ProfileButtons_FRAMEWORKS = UIKit Foundation SafariServices WebKit

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/tweak.mk
