#import "KGGlassView.h"
#import <QuartzCore/QuartzCore.h>

// 模糊强度 -> UIBlurEffect 样式。
//
// 【为什么不用 CABackdropLayer】v0.4.x 用的是 CABackdropLayer + gaussianBlur。
// backdrop 层只采样**同一 layer 树里已经绘制**的内容, 而键盘在独立的 overlay
// 窗口里 —— 于是 backdrop 采到的样本是空的, 玻璃层等于全透明。实测日志里
// blur 被用户拖到 0, 更是连模糊都关了, 两头叠加就成了「纯透明」。
//
// 系统键盘自己用的就是 UIVisualEffectView(_UIVisualEffectBackdropView 内核),
// 它在键盘窗口里能模糊到下层 App 内容, 所以换成同一套机制。
//
// 【为什么最低档也保留雾感】blur=0 不再映射成「不模糊」, 而是映射到
// SystemThinMaterial —— 它仍然有明显的雾面磨砂。这是 v0.5.0 的关键修正:
// 旧版 blur=0 等于把玻璃整个关掉, 用户拖到 0 之后看到的就是「插件没生效」。
// 【关于最后一档的名字】UIKit 实际导出的是
// UIBlurEffectStyleSystemUltraThinMaterial{Light,Dark} —— **没有 UltraThick**。
// 编译器给的提示就是 "did you mean 'UIBlurEffectStyleSystemUltraThinMaterialLight'?"。
// 「超薄」这档模糊很弱, 只在用户把强度拉到 40 以上时才会用到, 但名字必须写对。
static UIBlurEffectStyle KGEffectStyleForBlur(CGFloat blur, BOOL dark) {
    if (blur <= 2.5) {
        return dark ? UIBlurEffectStyleSystemThinMaterialDark
                    : UIBlurEffectStyleSystemThinMaterialLight;
    }
    if (blur <= 7.0) {
        return dark ? UIBlurEffectStyleSystemMaterialDark
                    : UIBlurEffectStyleSystemMaterialLight;
    }
    if (blur <= 13.0) {
        return dark ? UIBlurEffectStyleSystemThickMaterialDark
                    : UIBlurEffectStyleSystemThickMaterialLight;
    }
    return dark ? UIBlurEffectStyleSystemUltraThinMaterialDark
                : UIBlurEffectStyleSystemUltraThinMaterialLight;
}

@interface KGGlassView ()
@property (nonatomic, strong) UIVisualEffectView *blurView;
// 底色。玻璃要「看得见」主要靠它, 模糊只是锦上添花。
@property (nonatomic, strong) CALayer *veilLayer;
// 顶部高光带: iOS 26 玻璃最有辨识度的特征就是上边缘被顶起的那道亮边。
@property (nonatomic, strong) CAGradientLayer *topGlowLayer;
// 边缘高光环。
@property (nonatomic, strong) CAGradientLayer *rimLayer;
@property (nonatomic, strong) CAShapeLayer *rimMask;
@end

@implementation KGGlassView

- (instancetype)initWithFrame:(CGRect)frame {
    self = [super initWithFrame:frame];
    if (self) [self kg_setup];
    return self;
}

- (instancetype)init {
    self = [super init];
    if (self) [self kg_setup];
    return self;
}

- (void)kg_setup {
    // 【触摸安全】本视图及其所有子视图一律关闭交互。
    // hitTest 遇到 userInteractionEnabled=NO 的视图必定跳过, 这是 UIKit 的
    // 明确契约, 不依赖任何推断。此前两次「打不了字」都是 z 序/藏层误判,
    // 这次把能显式关的全部显式关掉, 不留任何靠推理撑着的环节。
    self.userInteractionEnabled = NO;
    // 【CALayer -> UIView 的抄写陷阱】CALayer 上叫 masksToBounds, UIView 上叫
    // clipsToBounds。v0.5.0 从纯 CALayer 改写成 UIView 时, 这一行照抄了过来,
    // 编译直接报 "property 'masksToBounds' not found"。
    // 另外 backgroundColor 是 **UIColor** 属性, 赋 CGColorRef 需要桥接 ——
    // CALayer.backgroundColor 才收 CGColorRef。
    self.clipsToBounds = YES;
    self.backgroundColor = [UIColor clearColor];
    self.opaque = NO;
    self.contentMode = UIViewContentModeRedraw;

    _darkMode = NO;

    @try {
        // ---- 1. 模糊本体（玻璃的来源）----
        _blurView = [[UIVisualEffectView alloc] initWithEffect:
            [UIBlurEffect effectWithStyle:UIBlurEffectStyleSystemMaterialLight]];
        _blurView.userInteractionEnabled = NO;
        _blurView.autoresizingMask = UIViewAutoresizingFlexibleWidth | UIViewAutoresizingFlexibleHeight;
        [self addSubview:_blurView];

        // ---- 2. 底色 veil ----
        _veilLayer = [CALayer layer];
        _veilLayer.masksToBounds = YES;
        [self.layer addSublayer:_veilLayer];

        // ---- 3. 顶部高光带 ----
        // 高度随高光强度走, 固定在顶部, 往下淡出。用 axial(纵向)渐变。
        _topGlowLayer = [CAGradientLayer layer];
        _topGlowLayer.type = kCAGradientLayerAxial;
        _topGlowLayer.startPoint = CGPointMake(0.5, 0.0);
        _topGlowLayer.endPoint   = CGPointMake(0.5, 1.0);
        [self.layer addSublayer:_topGlowLayer];

        // ---- 4. 边缘高光环 ----
        _rimLayer = [CAGradientLayer layer];
        _rimLayer.type = kCAGradientLayerAxial;
        _rimLayer.startPoint = CGPointMake(0.5, 0.0);
        _rimLayer.endPoint   = CGPointMake(0.5, 1.0);
        [self.layer addSublayer:_rimLayer];

        _rimMask = [CAShapeLayer layer];
        _rimMask.fillColor = [UIColor whiteColor].CGColor;
        _rimMask.fillRule = kCAFillRuleEvenOdd;
        [self.layer addSublayer:_rimMask];
    } @catch (NSException *exception) {
        NSLog(@"[KeyboardGlass] kg_setup 异常, 退化为纯透明: %@", exception);
    }
}

