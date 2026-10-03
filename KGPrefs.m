#import "KGPrefs.h"
#import <stdarg.h>

NSString * const KGPrefsSuiteName = @"com.banli.keyboardglass.preferences";

// 参数默认值。
// 早期版本取的是 GlassSuiteX 的默认 (模糊 5 / 折射 9 / 高光 0.51 / 底色 0),
// 但那是给「通知横幅」调的 —— 键盘底下是整块 App 内容, 那组数值放在键盘上
// 几乎等于全透明, 用户完全看不出装了插件。这里换成在键盘上肉眼可辨的一组。
//
// 【v0.5.0 关键修正】模糊从 12 提到 18, 并且**任何情况下都不允许为 0**。
// 实测日志实锤用户存档里 blur=0.0:
//     [install ...] blur=0.0 refraction=10.0 highlight=0.65 veil=0.42
// 旧版 blur 是直接喂给 CABackdropLayer 的 radius 的, 0 就等于「完全不采背景」——
// 玻璃整个关掉, 屏幕上只剩下 veil 的一点白。用户看到的「完全透明」就是这一条。
// 现在 blur 走 UIVisualEffectView 的档位映射, 最低档 (ThinMaterial) 也带雾感。
static const CGFloat kKGDefaultBlur         = 18.0;
static const CGFloat kKGDefaultRefraction   = 14.0;
static const CGFloat kKGDefaultHighlight    = 0.55;
// v0.5.0 从 0.42 提到 0.52: 玻璃的「可见度」主要靠底色, 0.42 在浅色 App 上
// 压不住底下的文字。0.52 既有明显玻璃感, 又保证按键字看得清。
static const CGFloat kKGDefaultVeil         = 0.52;
// v0.5.0 圆角从 0 提到 10: iOS 26 的键盘玻璃四角是圆的, 直角永远差那口气。
// 只圆上面两个角, 下面贴屏幕底边。
static const CGFloat kKGDefaultCornerRadius = 10.0;

// 参数版本号。1 = 早期那组不可见的默认值; 2 = 液态玻璃推荐值;
// 3 = 二分隔离结束, 工作模式默认切到「完整」;
// 4 = v0.4.0 批量藏背景导致键盘哑掉, 默认退回「纯探针」(用户实测能打字的那档);
// 5 = v0.5.0 换 UIVisualEffectView 架构, 模糊/底色/圆角全部换新默认。
//     **必须升**: 用户存档里的 blur=0.0 是旧架构的产物, 不迁移的话
//     换架构之后依然是 0, 用户会以为新版本也没生效。
// 6 = v0.6.0 删掉 GlassOverKeys (实测两次「打开就打不了字」), 新增「按键区底色调淡」。
//     **必须升**: 用户存档里 GlassOverKeys 很可能开着, 不迁移的话设置面板里
//     还会露出那个开关, 用户一开就又打不了字 —— 又是一次「装上就废」。
// 8 = v1.0.0 架构重写。**必须升**, 两个原因:
//     a) 删除 WorkMode(工作模式)。v1.0.0 只按「uie=0 铁律」单线施工,
//        不再需要二分隔离档位; 留着旧档位只会让人拖到「纯探针」以为插件没生效。
//     b) 新增 GlassTransparency。这是 v1.0.0 唯一的新参数, 且它控制的
//        那层(_UIVisualEffectBackdropView)实测 uie=0, 是键盘「实心浅灰」
//        真正的元凶。旧存档里没有它, 不迁移就永远是 registerDefaults 的 0.65,
//        而用户之前十一个版本攒下的「底色浓度」是按另一套语义调出来的, 得重置。
// 9 = v1.1.0 新增五个动作的独立开关 + 安全档。
// 11 = v3.0.0 推翻重做: 删掉 v2.0.0 的 ExtProbe/HostKeyboardActions,
//新增「底板白度」(BackdropWhiteness)。
//     **必须升**, 三个原因:
//     a) 不升的话用户存档里留着 ExtProbe=YES, 而探针代码已删 —— 面板会
//        显示一个不存在的开关, 拨它毫无反应。
//     b) 旧存档里没有 BackdropWhiteness, 不迁移就用 registerDefaults 的
//        默认值。默认值本身设成「肉眼可辨」, 所以不迁移也能出效果。
//     c) 十三版攒下的 GlassTransparency/KeyplaneDim 是按「调效果图层」
//        的语义拖出来的, 那个方向已被数据证伪, 必须重置回推荐值。
static const NSInteger kKGParamsVersion = 11;

