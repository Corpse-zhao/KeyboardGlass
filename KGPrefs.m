#import "KGPrefs.h"
#import <stdarg.h>

NSString * const KGPrefsSuiteName = @"com.banli.keyboardglass.preferences";

// 参数默认值。
// 早期版本取的是 GlassSuiteX 的默认 (模糊 5 / 折射 9 / 高光 0.51 / 底色 0),
// 但那是给「通知横幅」调的 —— 键盘底下是整块 App 内容, 那组数值放在键盘上
// 几乎等于全透明, 用户完全看不出装了插件。这里换成在键盘上肉眼可辨的一组。
static const CGFloat kKGDefaultBlur         = 12.0;
static const CGFloat kKGDefaultRefraction   = 10.0;
static const CGFloat kKGDefaultHighlight    = 0.65;
// v0.4.0 从 0.30 提到 0.42: 隐藏原生背板之后, 键盘底色全靠玻璃层的 veil 撑着。
// 0.30 × 0.65 = 0.195 的白几乎等于没有, 键盘透出底下的 App 内容会直接影响
// 按键文字的可读性, 用户也会怀疑「是不是没生效」。0.42 → 0.273, 既有明显
// 的玻璃感, 又保证字看得清。
static const CGFloat kKGDefaultVeil         = 0.42;
// 默认 0: 先不做圆角。圆角会让键盘四角露出下层内容, 而原生背板仍是直角,
// 两者叠加反而难看 —— 等基础材质确认无误后再作为第二步开启。
static const CGFloat kKGDefaultCornerRadius = 0.0;

// 参数版本号。1 = 早期那组不可见的默认值; 2 = 液态玻璃推荐值;
// 3 = 二分隔离结束, 工作模式默认切到「完整」;
// 4 = v0.4.0 批量藏背景导致键盘哑掉, 默认退回「纯探针」(用户实测能打字的那档)。
static const NSInteger kKGParamsVersion = 4;

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
    // v0.4.1: 退回「纯探针」。
    //
    // v0.3.0 我把默认设成 Full, 理由是「玻璃层是纯 CALayer, 不可能挡触摸」——
    // 这个理由是错的, 而且从没被验证过: 用户说「能打字」时用的是 Probe/Hide 档,
    // 那两档根本不插玻璃层。v0.4.0 上了 Full 档后用户立刻反馈「又不能点击了」。
    //
    // 教训: 「机制上不可能」不等于「实测不会」。默认档必须是**用户亲自验证过
    // 能打字**的那一档, 把完整档留给用户按需开启, 不能替他冒这个险。
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
    // 默认 NO: 玻璃压在按键上会遮挡按键, 能不能打字从未实测验证过。
    // 沿用「拿不准就退到已验证的那一侧」这条铁律。
    return [[self defaults] boolForKey:@"GlassOverKeys"];
}

+ (BOOL)debugLog {
    kKGDebugEnabled = [[self defaults] boolForKey:@"DebugLog"];
    return kKGDebugEnabled;
}

@end
