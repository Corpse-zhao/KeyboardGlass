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
// 5 = v0.5.0 换 UIVisualEffectView 架构, 模糊/底色/圆角换新默认,
// 6 = v0.6.0 删掉 GlassOverKeys (实测两次导致打不了字), 新增「按键区底色调淡」。
// 8 = v1.0.0 架构重写: 删掉 WorkMode 二分隔离档位, 新增「玻璃通透度」。
// 9 = v1.1.0 新增五个动作的独立开关 + 安全档。
// 10 = v2.0.0 架构转向微信输入法: 六个二分开关整体废弃, 换成
//「扩展进程探针(默认开) + 宿主旧逻辑(默认关)」。
// 11 = v3.0.0 推翻重做: 删掉 v2.0.0 那两个开关(探针代码已随引擎重写删除),
//新增「底板白度」。旧存档里 GlassTransparency/KeyplaneDim 是按
//     「调效果图层」的语义拖出来的, 那个方向已被全量探针数据证伪, 必须重置。
//
// **必须和 KGPrefs.m 里的 kKGParamsVersion 保持一致。**
// v0.4.3 之前两边是 4 和 5 不一致 —— 插件进程先迁移到自己的版本号, 设置
// 进程再迁移一次, 谁先跑谁说了算, 迁移结果不确定。这类「双份常量」必须
// 当成一个字段看待, 改一边就要同时改另一边。
static const NSInteger kKGParamsVersion = 11;
static const double kKGRecommendedBlur       = 18.0;
static const double kKGRecommendedRefraction = 14.0;
static const double kKGRecommendedHighlight  = 0.55;
static const double kKGRecommendedVeil       = 0.52;
static const double kKGRecommendedRadius     = 10.0;
static const double kKGRecommendedTransp     = 0.65;  // v1.0.0: 玻璃通透度
static const double kKGRecommendedKeyDim     = 0.70;  // v1.0.0: 触摸下限已删, 纯观感
// v3.0.0: 底板白度。与 KGPrefs.m 的 kKGDefaultBackdropWhiteness 必须一致。
// 系统原本 0.10(探针实测 bg=1.00/1.00/1.00/0.10), 0.03 是「明显更透
// 但按键字仍读得清」的那一档。
static const double kKGRecommendedBackdrop   = 0.03;

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
    [defaults setObject:@YES                        forKey:@"HideNativeBackdrop"];
    [defaults setObject:@(kKGRecommendedTransp)     forKey:@"GlassTransparency"];
    [defaults setObject:@(kKGRecommendedKeyDim)     forKey:@"KeyplaneDim"];
    // v1.0.0: 三个已废弃的下拉项/开关**从存档里彻底删除**。
    // WorkMode 是 v0.3.0~0.7.4 的二分隔离产物, v1.0.0 按 uie=0 铁律
    // 单线施工, 不再需要档位; GlassOverKeys 是 v0.6.0 的废项。
    // 留着它们, 用户会拖到「① 纯探针」然后以为插件没生效。
    [defaults removeObjectForKey:@"WorkMode"];
    [defaults removeObjectForKey:@"GlassOverKeys"];
    // v2.0.0~v3.0.0: 探针期产物与六个二分开关**彻底清掉**。
    //   六个二分开关的整个设计前提是「在宿主进程里改宿主层就能调出玻璃效果」,
    //   而 v1.1.0 探针的 253MB 全量数据已经把这个前提彻底推翻 ——
    //   真正的目标层是 UIKBBackdropView(系统铺在键盘区的那层白)。
    //   v2.0.0 的 ExtProbe/HostKeyboardActions 属于纯探针期, 引擎重写后
    //   探针代码已删除, 留着会让人以为还有开关在控制什么。
    for (NSString *dead in @[@"SafeMode", @"ActionGlass", @"ActionVeil",
                             @"ActionAssistantBar", @"ActionKeyBottom",
                             @"ActionFullscreenWhite",
                             @"ExtProbe", @"HostKeyboardActions"]) {
        [defaults removeObjectForKey:dead];
    }
    // v3.0.0: 唯一的新参数 —— 底板白度。系统原本 0.10, 推荐 0.03。
    [defaults setObject:@(kKGRecommendedBackdrop)  forKey:@"BackdropWhiteness"];
    [defaults synchronize];
    KGProbe([NSString stringWithFormat:@"[migrate] 参数版本 %ld -> %ld, 已写入 v3.0.0 推荐值(底板白度=%.2f) + v2.0/v1.1 八个开关已清除 + 熔断计数已清零",
             (long)old, (long)kKGParamsVersion, kKGRecommendedBackdrop]);
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

        // 【v3.0.0 去掉 @try/@catch】原来是这么写的:
        //     @try { all = [self loadSpecifiersFromPlistName:@"Root" target:self]; }
        //     @catch (NSException *e) { all = @[]; }
        // 理由是「plist 坏了要让面板空着而不是崩」。但 bundle 跑在「设置」
        // 进程里, 崩了只是设置 App 闪退, 而 v2.0.0 已经实测: Logos 的
        // 预处理器可能把 @catch 当成自己的 @c 指令吃掉, 吐出裸 C++ 语法,
        // 直接让整个构建失败。权衡: 为一个「plist 坏了」的小概率换一个
        // 真实的构建失败风险, 不值当。loadSpecifiersFromPlistName 返回 nil
        // 时下面 KGProbe 照样会记下, 排查手段没丢。
        NSArray *all = [self loadSpecifiersFromPlistName:@"Root" target:self];
        if (!all) all = @[];
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
    [defaults setObject:@(kKGRecommendedTransp)     forKey:@"GlassTransparency"];
    [defaults setObject:@(kKGRecommendedKeyDim)     forKey:@"KeyplaneDim"];
    // v3.0.0: 这一版真正起作用的那个参数。
    [defaults setObject:@(kKGRecommendedBackdrop)   forKey:@"BackdropWhiteness"];
    [defaults removeObjectForKey:@"WorkMode"];
    [defaults removeObjectForKey:@"GlassOverKeys"];
    // v2.0.0~v3.0.0 的八个废弃键, 恢复默认时一并清干净。
    for (NSString *dead in @[@"SafeMode", @"ActionGlass", @"ActionVeil",
                             @"ActionAssistantBar", @"ActionKeyBottom",
                             @"ActionFullscreenWhite",
                             @"ExtProbe", @"HostKeyboardActions"]) {
        [defaults removeObjectForKey:dead];
    }
    [defaults synchronize];
    KGProbe([NSString stringWithFormat:@"[reset] 已恢复 v3.0.0 推荐参数 (底板白度=%.2f, 废弃键已清除)",
             kKGRecommendedBackdrop]);
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