- (void)applyStyle:(KGStyle)style dark:(BOOL)dark {
    _kgStyle = style;
    _darkMode = dark;
    [self setNeedsLayout];
}

- (CGSize)intrinsicContentSize {
    return CGSizeMake(UIViewNoIntrinsicMetric, UIViewNoIntrinsicMetric);
}

- (CGSize)sizeThatFits:(CGSize)size {
    return size;
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // v0.4.2 教训: 这里是 UIKit 布局回调, 抛异常直接 abort, 必须兜住。
    @try {
        [self kg_layoutSafe];
    } @catch (NSException *exception) {
        NSLog(@"[KeyboardGlass] layoutSubviews 异常, 本帧不更新玻璃: %@", exception);
    }
}

- (void)kg_layoutSafe {
    CGRect bounds = self.bounds;
    if (CGRectIsEmpty(bounds)) return;

    KGStyle style = self.kgStyle;
    BOOL dark = self.darkMode;

    // ---- 模糊本体 ----
    // effect 换档必须走 setNeedsLayout, 直接改会闪。
    UIBlurEffect *effect = [UIBlurEffect
        effectWithStyle:KGEffectStyleForBlur(style.blur, dark)];
    if (![self.blurView.effect isEqual:effect]) {
        self.blurView.effect = effect;
    }
    self.blurView.frame = bounds;

    // ---- 底色 veil ----
    // v0.5.0: 旧版是 style.veil * 0.65, 0.42 最多只有 0.273 的白, 几乎等于没有。
    // 「玻璃感」主要靠底色建立, 文字可读性也靠它保证, 不靠模糊。这里直接用原值。
    self.veilLayer.frame = bounds;
    if (self.showOutline) {
        // 调试描边: 品红很淡, 用户还得继续打字, 不能把键盘糊死。
        self.layer.borderWidth = 2.5;
        self.layer.borderColor = [UIColor colorWithRed:0.0 green:0.85 blue:1.0 alpha:1.0].CGColor;
        self.veilLayer.backgroundColor = [UIColor colorWithRed:1.0 green:0.0 blue:1.0 alpha:0.10].CGColor;
    } else {
        self.layer.borderWidth = 0.0;
        UIColor *veilColor = dark ? [UIColor blackColor] : [UIColor whiteColor];
        self.veilLayer.backgroundColor = [veilColor colorWithAlphaComponent:style.veil].CGColor;
    }

    // ---- 顶部高光带 ----
    // 旧版的「折射环」是一道很窄的白边, 在 0.42 的底色上几乎看不出来。
    // 这里改成有实际高度的一段渐变, 宽度同时吃折射值 —— 折射越大, 亮带越厚。
    CGFloat highlight = style.highlight;
    CGFloat refraction = style.refraction;
    CGFloat glowHeight = MIN(bounds.size.height * 0.5,
                             MAX(2.0, 1.0 + highlight * 6.0 + refraction * 0.55));
    self.topGlowLayer.frame = CGRectMake(0, 0, bounds.size.width, glowHeight);
    self.topGlowLayer.hidden = (highlight <= 0.01);
    if (!self.topGlowLayer.hidden) {
        CGFloat a = MIN(0.85, highlight);
        self.topGlowLayer.colors = @[
            (id)[[UIColor whiteColor] colorWithAlphaComponent:a].CGColor,
            (id)[[UIColor whiteColor] colorWithAlphaComponent:a * 0.45].CGColor,
            (id)[[UIColor whiteColor] colorWithAlphaComponent:0.0].CGColor,
        ];
        self.topGlowLayer.locations = @[@0.0, @0.35, @1.0];
    }

    // ---- 边缘高光环 ----
    self.rimMask.frame = bounds;
    self.rimLayer.frame = bounds;
    CGFloat rimAlpha = MIN(1.0, MAX(0.0, highlight * 0.85 + refraction * 0.012));
    self.rimLayer.hidden = (rimAlpha <= 0.01);
    if (!self.rimLayer.hidden) {
        self.rimLayer.colors = @[
            (id)[[UIColor whiteColor] colorWithAlphaComponent:rimAlpha].CGColor,
            (id)[[UIColor whiteColor] colorWithAlphaComponent:rimAlpha * 0.28].CGColor,
            (id)[[UIColor whiteColor] colorWithAlphaComponent:rimAlpha * 0.55].CGColor,
        ];
        self.rimLayer.locations = @[@0.0, @0.45, @1.0];
        self.rimMask.path = [self kg_topRingPathInBounds:bounds
                                                 radius:style.cornerRadius
                                             ringWidth:1.5].CGPath;
    }
}

// 顶部敞开的环形路径: 只保留上边与左右两侧, 底部往下多画 40pt 跑出可视区。
- (UIBezierPath *)kg_topRingPathInBounds:(CGRect)bounds radius:(CGFloat)radius ringWidth:(CGFloat)ringWidth {
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

@end
