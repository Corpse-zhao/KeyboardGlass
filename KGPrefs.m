#import "KGPrefs.h"

NSString * const KGPrefsSuiteName = @"com.banli.keyboardglass.preferences";

// 参数默认值 —— 起点参考自 GlassSuiteX 的实际默认 (模糊 5 / 折射 9 / 高光 0.51 / 底色 0)
static const CGFloat kKGDefaultBlur         = 5.0;
static const CGFloat kKGDefaultRefraction   = 9.0;
static const CGFloat kKGDefaultHighlight    = 0.51;
static const CGFloat kKGDefaultVeil         = 0.0;
static const CGFloat kKGDefaultCornerRadius = 12.0;

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
        @"HideNativeBackdrop": @YES,
        @"DebugLog":           @NO,
    }];
    kKGDebugEnabled = [[self defaults] boolForKey:@"DebugLog"];
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
        default:
            // 液态玻璃: 全部走用户自定义参数
            s.blur         = [d objectForKey:@"LiquidBlur"] ? [d doubleForKey:@"LiquidBlur"] : kKGDefaultBlur;
            s.refraction   = [d objectForKey:@"LiquidRefraction"] ? [d doubleForKey:@"LiquidRefraction"] : kKGDefaultRefraction;
            s.highlight    = [d objectForKey:@"LiquidHighlight"] ? [d doubleForKey:@"LiquidHighlight"] : kKGDefaultHighlight;
            s.veil         = [d objectForKey:@"LiquidVeil"] ? [d doubleForKey:@"LiquidVeil"] : kKGDefaultVeil;
            break;
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
    if ([d objectForKey:@"HideNativeBackdrop"] == nil) return YES;
    return [d boolForKey:@"HideNativeBackdrop"];
}

+ (BOOL)debugLog {
    kKGDebugEnabled = [[self defaults] boolForKey:@"DebugLog"];
    return kKGDebugEnabled;
}

@end
