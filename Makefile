ARCHS = arm64
TARGET := iphone:clang:latest:14.0

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = hongguospeed

hongguospeed_FILES = SpeedBadge.m
hongguospeed_CFLAGS = -fobjc-arc
hongguospeed_FRAMEWORKS = UIKit AVFoundation

include $(THEOS_MAKE_PATH)/tweak.mk