// v1.0.0: 玻璃通透度默认值。系统那层浓白调淡 65% —— 留 35% 压住, 保证
// 按键上的白字在浅色 App 背景下仍然读得清。拖到 1.0 玻璃感最强。
static const CGFloat kKGDefaultGlassTransparency = 0.65;

// v1.0.0: 按键区底色调淡默认值。与通透度分开, 因为这两层压在一起才
// 决定「按键区透不透」。0.7 调淡 70% 留 30% 底色, 键缝能透出玻璃。
static const CGFloat kKGDefaultKeyplaneDim = 0.70;

// v3.0.0: 底板白度默认值。系统原本 0.10, 这里给 0.03 ——
// 「明显比系统通透」但「按键字还读得清」的那一档。
// 定这个值的依据: 探针实测 bg=1.00/1.00/1.00/0.10, 铺满整个键盘区。
// 调到 0 会让浅色 App 上的按键白字失去对比度, 用户会以为按键坏了。
static const CGFloat kKGDefaultBackdropWhiteness = 0.03;

static BOOL kKGDebugEnabled = NO;

void KGLog(NSString *format, ...) {
    if (!kKGDebugEnabled) return;
    va_list args;
    va_start(args, format);
    NSString *msg = [[NSString alloc] initWithFormat:format arguments:args];
    va_end(args);
    NSLog(@"[KeyboardGlass] %@", msg);
}

@implementation KGPrefs

+ (NSUserDefaults *)defaults {
    static NSUserDefaults *defaults = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        defaults = [[NSUserDefaults alloc] initWithSuiteName:KGPrefsSuiteName];
    });
    return defaults;
}

+ (void)registerDefaults {
    [[self defaults] registerDefaults:@{
        @"Enabled":            @YES,
        @"Material":           @(KGMaterialLiquid),
        @"LiquidBlur":         @(kKGDefaultBlur),
        @"LiquidRefraction":   @(kKGDefaultRefraction),
        @"LiquidHighlight":    @(kKGDefaultHighlight),
        @"LiquidVeil":         @(kKGDefaultVeil),
        @"CornerRadius":       @(kKGDefaultCornerRadius),
        // 默认 YES: 玻璃层插在原生背板的上一层, 藏着它的话玻璃只会采到
        // 那块背板本身, 模糊等于没做。想让玻璃真采到键盘下方的画面就得让位。
        @"HideNativeBackdrop": @YES,
        // v1.0.0: 玻璃通透度。控制 _UIVisualEffectBackdropView(系统那层
        // 85% 浓白, 实测 uie=0)的调淡程度 —— 键盘「实心浅灰」的真凶。
        @"GlassTransparency":  @(kKGDefaultGlassTransparency),
        // v1.0.0: 按键区底色调淡。v0.7.3 那个 0.55「触摸安全下限」已删除 ——
        // 实测 UIKBSplitImageView 是 uie=0 纯视觉层, 本来就与触摸派发无关,
        // 加下限只是自己吓自己, 还把观感自由度锁死了。
        @"KeyplaneDim":        @(kKGDefaultKeyplaneDim),
        @"DebugLog":           @NO,
        @"ShowLayerOutline":   @NO,

        // ---- v3.0.0: 底板白度 ----
        // 系统在 UIKBBackdropView 上铺的那层白, 探针实测 bg=1.00/1.00/1.00/0.10。
        // 0.10 已经很淡, 但键盘整体观感仍偏"实心浅灰" —— 因为它铺的是
        // **整个键盘区**。往上调(更白) = 更实心; 往下调(更透) = 玻璃感。
        // 默认 0.03: 保留一点点白以维持按键文字对比度, 同时明显比 0.10 通透。
        // 调0 就是全透, 键缝能看清下层 App 内容, 但浅色App 上按键字会发飘。
        @"BackdropWhiteness":  @(kKGDefaultBackdropWhiteness),
    }];
    // v1.0.0: WorkMode / GlassOverKeys 已彻底废弃, 这里**不注册**。
    // 注册一个永远没人读的下拉项, 只会让人拖到「纯探针」档以为插件没生效。
    kKGDebugEnabled = [[self defaults] boolForKey:@"DebugLog"];
    [self runParamsMigrationIfNeeded];
}

// 只跑一次: 把「老默认值 = 用户从没动过的存档」升级成肉眼可见的一组。
// 判据是 ParamsVersion 而不是参数内容 —— 用户后来自己拖到 0 是有意为之,
// 不能再被我们覆盖回去。
+ (BOOL)needsParamsMigration {
    return [[self defaults] integerForKey:@"ParamsVersion"] < kKGParamsVersion;
}

