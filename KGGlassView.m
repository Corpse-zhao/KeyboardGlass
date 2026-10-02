#import "KGGlassView.h"
#import <QuartzCore/QuartzCore.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Warc-performSelector-leaks"

// 给任意 CALayer 挂高斯模糊。CAFilter 是私有类, 取不到就静默跳过 (降级为纯染色+高光)。
static void KGApplyBlur(CALayer *layer, CGFloat radius) {
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

@interface KGGlassView ()
@property (nonatomic, strong) CALayer *veilLayer;
@property (nonatomic, strong) CALayer *refractLayer;
@property (nonatomic, strong) CAGradientLayer *rimLayer;
@property (nonatomic, strong) CAShapeLayer *refractMask;
@property (nonatomic, strong) CAShapeLayer *rimMask;
@property (nonatomic, assign) BOOL backdropAvailable;
@end

@implementation KGGlassView

+ (Class)layerClass {
    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    return backdropClass ?: [CALayer class];
}

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) {
        // 绝不拦截键盘触摸 —— 这一层是纯装饰
        self.userInteractionEnabled = NO;
        self.backgroundColor = [UIColor clearColor];
        self.opaque = NO;
        self.clipsToBounds = YES;
        self.layer.masksToBounds = YES;
        _backdropAvailable = (NSClassFromString(@"CABackdropLayer") != nil);
        [self setupSublayers];
    }
    return self;
}

- (void)setupSublayers {
    self.veilLayer = [CALayer layer];
    self.veilLayer.masksToBounds = YES;
    [self.layer addSublayer:self.veilLayer];

    Class backdropClass = NSClassFromString(@"CABackdropLayer");
    CALayer *refract = backdropClass ? (CALayer *)[[backdropClass alloc] init] : [CALayer layer];
    refract.masksToBounds = YES;
    self.refractLayer = refract;
    [self.layer addSublayer:self.refractLayer];

    self.rimLayer = [CAGradientLayer layer];
    self.rimLayer.type = kCAGradientLayerAxial;
    [self.layer addSublayer:self.rimLayer];

    self.refractMask = [CAShapeLayer layer];
    self.refractMask.fillColor = [UIColor whiteColor].CGColor;
    self.refractMask.fillRule = kCAFillRuleEvenOdd;
    self.rimMask = [CAShapeLayer layer];
    self.rimMask.fillColor = [UIColor whiteColor].CGColor;
    self.rimMask.fillRule = kCAFillRuleEvenOdd;
}

- (void)applyStyle:(KGStyle)style {
    self.style = style;
    [self setNeedsLayout];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    // 深色/浅色切换会改变 veil 的方向与高光观感, 重新布局
    [self setNeedsLayout];
}

- (void)layoutSubviews {
    [super layoutSubviews];

    CGRect bounds = self.bounds;
    if (CGRectIsEmpty(bounds)) return;

    BOOL dark = (self.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    KGStyle style = self.style;

    // ---- 1. 本体: 模糊下方内容 ----
    KGApplyBlur(self.layer, style.blur);
    self.layer.backgroundColor = [UIColor clearColor].CGColor;

    // ---- 2. 底色 (veil): 深色压黑, 浅色提白 ----
    self.veilLayer.frame = bounds;
    UIColor *veilColor = dark ? [UIColor blackColor] : [UIColor whiteColor];
    CGFloat veilAlpha = style.veil * 0.65;
    self.veilLayer.backgroundColor = [veilColor colorWithAlphaComponent:veilAlpha].CGColor;

    // ---- 3. 折射: 放大后的边缘环 ----
    CGFloat refraction = style.refraction;
    if (refraction > 0.5) {
        self.refractLayer.hidden = NO;
        self.refractLayer.frame = bounds;

        // 边缘采样用更大的模糊半径, 让折射带里的内容更「润」
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
