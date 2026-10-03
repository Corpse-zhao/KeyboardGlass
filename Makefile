export TARGET = iphone:clang:latest:16.0
export THEOS_PACKAGE_SCHEME = rootless
# 键盘跑在宿主 App 进程 (arm64) 与部分系统进程 (arm64e), 两个切片都要。
# arm64e 必须 macOS 运行器编译 (Linux 工具链注入系统进程会 objc readClass SIGBUS)。
export ARCHS = arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME = KeyboardGlass
# v3.0.0 推翻重做: KGKeyboardInstaller(2600 行)与 KGExtProbe 已删除。
# 引擎合并成单一 KGEngine.m —— 旧版把「找层/调色/插玻璃/探针/熔断」分在
# 两个文件里, 结果v2.0.0 需要靠六个开关做二分, 而六个开关的存在本身就
# 说明没人说得清哪一处真正起作用。合成一个文件是为了让「改哪一行会
# 产生什么效果」一目了然。
KeyboardGlass_FILES = Tweak.x KGPrefs.m KGEngine.m KGGlassView.m
KeyboardGlass_FRAMEWORKS = UIKit QuartzCore
KeyboardGlass_CFLAGS = -fobjc-arc -Wno-deprecated-declarations -Wno-unused-function

include $(THEOS_MAKE_PATH)/tweak.mk

SUBPROJECTS += prefs
include $(THEOS_MAKE_PATH)/aggregate.mk