+ (void)writeRecommendedParams {
    NSUserDefaults *d = [self defaults];
    [d setObject:@(kKGParamsVersion)     forKey:@"ParamsVersion"];
    [d setObject:@(kKGDefaultBlur)       forKey:@"LiquidBlur"];
    [d setObject:@(kKGDefaultRefraction) forKey:@"LiquidRefraction"];
    [d setObject:@(kKGDefaultHighlight)  forKey:@"LiquidHighlight"];
    [d setObject:@(kKGDefaultVeil)       forKey:@"LiquidVeil"];
    [d setObject:@(kKGDefaultCornerRadius) forKey:@"CornerRadius"];
    [d setObject:@YES                    forKey:@"HideNativeBackdrop"];
    // v1.0.0 推荐值。
    [d setObject:@(kKGDefaultGlassTransparency) forKey:@"GlassTransparency"];
    [d setObject:@(kKGDefaultKeyplaneDim)       forKey:@"KeyplaneDim"];
    // v1.0.0: 把两个已废弃的下拉项从存档里**彻底删掉**, 不只是写个默认值。
    // 用户之前十一个版本攒下的 WorkMode / GlassOverKeys 没有保留价值,
    // 留着只会让设置面板冒出没人认得的档位名。
    [d removeObjectForKey:@"WorkMode"];
    [d removeObjectForKey:@"GlassOverKeys"];
    // v2.0.0~v3.0.0: 探针期与六个二分开关全部清掉。v2.0.0 是纯探针版,
    // 探针文件已随引擎重写删除, ExtProbe 留着会让人以为还有一个开关在
    // 控制什么。六个二分开关的整个设计前提也已被全量数据证伪。
    for (NSString *dead in @[@"SafeMode", @"ActionGlass", @"ActionVeil",
                             @"ActionAssistantBar", @"ActionKeyBottom",
                             @"ActionFullscreenWhite",
                             @"ExtProbe", @"HostKeyboardActions"]) {
        [d removeObjectForKey:dead];
    }
    // v3.0.0: 唯一的新参数 —— 底板白度。
    [d setObject:@(kKGDefaultBackdropWhiteness) forKey:@"BackdropWhiteness"];
    [d synchronize];
}

+ (void)runParamsMigrationIfNeeded {
    if (![self needsParamsMigration]) return;
    [self writeRecommendedParams];
    KGLog(@"参数已迁移到 v%ld: blur=%.1f refraction=%.1f highlight=%.2f veil=%.2f",
          (long)kKGParamsVersion, kKGDefaultBlur, kKGDefaultRefraction,
          kKGDefaultHighlight, kKGDefaultVeil);
}

+ (KGMaterial)material {
    if (![[self defaults] boolForKey:@"Enabled"]) return KGMaterialOff;
    NSInteger raw = [[self defaults] integerForKey:@"Material"];
    if (raw < KGMaterialOff || raw > KGMaterialLiquid) raw = KGMaterialLiquid;
    return (KGMaterial)raw;
}

