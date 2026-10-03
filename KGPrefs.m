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
static const NSInteger kKGParamsVersion = 6;

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
        // v0.6.0: 按键区底色调淡强度。默认 0.75 -> 调到原来的 25%。
        // 「按键区不透明」是这个版本要解决的主问题, 所以默认就开着,
        // 用户觉得太透可以拖回 0。
        @"KeyplaneDim":        @0.75,
        // v0.6.0 已废弃: GlassOverKeys 恒为 NO, 这里保留只为清掉旧存档。
        @"GlassOverKeys":      @NO,
        @"DebugLog":           @NO,
        @"ShowLayerOutline":   @NO,
        // 默认「纯探针」: 唯一一档被用户实测过「能打字」的。
        // 完整档会插玻璃层 + 藏原生背景, 这两件事都还在验证中, 不能默认开。
        @"WorkMode":           @(KGWorkModeProbe),
    }];
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
    // v0.6.0: 默认把按键区底色调到 25% —— 「按键区不透明」是这一版要解决的主问题。
    [d setObject:@0.75                   forKey:@"KeyplaneDim"];
    [d setObject:@NO                     forKey:@"GlassOverKeys"];
    // v0.4.1 起退回「纯探针」, v0.5.0 继续保持。
    //
    // v0.3.0 我把默认设成 Full, 理由是「玻璃层是纯 CALayer, 不可能挡触摸」——
    // 这个理由是错的, 而且从没被验证过: 用户说「能打字」时用的是 Probe/Hide 档,
    // 那两档根本不插玻璃层。v0.4.0 上了 Full 档后用户立刻反馈「又不能点击了」。
    //
    // v0.5.0 玻璃层从 CALayer 换成了 UIView, 触摸安全从「layer 天生不参与命中」
    // 换成「显式 userInteractionEnabled=NO」。机制上更硬, 但**依然没实测过**。
    // 铁律不变: 默认档必须是用户亲自验证过能打字的那一档。
    [d setObject:@(KGWorkModeProbe)        forKey:@"WorkMode"];
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
    // 新架构下最低档也带雾感, 但仍然把 0 兜到 1, 不给「看起来像没生效」留余地。
    if (s.blur < 1.0)       s.blur = 1.0;
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

+ (KGWorkMode)workMode {
    NSUserDefaults *d = [self defaults];
    if ([d objectForKey:@"WorkMode"] == nil) return KGWorkModeProbe;
    NSInteger raw = [d integerForKey:@"WorkMode"];
    if (raw < KGWorkModeProbe || raw > KGWorkModeFull) return KGWorkModeProbe;
    return (KGWorkMode)raw;
}

+ (BOOL)showLayerOutline {
    return [[self defaults] boolForKey:@"ShowLayerOutline"];
}

+ (BOOL)glassOverKeys {
    // 【v0.6.0 已废弃】永远返回 NO。实测两次「打开就不能打字」(见 KGPrefs.h)。
    // 保留这个方法只是为了让旧代码还能编过, 设置面板也不再暴露它。
    return NO;
}

+ (CGFloat)keyplaneDim {
    CGFloat v = [[self defaults] doubleForKey:@"KeyplaneDim"];
    if (v < 0) v = 0;
    if (v > 1) v = 1;
    return v;
}

+ (BOOL)debugLog {
    kKGDebugEnabled = [[self defaults] boolForKey:@"DebugLog"];
    return kKGDebugEnabled;
}

@end
