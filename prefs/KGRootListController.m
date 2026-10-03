#import "KGRootListController.h"
#import <sys/stat.h>

static NSString * const kKGPrefsDomain = @"com.banli.keyboardglass.preferences";

// 崩溃计数文件。**必须和 KGEngine.m 里的 kKGCrashFile 一字不差。**
// 【为什么写成两份】引擎那份是 C 字符串(信号处理器里只能用
// async-signal-safe 的 open/read/write, 不能碰 NSString), 这份是
// NSString(设置进程里删文件用)。路径写错的后果是「设置面板清了计数,
// 但引擎读的是另一个文件」—— 熔断解不开, 而且极难排查。
// 判据放在 check_offline.py 里逐字比对。
static NSString * const kKGCrashCountFile =
    @"/var/mobile/Documents/KeyboardGlass/crash_count.txt";

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
// 12 = v3.0.1 撤回「底板白度」: 它会去写 uie=1 的系统底板, 用户装 v3.0.0
//     后疑似系统异常。改成用玻璃层盖住那层白, 滑块整个作废并清除。
//
// **必须和 KGPrefs.m 里的 kKGParamsVersion 保持一致。**
static const NSInteger kKGParamsVersion = 12;
static const double kKGRecommendedBlur       = 18.0;
static const double kKGRecommendedRefraction = 14.0;
static const double kKGRecommendedHighlight  = 0.55;
static const double kKGRecommendedVeil       = 0.52;
static const double kKGRecommendedRadius     = 10.0;
static const double kKGRecommendedTransp     = 0.65;  // v1.0.0: 玻璃通透度
static const double kKGRecommendedKeyDim     = 0.70;  // v1.0.0: 触摸下限已删, 纯观感
// 【v3.0.1 已删除】kKGRecommendedBackdrop(底板白度推荐值)。
// 它唯一的作用是写 `UIKBBackdropView`(系统底板, uie=1)的 backgroundColor ——
// 也就是 v3.0.0 唯一一处越界动作。常量跟着滑块一起作废, 留在这里只会
// 让下一个人以为「改白度」还是一条可走的路。

// 早期版本的默认值在键盘上完全看不出效果, 用户会以为插件没装成功。
// 这里在「设置」进程里做一次迁移 —— 这个进程不沙盒, 写进去的位置插件
// 一定读得到。判据是版本号而不是参数内容: 用户后来自己拖到 0 是有意的,
// 不能再被覆盖回去。
static void KGMigrateParamsIfNeeded(NSUserDefaults *defaults) {
    // 崩溃熔断状态必须无条件清掉。v0.4.1 崩过一次之后计数已经满了,
    // 用户装回新版本时若不清, 插件会一直处于「已熔断」状态啥也不干 ——
    // 看起来就像装了没用。不清它, 用户永远不会知道插件其实是关着的。
    //
    //【v3.0.1 新增: 计数已经从 NSUserDefaults 搬到文件】
    // 引擎侧改成读 /var/mobile/Documents/KeyboardGlass/crash_count.txt,
    // 因为信号处理器里绝对不能碰 NSUserDefaults(不是 async-signal-safe,
    // 崩溃时调用会二次崩溃)。**这意味着上面那三行 removeObjectForKey
    // 已经清不到真正的计数了** —— 只清 NSUserDefaults 的话, 用户上次
    // 撞满 5 次留下的文件计数会让v3.0.1 一装上就处于熔断态,
    // 表现是「插件装了但一点反应都没有」。所以必须连文件一起删。
    [defaults removeObjectForKey:@"CircuitOpen"];
    [defaults removeObjectForKey:@"CrashCount"];
    [defaults removeObjectForKey:@"CrashLastTime"];
    [[NSFileManager defaultManager] removeItemAtPath:kKGCrashCountFile error:NULL];

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
    // v2.0.0~v3.0.1: 探针期产物、六个二分开关、以及 v3.0.0 的底板白度
    //**彻底清掉**。
    //   六个二分开关的整个设计前提是「在宿主进程里改宿主层就能调出玻璃效果」,
    //   而 v1.1.0 探针的 253MB 全量数据已经把这个前提彻底推翻。
    //   v2.0.0 的 ExtProbe/HostKeyboardActions 属于纯探针期, 引擎重写后
    //   探针代码已删除, 留着会让人以为还有开关在控制什么。
    //   BackdropWhiteness 是 v3.0.0 唯一的新参数, 也是那次「疑似系统异常」
    //   的唯一嫌疑动作 —— **必须清掉, 不能只是不用它**。留在存档里的理由是
    //   「万一以后想恢复」, 但恢复它的前提是那条路被证明安全, 而现在没有。
    for (NSString *dead in @[@"SafeMode", @"ActionGlass", @"ActionVeil",
                             @"ActionAssistantBar", @"ActionKeyBottom",
                             @"ActionFullscreenWhite",
                             @"ExtProbe", @"HostKeyboardActions",
                             @"BackdropWhiteness"]) {
        [defaults removeObjectForKey:dead];
    }
    [defaults synchronize];
    KGProbe([NSString stringWithFormat:@"[migrate] 参数版本 %ld -> %ld, 已写入 v3.0.1 推荐值 + v3.0/v2.0/v1.1 九个废弃键已清除 + 熔断计数已清零",
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
    [defaults removeObjectForKey:@"WorkMode"];
    [defaults removeObjectForKey:@"GlassOverKeys"];
    // v2.0.0~v3.0.1 的九个废弃键, 恢复默认时一并清干净。
    // BackdropWhiteness 在其中 —— 「恢复默认」绝不能把一个会导致系统异常的
    // 参数又写回去, 那等于给用户一个一键复现故障的按钮。
    for (NSString *dead in @[@"SafeMode", @"ActionGlass", @"ActionVeil",
                             @"ActionAssistantBar", @"ActionKeyBottom",
                             @"ActionFullscreenWhite",
                             @"ExtProbe", @"HostKeyboardActions",
                             @"BackdropWhiteness"]) {
        [defaults removeObjectForKey:dead];
    }
    [defaults synchronize];
    KGProbe(@"[reset] 已恢复 v3.0.1 推荐参数 (九个废弃键已清除)");
    _specifiers = nil;
    [self reloadSpecifiers];
}

@end