+ (KGStyle)styleForMaterial:(KGMaterial)material dark:(BOOL)dark {
    KGStyle s;
    NSUserDefaults *d = [self defaults];

    switch (material) {
        case KGMaterialUltra:
            // 超薄: 只留一点模糊, 几乎不改变观感
            s.blur = 4.0;  s.refraction = 0.0;  s.highlight = 0.15; s.veil = 0.10;
            break;
        case KGMaterialThin:
            s.blur = 9.0;  s.refraction = 0.0;  s.highlight = 0.25; s.veil = 0.16;
            break;
        case KGMaterialStd:
            // 标准: 接近系统原生毛玻璃的观感强度
            s.blur = 14.0; s.refraction = 0.0;  s.highlight = 0.35; s.veil = 0.22;
            break;
        case KGMaterialLiquid:
        default: {
            // 液态玻璃: 全部走用户自定义参数。
            // 存档还没迁移过的话, 里面是早期那组「几乎全透明」的旧默认值 ——
            // 这时先按推荐值渲染, 免得用户以为插件没装成功。
            if ([self needsParamsMigration]) {
                s.blur       = kKGDefaultBlur;
                s.refraction = kKGDefaultRefraction;
                s.highlight  = kKGDefaultHighlight;
                s.veil       = kKGDefaultVeil;
            } else {
                s.blur       = [d objectForKey:@"LiquidBlur"]       ? [d doubleForKey:@"LiquidBlur"]       : kKGDefaultBlur;
                s.refraction = [d objectForKey:@"LiquidRefraction"] ? [d doubleForKey:@"LiquidRefraction"] : kKGDefaultRefraction;
                s.highlight  = [d objectForKey:@"LiquidHighlight"]  ? [d doubleForKey:@"LiquidHighlight"]  : kKGDefaultHighlight;
                s.veil       = [d objectForKey:@"LiquidVeil"]       ? [d doubleForKey:@"LiquidVeil"]       : kKGDefaultVeil;
            }
            break;
        }
    }

    s.cornerRadius = [d objectForKey:@"CornerRadius"] ? [d doubleForKey:@"CornerRadius"] : kKGDefaultCornerRadius;
    s.dark = dark;

    // 数值护栏: 设置端给的范围一旦被外部改写, 这里保证不产生非法几何
    if (s.blur < 0)         s.blur = 0;
    if (s.blur > 40)        s.blur = 40;
    if (s.refraction < 0)   s.refraction = 0;
    if (s.refraction > 60)  s.refraction = 60;
    if (s.highlight < 0)    s.highlight = 0;
    if (s.highlight > 1)    s.highlight = 1;
    if (s.veil < 0)         s.veil = 0;
    if (s.veil > 1)         s.veil = 1;
    if (s.cornerRadius < 0) s.cornerRadius = 0;
    if (s.cornerRadius > 40) s.cornerRadius = 40;

    // 【v0.5.0】模糊不许为 0。
    // 旧架构下 blur 直接当 backdrop 的 radius, 0 = 整个玻璃关掉, 屏幕全透明。
    // 用户实测存档里就是 blur=0.0, 这是「没达到预期效果」最直接的一条原因。
    //
    // 【v0.7.0 下限从 1.0 提到 6.0 —— 1.0 是个陷阱档】
    // KGEffectStyleForBlur 的档位切分: <=2.5 走 SystemThinMaterial,
    // 而 ThinMaterial 的磨砂非常弱, 视觉上几乎等于没模糊。用户截图里
    // 「模糊强度 1.0」就是这么来的 —— 滑块拖到最左, 结果看着像插件没生效,
    // 实际上模糊在, 只是弱到看不出来。6.0 对应 SystemMaterial, 起雾,
    // 是「肉眼能确认玻璃存在」的最低档。
    if (s.blur < 6.0)       s.blur = 6.0;
    return s;
}

+ (KGStyle)styleForCurrentMaterialDark:(BOOL)dark {
    return [self styleForMaterial:[self material] dark:dark];
}

+ (CGFloat)keyboardScale {
    CGFloat v = [[self defaults] doubleForKey:@"KeyboardScale"];
    if (v <= 0) v = 100.0;
    return v;
}

+ (BOOL)scaleEnabled {
    return [[self defaults] boolForKey:@"KeyboardScaleEnabled"];
}

+ (BOOL)hideNativeBackdrop {
    NSUserDefaults *d = [self defaults];
    if ([d objectForKey:@"HideNativeBackdrop"] == nil) return NO;
    return [d boolForKey:@"HideNativeBackdrop"];
}

+ (BOOL)showLayerOutline {
    return [[self defaults] boolForKey:@"ShowLayerOutline"];
}

+ (CGFloat)glassTransparency {
    NSUserDefaults *d = [self defaults];
    if ([d objectForKey:@"GlassTransparency"] == nil) {
        return kKGDefaultGlassTransparency;
    }
    CGFloat v = [d doubleForKey:@"GlassTransparency"];
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    return v;
}

+ (CGFloat)keyplaneDim {
    CGFloat v = [[self defaults] doubleForKey:@"KeyplaneDim"];
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    return v;
}

// ---- v3.0.0: 底板白度 ----
// 语义: 直接就是 UIKBBackdropView 那层白的 alpha。0 = 全透, 1 = 全白。
// 不用再像 GlassTransparency 那样绕一层「调淡比例」—— 那个间接映射
// 是十三版「调了半天看不出变化」的帮凶之一。这里给什么值就是什么值。
+ (CGFloat)backdropWhiteness {
    NSUserDefaults *d = [self defaults];
    if ([d objectForKey:@"BackdropWhiteness"] == nil) {
        return kKGDefaultBackdropWhiteness;
    }
    CGFloat v = [d doubleForKey:@"BackdropWhiteness"];
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    return v;
}

+ (BOOL)debugLog {
    kKGDebugEnabled = [[self defaults] boolForKey:@"DebugLog"];
    return kKGDebugEnabled;
}

@end
