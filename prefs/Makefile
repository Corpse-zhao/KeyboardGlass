BUNDLE_NAME = KeyboardGlassPreferences
KeyboardGlassPreferences_FILES = KGRootListController.m
KeyboardGlassPreferences_FRAMEWORKS = UIKit
KeyboardGlassPreferences_INSTALL_PATH = /Library/PreferenceBundles
KeyboardGlassPreferences_CFLAGS = -fobjc-arc -Wno-deprecated-declarations
# PSListController / PSSpecifier 属于私有的 Preferences 框架, 这里是自己声明的接口。
# bundle 默认不开动态查找, ld 会把它们当成需要定义的强符号而报 undefined symbol,
# 因此显式打开 dynamic_lookup —— 符号在「设置」进程运行时解析。
KeyboardGlassPreferences_LDFLAGS = -Wl,-undefined,dynamic_lookup

include $(THEOS)/makefiles/common.mk
include $(THEOS_MAKE_PATH)/bundle.mk
