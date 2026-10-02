export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# 键盘跑在宿主 App 进程 (arm64) 与部分系统进程 (arm64e), 两个切片都要。
# arm64e 必须 macOS 运行器编译 (Linux 工具链注入系统进程会 objc readClass SIGBUS)。
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KeyboardGlass
KeyboardGlass_FILES = Tweak.x KGPrefs.m KGGlassLayer.m KGKeyboardInstaller.m
KeyboardGlass_FRAMEWORKS = UIKit QuartzCore
KeyboardGlass_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
