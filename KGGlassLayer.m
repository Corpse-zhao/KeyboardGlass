#import "KGGlassLayer.h"
#import <QuartzCore/QuartzCore.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

// 给任意 CALayer 挂高斯模糊。CAFilter 是私有类, 取不到就静默跳过 (降级为纯染色+高光)。
//
// v0.4.2: 整段包在 @try 里。KVC 写私有属性抛异常时, 如果正好发生在
// CoreAnimation 的布局/渲染回调里, 是**直接 abort 进程**, 不是让 App 崩一下 ——
// 键盘一起来就崩, 反复重启直接进安全模式。这里必须自己兜住。
static void KGApplyBlur(CALayer *layer, CGFloat radius) {
    @try {
        Class CAFilterClass = NSClassFromString(@"CAFilter");
        if (!CAFilterClass) return;
        SEL sel = NSSelectorFromString(@"filterWithName:");
        if (![CAFilterClass respondsToSelector:sel]) return;
        id filter = [CAFilterClass performSelector:sel withObject:@"gaussianBlur"];
        if (!filter) return;
        [filter setValue:@(radius) forKey:@"inputRadius"];
        layer.filters = @[filter];

        // CABackdropLayer 有个 enabled 开关, 某些系统版本默认关着
        if ([layer respondsToSelector:NSSelectorFromString(@"setEnabled:")]) {
            [layer setValue:@YES forKey:@"enabled"];
        }
    } @catch (NSException *exception) {
        NSLog(@"[KeyboardGlass] KGApplyBlur 异常, 已跳过模糊: %@", exception);
    }
}

// 顶部敞开的环形路径: 只保留上边与左右两侧, 底部往下多画 40pt 让底边跑出可视区,
// 这样键盘贴着屏幕底边的那一圈不会出现多余的高光/折射。
// 返回 UIBezierPath 而不是 CGPathRef —— CGPathRef 由这个局部对象持有, 直接返回它
// 会在函数返回后变成悬垂指针。
static UIBezierPath *KGMakeTopRingPath(CGRect bounds, CGFloat radius, CGFloat ringWidth) {
    CGFloat safeRadius = MAX(0, MIN(radius, bounds.size.width / 2.0));
    CGFloat w = MAX(0.5, ringWidth);

    CGRect outerRect = CGRectMake(0, 0, bounds.size.width, bounds.size.height + 40);
    CGRect innerRect = CGRectInset(outerRect, w, w);

    UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:outerRect
                                              byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight
                                                    cornerRadii:CGSizeMake(safeRadius, safeRadius)];
    CGFloat innerRadius = MAX(0, safeRadius - w);
    UIBezierPath *inner = [UIBezierPath bezierPathWithRoundedRect:innerRect
                                               byRoundingCorners:UIRectCornerTopLeft | UIRectCornerTopRight
                                                     cornerRadii:CGSizeMake(innerRadius, innerRadius)];
    [path appendPath:inner];
    return path;
}

@interface KGGlassLayer ()
@property (nonatomic, strong) CALayer *backdropLayer;
@property (nonatomic, strong) CALayer *veilLayer;
@property (nonatomic, strong) CALayer *refractLayer;
@property (nonatomic, strong) CAGradientLayer *rimLayer;
@property (nonatomic, strong) CAShapeLayer *refractMask;
@property (nonatomic, strong) CAShapeLayer *rimMask;
@property (nonatomic, assign) BOOL backdropAvailable;
@end

// 真正的布局逻辑。单独拆出来, 由 layoutSublayers 包着 @try 调用 ——
// 这样整个方法体都在异常保护之下, 不会漏掉某一行。
@interface KGGlassLayer ()
- (void)kg_layoutSublayersSafe;
@end

@implementation KGGlassLayer

- (instancetype)init {
    self = [super init];
    if (self) {
        self.masksToBounds = YES;
        self.backgroundColor = [UIColor clearColor].CGColor;
        self.opaque = NO;
        _backdropAvailable = (NSClassFromString(@"CABackdropLayer") != nil);
        [self setupSublayers];
    }
    return self;
}

- (void)setupSublayers {
    // CABackdropLayer 是私有类。alloc/init 也可能失败或抛异常, 全部兜住,
    // 任何一步失败都退回普通 CALayer —— 观感差一点, 但绝不崩。
    @try {
        // 本体: 真正做模糊的采样层
        Class backdropClass = NSClassFromString(@"CABackdropLayer");
        CALayer *backdrop = backdropClass ? (CALayer *)[[backdropClass alloc] init] : [CALayer layer];
        backdrop.masksToBounds = YES;
        self.backdropLayer = backdrop;
        [self addSublayer:backdrop];

        self.veilLayer = [CALayer layer];
        self.veilLayer.masksToBounds = YES;
        [self addSublayer:self.veilLayer];

        CALayer *refract = backdropClass ? (CALayer *)[[backdropClass alloc] init] : [CALayer layer];
        refract.masksToBounds = YES;
        self.refractLayer = refract;
        [self addSublayer:refract];
    } @catch (NSException *exception) {
        NSLog(@"[KeyboardGlass] setupSublayers 异常, 退回普通 CALayer: %@", exception);
        [self.sublayers enumerateObjectsUsingBlock:^(CALayer *layer, NSUInteger idx, BOOL *stop) {
            [layer removeFromSuperlayer];
        }];
        self.backdropLayer = [CALayer layer];
        self.veilLayer = [CALayer layer];
        self.refractLayer = [CALayer layer];
        [self addSublayer:self.backdropLayer];
        [self addSublayer:self.veilLayer];
        [self addSublayer:self.refractLayer];
    }

    self.rimLayer = [CAGradientLayer layer];
    self.rimLayer.type = kCAGradientLayerAxial;
    [self addSublayer:self.rimLayer];

    self.refractMask = [CAShapeLayer layer];
    self.refractMask.fillColor = [UIColor whiteColor].CGColor;
    self.refractMask.fillRule = kCAFillRuleEvenOdd;
    self.rimMask = [CAShapeLayer layer];
    self.rimMask.fillColor = [UIColor whiteColor].CGColor;
    self.rimMask.fillRule = kCAFillRuleEvenOdd;
}

