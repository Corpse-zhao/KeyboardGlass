#import "KGRootListController.h"
#import <sys/stat.h>

static NSString * const kKGPrefsDomain = @"com.banli.keyboardglass.preferences";

// 探针: 诊断「设置页面空白」用。写到 Filza 能直接看的地方,
// 三个探针点分别区分 bundle 加载 / 类实例化 / plist 解析 哪一环断了。
static void KGProbe(NSString *msg) {
    mkdir("/var/mobile/Documents/KeyboardGlass", 0755);
    FILE *f = fopen("/var/mobile/Documents/KeyboardGlass/prefs_probe.txt", "a");
    if (f) {
        fprintf(f, "%s\n", msg.UTF8String);
        fclose(f);
    }
    NSLog(@"[KeyboardGlass][prefs] %@", msg);
}

@implementation KGRootListController

+ (void)load {
    KGProbe(@"[1] +load —— bundle 二进制已成功加载");
}

- (instancetype)init {
    self = [super init];
    if (self) {
        KGProbe(@"[2] -init —— NSPrincipalClass 实例化成功");
    }
    return self;
}

- (NSArray *)specifiers {
    if (!_specifiers) {
        NSArray *all = nil;
        @try {
            all = [self loadSpecifiersFromPlistName:@"Root" target:self];
        } @catch (NSException *exception) {
            KGProbe([NSString stringWithFormat:@"[3] plist 解析异常: %@", exception]);
            all = @[];
        }
        KGProbe([NSString stringWithFormat:@"[3] -specifiers —— Root.plist 解析出 %lu 个条目",
                 (unsigned long)all.count]);
        _specifiers = [self kg_filterSpecifiers:all];
    }
    return _specifiers;
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
        _specifiers = nil;
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
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
