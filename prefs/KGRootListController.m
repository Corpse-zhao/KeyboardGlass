#import "KGRootListController.h"

static NSString * const kKGPrefsDomain = @"com.banli.keyboardglass.preferences";

@implementation KGRootListController {
    NSArray *_kgSpecifiers;
}

- (NSArray *)specifiers {
    if (!_kgSpecifiers) {
        NSArray *all = [self loadSpecifiersFromPlistName:@"Root" target:self];
        _kgSpecifiers = [self kg_filterSpecifiers:all];
    }
    return _kgSpecifiers;
}

// 只有「液态玻璃」档才需要那四个自定义参数, 其它档位把它们整组收起来
- (NSArray *)kg_filterSpecifiers:(NSArray *)all {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kKGPrefsDomain];
    NSInteger material = [defaults objectForKey:@"Material"] ? [defaults integerForKey:@"Material"] : 3;
    if (material == 3) return all;

    NSMutableArray *kept = [NSMutableArray array];
    for (PSSpecifier *specifier in all) {
        if ([[specifier propertyForKey:@"liquidOnly"] boolValue]) continue;
        [kept addObject:specifier];
    }
    return kept;
}

// 切换档位/开关后重新展开列表, 让参数组的显隐立刻跟上
- (void)setPreferenceValue:(id)value specifier:(PSSpecifier *)specifier {
    [super setPreferenceValue:value specifier:specifier];

    NSString *key = [specifier propertyForKey:@"key"];
    if ([key isEqualToString:@"Material"] || [key isEqualToString:@"Enabled"]) {
        _kgSpecifiers = nil;
        [self reloadSpecifiers];
    }
}

// 「恢复本页默认设置」按钮: 只清掉液态玻璃那四个自定义参数与圆角, 保留开关与档位
- (void)resetPage:(PSSpecifier *)specifier {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kKGPrefsDomain];
    for (NSString *key in @[ @"LiquidBlur", @"LiquidRefraction", @"LiquidHighlight",
                             @"LiquidVeil", @"CornerRadius" ]) {
        [defaults removeObjectForKey:key];
    }
    [defaults synchronize];
    _kgSpecifiers = nil;
    [self reloadSpecifiers];
}

@end
