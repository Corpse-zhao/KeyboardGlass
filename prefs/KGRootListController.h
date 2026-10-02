#import <UIKit/UIKit.h>

// Preferences 框架是私有的, 这里只做最小声明。
// bundle 由「设置」App 加载, 符号在运行时解析 (theos bundle 默认 -undefined dynamic_lookup),
// 因此不需要链接 Preferences.framework, 也就绕开了 Apple ld 找不到 SDK PrivateFrameworks 的问题。
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface PSListController : UIViewController
- (NSArray *)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface KGRootListController : PSListController
@end
