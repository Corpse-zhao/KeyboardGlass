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

// 参数版本号。1 = 早期那组「在键盘上几乎全透明」的默认值, 2 = 液态玻璃推荐值,
// 3 = 工作模式默认切到「完整」(这一步是错的), 4 = 默认退回「纯探针」,
// 5 = v0.5.0 换 UIVisualEffectView 架构, 模糊/底色/圆角换新默认。
//
// **必须和 KGPrefs.m 里的 kKGParamsVersion 保持一致。**
// v0.4.3 之前两边是 4 和 5 不一致 —— 插件进程先迁移到自己的版本号, 设置
// 进程再迁移一次, 谁先跑谁说了算, 迁移结果不确定。这类「双份常量」必须
// 当成一个字段看待, 改一边就要同时改另一边。
static const NSInteger kKGParamsVersion = 5;
static const NSInteger kKGWorkModeProbe = 0;   // 必须与 KGPrefs.m 的 KGWorkModeProbe 一致
static const double kKGRecommendedBlur       = 18.0;
static const double kKGRecommendedRefraction = 14.0;
static const double kKGRecommendedHighlight  = 0.55;
static const double kKGRecommendedVeil       = 0.52;
static const double kKGRecommendedRadius     = 10.0;

// 早期版本的默认值在键盘上完全看不出效果, 用户会以为插件没装成功。
// 这里在「设置」进程里做一次迁移 —— 这个进程不沙盒, 写进去的位置插件
// 一定读得到。判据是版本号而不是参数内容: 用户后来自己拖到 0 是有意的,
// 不能再被覆盖回去。
static void KGMigrateParamsIfNeeded(NSUserDefaults *defaults) {
    // 崩溃熔断状态必须无条件清掉。v0.4.1 崩过一次之后计数已经满了,
    // 用户装回新版本时若不清, 插件会一直处于「已熔断」状态啥也不干 ——
    // 看起来就像装了没用。不清它, 用户永远不会知道插件其实是关着的。
    [defaults removeObjectForKey:@"CircuitOpen"];
    [defaults removeObjectForKey:@"CrashCount"];
    [defaults removeObjectForKey:@"CrashLastTime"];

    if ([defaults integerForKey:@"ParamsVersion"] >= kKGParamsVersion) return;

    NSInteger old = [defaults integerForKey:@"ParamsVersion"];
    [defaults setObject:@(kKGParamsVersion)         forKey:@"ParamsVersion"];
    [defaults setObject:@(kKGRecommendedBlur)       forKey:@"LiquidBlur"];
    [defaults setObject:@(kKGRecommendedRefraction) forKey:@"LiquidRefraction"];
    [defaults setObject:@(kKGRecommendedHighlight)  forKey:@"LiquidHighlight"];
    [defaults setObject:@(kKGRecommendedVeil)       forKey:@"LiquidVeil"];
    [defaults setObject:@(kKGRecommendedRadius)      forKey:@"CornerRadius"];
    // v0.4.1: 退回纯探针 —— 唯一被实测确认「能打字」的一档。
    // v0.3.0~0.4.0 我错误地把默认设成了「完整」, 理由是一句没验证过的推断,
    // 结果用户直接反馈「又不能点击了」。默认档必须是用户亲自验证过的。
    [defaults setObject:@(kKGWorkModeProbe)         forKey:@"WorkMode"];
    [defaults setObject:@YES                        forKey:@"HideNativeBackdrop"];
    [defaults setObject:@NO                         forKey:@"GlassOverKeys"];
    [defaults synchronize];
    KGProbe([NSString stringWithFormat:@"[migrate] 参数版本 %ld -> %ld, 已写入推荐值 + 工作模式=纯探针 + 熔断计数已清零",
             (long)old, (long)kKGParamsVersion]);
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
        // 先迁移再读 plist, 否则滑块会按旧值显示
        KGMigrateParamsIfNeeded([[NSUserDefaults alloc] initWithSuiteName:kKGPrefsDomain]);

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

// 「恢复本页默认设置」按钮: 把参数写回推荐值, 保留启用开关与档位
- (void)resetPage:(PSSpecifier *)specifier {
    NSUserDefaults *defaults = [[NSUserDefaults alloc] initWithSuiteName:kKGPrefsDomain];
    [defaults setObject:@(kKGParamsVersion)         forKey:@"ParamsVersion"];
    [defaults setObject:@(kKGRecommendedBlur)       forKey:@"LiquidBlur"];
    [defaults setObject:@(kKGRecommendedRefraction) forKey:@"LiquidRefraction"];
    [defaults setObject:@(kKGRecommendedHighlight)  forKey:@"LiquidHighlight"];
    [defaults setObject:@(kKGRecommendedVeil)       forKey:@"LiquidVeil"];
    [defaults setObject:@(kKGRecommendedRadius)      forKey:@"CornerRadius"];
    [defaults setObject:@YES                        forKey:@"HideNativeBackdrop"];
    [defaults setObject:@NO                         forKey:@"GlassOverKeys"];
    [defaults setObject:@(kKGWorkModeProbe)         forKey:@"WorkMode"];
    [defaults synchronize];
    KGProbe(@"[reset] 已恢复推荐参数 (工作模式=纯探针)");
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
