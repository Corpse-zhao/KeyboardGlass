#import <UIKit/UIKit.h>

// Preferences 框架是私有的, 这里只做最小声明。
// bundle 由「设置」App 加载, 符号在运行时解析 (bundle 链接了 -Wl,-undefined,dynamic_lookup),
// 因此不需要链接 Preferences.framework。
//
// ⚠️ _specifiers 这个 ivar 声明是刻意为之: PSListController 的表格数据源内部直接
// 访问自己的 _specifiers ivar (编译期绑定), 子类如果只覆盖 -specifiers 却写自己的
// 缓存 ivar, 基类看到的永远是 nil → 设置页面整页空白。
// 把 ivar 声明在基类接口里, 编译器会生成对 _OBJC_IVAR_$_PSListController._specifiers
// 的引用 (与 GlassSuiteX 的做法一致), 运行时解析到真正的基类 ivar。
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
- (void)setProperty:(id)value forKey:(NSString *)key;
@end

@interface PSListController : UIViewController {
    @protected
    NSArray *_specifiers;
}
- (NSArray *)specifiers;
- (NSArray *)loadSpecifiersFromPlistName:(NSString *)name target:(id)target;
- (void)reloadSpecifiers;
- (id)readPreferenceValue:(PSSpecifier *)specifier;
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier;
@end

@interface KGRootListController : PSListController
@end