- (void)applyStyle:(KGStyle)style dark:(BOOL)dark {
    self.kgStyle = style;
    self.darkMode = dark;
    [self setNeedsLayout];
}

// v0.4.2: 整个 layoutSublayers 包 @try。
// 这是本项目**最危险的位置**: 它由 CoreAnimation 在布局/渲染回调里调用,
// 期间抛出的异常不是"App 崩一下", 而是直接 abort 进程。v0.4.1 就是因为
// 同类的越界异常在这个调用链上, 导致键盘一起来就崩、反复重启进安全模式。
// 玻璃只是观感功能, 任何情况下都不值得拿系统稳定性去换。
- (void)layoutSublayers {
    [super layoutSublayers];
    @try {
        [self kg_layoutSublayersSafe];
    } @catch (NSException *exception) {
        NSLog(@"[KeyboardGlass] layoutSublayers 异常, 本帧不更新玻璃: %@", exception);
    }
}

- (void)kg_layoutSublayersSafe {
    CGRect bounds = self.bounds;
    if (CGRectIsEmpty(bounds)) return;

    BOOL dark = self.darkMode;
    KGStyle style = self.kgStyle;

    // ---- 1. 本体: 模糊下方内容 ----
    self.backdropLayer.frame = bounds;
    KGApplyBlur(self.backdropLayer, style.blur);
    self.backdropLayer.backgroundColor = [UIColor clearColor].CGColor;

    // ---- 2. 底色 (veil): 深色压黑, 浅色提白 ----
    self.veilLayer.frame = bounds;
    if (self.showOutline) {
        // 调试描边: 位置对不对只看这个, 跟材质参数无关。
        // 填充压得很淡 —— 描边开着时用户还得继续打字, 不能把键盘糊死。
        self.borderWidth = 2.5;
        self.borderColor = [UIColor colorWithRed:0.0 green:0.85 blue:1.0 alpha:1.0].CGColor;
        self.veilLayer.backgroundColor = [UIColor colorWithRed:1.0 green:0.0 blue:1.0 alpha:0.10].CGColor;
    } else {
        self.borderWidth = 0.0;
        UIColor *veilColor = dark ? [UIColor blackColor] : [UIColor whiteColor];
        CGFloat veilAlpha = style.veil * 0.65;
        self.veilLayer.backgroundColor = [veilColor colorWithAlphaComponent:veilAlpha].CGColor;
    }

    // ---- 3. 折射: 放大后的边缘环 ----
    CGFloat refraction = style.refraction;
    if (refraction > 0.5) {
        self.refractLayer.hidden = NO;
        self.refractLayer.frame = bounds;
        KGApplyBlur(self.refractLayer, style.blur * 1.6 + 2.0);

        CGFloat scale = 1.0 + refraction / 500.0;
        self.refractLayer.transform = CATransform3DMakeScale(scale, scale, 1.0);

        // mask 会跟着 transform 一起被放大, 所以要先把环宽除回去
        CGFloat ringWidth = refraction / scale;
        UIBezierPath *refractRing = KGMakeTopRingPath(bounds, style.cornerRadius, ringWidth);
        self.refractMask.path = refractRing.CGPath;
        self.refractLayer.mask = self.refractMask;
    } else {
        self.refractLayer.hidden = YES;
        self.refractLayer.mask = nil;
    }

    // ---- 4. 边缘高光: 一条上亮下暗的玻璃轮廓线 ----
    CGFloat highlight = style.highlight;
    self.rimLayer.frame = bounds;
    self.rimLayer.colors = @[
        (id)[[UIColor whiteColor] colorWithAlphaComponent:MIN(1.0, highlight)].CGColor,
        (id)[[UIColor whiteColor] colorWithAlphaComponent:highlight * 0.22].CGColor,
        (id)[[UIColor whiteColor] colorWithAlphaComponent:highlight * 0.55].CGColor,
    ];
    self.rimLayer.locations = @[@0.0, @0.45, @1.0];
    UIBezierPath *rimRing = KGMakeTopRingPath(bounds, style.cornerRadius, 2.0);
    self.rimMask.path = rimRing.CGPath;
    self.rimLayer.mask = self.rimMask;

    KGLog(@"layout glass bounds=%@ blur=%.1f refraction=%.1f highlight=%.2f veil=%.2f dark=%d backdrop=%d",
          NSStringFromCGRect(bounds), style.blur, style.refraction,
          style.highlight, style.veil, dark, self.backdropAvailable);
}

@end

#pragma clang diagnostic pop
