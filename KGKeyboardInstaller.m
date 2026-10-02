#import "KGKeyboardInstaller.h"
#import "KGGlassView.h"
#import "KGPrefs.h"
#import <sys/stat.h>

#pragma mark - 视图判定

// 键盘宿主视图 —— UIInputSetHostView。
// 它的 frame 就是键盘矩形本身。第 6 版开始用它当锚点, 原因见 KG_ANCHOR_NOTE。
//
// KG_ANCHOR_NOTE:
//   第 5 版之前是按类名 (InputBackdrop / KeyboardBackdrop / UIKBBackdropView)
//   在全树里找面积最大的背板。用户探针显示唯一命中的是 44x44 的
//   TUICandidateBackdropView (TextInputUI 的候选栏背板) —— 真正那块键盘背景
//   压根不在候选表里。依赖私有类名太脆, 改为依赖层级结构。
//
// KG_LAYOUT_LOOP_NOTE (第 7 版教训, 血亏):
//   一个进程里会同时存在**多个** UIInputSetHostView, 而且它们会随键盘动画
//   在 576 / 621 / 932 之间变换位置和高度。第 6 版对每个宿主都响应, 玻璃层
//   被几十次/秒地在宿主之间搬来搬去 —— 每次搬动都触发宿主重新布局, 于是
//   形成布局反馈死循环, 键盘整个卡死, 用户表现为「打不了字」。
//   所以本版两条铁律:
//     1) 锁定一个「可用宿主」后, 除非它不可用, 否则绝不换
//     2) 玻璃层已经在目标宿主里就绝不 insert (只在被压到按键上面时才纠正)
static BOOL KGClassIsInputSetHost(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return name.length > 0 && [name containsString:@"InputSetHost"];
}

// 屏幕可见性。键盘收起/弹出动画途中宿主会被推到 y = 屏高 (完全出屏),
// 那种状态不能认 —— 认了玻璃层就跟着飞到屏幕外面去了。
static BOOL KGIsOnScreen(UIView *view) {
    if (!view || !view.window) return NO;
    CGRect inWindow = [view convertRect:view.bounds toView:view.window];
    CGRect visible = CGRectIntersection(inWindow, view.window.bounds);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return NO;
    CGFloat full = view.bounds.size.width * view.bounds.size.height;
    if (full <= 0) return NO;
    return (visible.size.width * visible.size.height) >= full * 0.6;
}

// 键盘尺寸资格: 宽度接近整屏 (iPhone 上键盘一定占满横向), 且按屏宽折算
// 至少 150pt 高。两条一起挡掉候选栏 / 工具条 / 收起态那种小块。
static BOOL KGIsKeyboardSized(UIView *view) {
    if (!view || !view.superview) return NO;
    CGFloat screenWidth = view.window.bounds.size.width;
    if (screenWidth <= 0) screenWidth = UIScreen.mainScreen.bounds.size.width;
    if (screenWidth <= 0) return NO;
    if (view.frame.size.width < screenWidth * 0.85) return NO;
    return (view.frame.size.width * view.frame.size.height) >= screenWidth * 150.0;
}

// 「可用宿主」= 类名对 + 尺寸对 + 还在屏幕里 + 还挂在树上。
// 只有这一个判定通过, 才允许接管 / 保持接管。
static BOOL KGIsUsableHost(UIView *view) {
    if (!view || !view.superview) return NO;
    return KGClassIsInputSetHost(view) && KGIsKeyboardSized(view) && KGIsOnScreen(view);
}

// 往下找「这棵子树里有没有键盘按键内容」。iOS 16 的按键可能住在
// UIKBKeyplaneView, 也可能是 UIKeyboardLayoutCanvas / UIKBKeyView 那一套,
// 而且外面还可能再包一层不带任何关键字的 UIView —— 所以必须递归进子树看。
static BOOL KGContainsKeyboardContent(UIView *view, NSUInteger depth) {
    if (!view || depth > 4) return NO;
    for (UIView *sub in view.subviews) {
        NSString *name = NSStringFromClass(sub.class);
        if ([name containsString:@"Keyplane"]) return YES;
        if ([name containsString:@"KeyView"]) return YES;
        if ([name containsString:@"KeyboardLayout"]) return YES;
        if (KGContainsKeyboardContent(sub, depth + 1)) return YES;
    }
    return NO;
}

// 「按键前景」判定。玻璃层绝不能插到它上面 —— 那会把整个键盘盖住, 按键点不着。
static BOOL KGLooksLikeKeyboardForeground(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if (name.length == 0) return NO;
    if ([name containsString:@"Backdrop"]) return NO;   // 名字带 Backdrop 的一定是背景
    if ([name containsString:@"Keyboard"]) return YES;
    if ([name containsString:@"Keyplane"]) return YES;
    return KGContainsKeyboardContent(view, 0);
}

// 这个视图能不能安全地被隐藏 (hideNativeBackdrop)。
// 名字带 Backdrop 才算背景, 但还要看它肚子里有没有按键内容 ——
// 有些版本的 UIKBInputBackdropView 是个容器, 按键也在里面。
// 把它 alpha 归零, 按键跟着 alpha=0, 系统连触摸都不再派发
// (hitTest 会跳过 alpha<=0.01 的视图) —— 整块键盘直接打不了字。
static BOOL KGIsSafeToHide(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if (![name containsString:@"Backdrop"]) return NO;
    return !KGContainsKeyboardContent(view, 0);
}

static BOOL KGStyleEqual(KGStyle a, KGStyle b) {
    return a.blur == b.blur
        && a.refraction == b.refraction
        && a.highlight == b.highlight
        && a.veil == b.veil
        && a.cornerRadius == b.cornerRadius
        && a.dark == b.dark;
}

#pragma mark - 探针

// 探针双写: 越狱公共目录 (系统键盘进程可写) + 当前进程沙盒 Documents
// (输入法扩展的沙盒可能拦住公共目录, 沙盒内这份 Filza 也能翻到)。
static void KGWriteProbe(NSString *content) {
    mkdir("/var/mobile/Documents/KeyboardGlass", 0755);
    NSString *sandboxPath = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/kg_tweak_probe.txt"];
    NSArray<NSString *> *paths = @[
        @"/var/mobile/Documents/KeyboardGlass/tweak_probe.txt",
        sandboxPath,
    ];
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    for (NSString *path in paths) {
        NSFileHandle *handle = [NSFileHandle fileHandleForUpdatingAtPath:path];
        if (handle) {
            [handle seekToEndOfFile];
            [handle writeData:data];
            [handle closeFile];
            continue;
        }
        [data writeToFile:path atomically:YES];
    }
}

// 带外观信息的树 dump。第 7 版加的 —— 光看类名和 frame 分不出「哪一层是可见的
// 键盘背景」, 必须把 alpha / hidden / backgroundColor 一起打出来。
static void KGDumpTreeDetail(UIView *view, NSUInteger depth, NSMutableString *out, NSInteger *budget) {
    if (!view || *budget <= 0 || depth > 14) return;
    (*budget)--;
    for (NSUInteger i = 0; i < depth; i++) [out appendString:@"  "];

    UIColor *bg = view.backgroundColor;
    NSString *bgDesc = @"-";
    if (bg) {
        CGFloat r = 0, g = 0, b = 0, a = 0;
        if ([bg getRed:&r green:&g blue:&b alpha:&a]) {
            bgDesc = [NSString stringWithFormat:@"%.2f/%.2f/%.2f/%.2f", r, g, b, a];
        }
    }
    [out appendFormat:@"%@ | %@ a=%.2f h=%d uie=%d bg=%@\n",
        NSStringFromClass(view.class), NSStringFromCGRect(view.frame),
        view.alpha, view.hidden, view.userInteractionEnabled, bgDesc];

    for (UIView *sub in view.subviews) {
        KGDumpTreeDetail(sub, depth + 1, out, budget);
    }
}

// 只 dump 宿主视图的直接孩子 —— 谁是谁、在第几层, 一眼就能看出来。
static void KGDumpHostChildren(UIView *host, NSString *tag) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"---- [%@] %@ 宿主视图 class=%@ frame=%@ onScreen=%d\n",
        [NSDate date], tag, NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        KGIsOnScreen(host)];
    NSArray<UIView *> *subs = host.subviews;
    for (NSUInteger i = 0; i < subs.count; i++) {
        UIView *sub = subs[i];
        [out appendFormat:@"  #%lu %@ frame=%@ fg=%d a=%.2f h=%d\n",
            (unsigned long)i, NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
            KGLooksLikeKeyboardForeground(sub), sub.alpha, sub.hidden];
    }
    [out appendString:@"----\n"];
    KGWriteProbe(out);
}

#pragma mark -

@interface KGKeyboardInstaller ()
@property (nonatomic, strong) KGGlassView *glassView;
@property (nonatomic, weak)   UIView *hostView;          // 锁定的宿主 (UIInputSetHostView)
@property (nonatomic, weak)   UIView *nativeBackdrop;    // 宿主里的原生背景层 (只用于隐藏)
@property (nonatomic, assign) CGFloat nativeBackdropAlpha;
@property (nonatomic, assign) BOOL hasNativeBackdrop;
@property (nonatomic, assign) KGStyle appliedStyle;
@property (nonatomic, assign) BOOL hasAppliedStyle;
@property (nonatomic, assign) BOOL didDumpStableTree;
@property (nonatomic, assign) BOOL didDumpExtensionTree;
@property (nonatomic, assign) BOOL didRunSafetyCheck;
@property (nonatomic, assign) BOOL usingContainerFallback;
@property (nonatomic, weak)   UIView *fallbackReferent;   // 兜底模式下用来对齐 frame 的宿主
@property (nonatomic, copy)   NSString *lastProbeSignature;
@property (nonatomic, assign) NSUInteger probeCount;
@end

@implementation KGKeyboardInstaller

+ (instancetype)shared {
    static KGKeyboardInstaller *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[KGKeyboardInstaller alloc] init];
    });
    return shared;
}

#pragma mark - 对外入口

// 最理想的入口: 直接从 UIInputSetHostView 的 layoutSubviews 进来。
- (void)handleHostView:(UIView *)host {
    if (!KGClassIsInputSetHost(host)) return;

    // 已经退到容器兜底模式: 不再往宿主里塞任何东西
    if (self.usingContainerFallback) return;

    // 铁律 1: 已经锁定了可用宿主, 别的宿主一律不理。
    // 一个进程里有多个宿主, 谁最后布局就把玻璃抢过去 —— 这正是键盘卡死的成因。
    if (self.hostView && self.hostView != host && KGIsUsableHost(self.hostView)) return;

    [self refreshWithHost:host];
}

// root 传 UIInputWindowController.view (UIInputSetContainerView)
- (void)handleLayout:(UIView *)root {
    if (!root) return;

    [KGPrefs debugLog];

    if (self.usingContainerFallback) {
        [self syncContainerFallback];
        return;
    }

    // 锁定的宿主还好用就继续用它
    if (KGIsUsableHost(self.hostView)) {
        [self refreshWithHost:self.hostView];
        return;
    }

    UIView *host = [self findInputSetHostIn:root];
    if (host) {
        [self refreshWithHost:host];
        return;
    }

    // 万一某些 iOS 版本里宿主视图不叫 InputSetHost*: 退回老路子 ——
    // 按背板类名在全树里找面积最大的那块, 装到它父视图上。宁可两条路都留着,
    // 也不要出现「换了锚点反而彻底找不到」这种退化。
    [self legacyRefreshWithRoot:root];
}

// 容器兜底模式: 玻璃层挂在宿主父视图的最底层, 只跟着宿主的 frame 走。
// 这个位置永远不会盖住按键, 所以不做任何 z 序操作。
- (void)syncContainerFallback {
    UIView *referent = self.fallbackReferent;
    if (!referent || !referent.superview || !self.glassView) return;
    if (self.glassView.superview != referent.superview) {
        [referent.superview insertSubview:self.glassView atIndex:0];
    }
    if (!CGRectEqualToRect(self.glassView.frame, referent.frame)) {
        self.glassView.frame = referent.frame;
    }
    self.glassView.hidden = !(KGIsKeyboardSized(referent) && KGIsOnScreen(referent));
}

// 第三方输入法扩展: 目前只做记录, 结构拿到之后再对准 hook
- (void)handleExtensionLayout:(UIView *)root {
    if (!root) return;
    [KGPrefs debugLog];

    UIView *host = [self findInputSetHostIn:root];
    if (host) {
        [self refreshWithHost:host];
        return;
    }

    // 扩展的视图树只 dump 一次, 别每次布局都刷
    if (self.didDumpExtensionTree) return;
    self.didDumpExtensionTree = YES;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"==== [%@] 输入法扩展视图树 ====\n", [NSDate date]];
    NSInteger budget = 300;
    KGDumpTreeDetail(root, 0, out, &budget);
    [out appendString:@"====\n"];
    KGWriteProbe(out);
}

#pragma mark - 主流程

- (void)refreshWithHost:(UIView *)host {
    [KGPrefs debugLog];

    KGMaterial material = [KGPrefs material];
    if (material == KGMaterialOff) {
        [self teardown];
        return;
    }

    // 键盘收起 / 移出屏幕: 只是藏起来, 千万不能因此换宿主
    if (!KGIsKeyboardSized(host) || !KGIsOnScreen(host)) {
        if (self.glassView.superview == host) self.glassView.hidden = YES;
        return;
    }

    if (self.hostView != host) {
        KGLog(@"锁定宿主 %@ frame=%@", NSStringFromClass(host.class), NSStringFromCGRect(host.frame));
        self.hostView = host;
        [self.glassView removeFromSuperview];   // 只有换宿主时才搬一次
        [self restoreNativeBackdrop];
        self.glassView.hidden = YES;

        KGDumpHostChildren(host, @"锁定宿主");
        [self scheduleStableTreeDump:host];
    }

    [self placeGlassInHost:host];
    self.glassView.hidden = NO;

    UIView *bg = self.nativeBackdrop;
    [self enforceNativeBackdropState];
    [self applyStyleForMaterial:material];
    [self writeInstallProbeWithHost:host background:bg material:material];
}

// 键盘完全稳定下来之后再做一次带外观信息的全树 dump。
// 之前那些 dump 全是在动画中间抓的 (子视图尺寸都是 0), 看不出结构。
- (void)scheduleStableTreeDump:(UIView *)host {
    if (self.didDumpStableTree) return;
    self.didDumpStableTree = YES;

    __weak UIView *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *strongHost = weakHost;
        if (!strongHost || !strongHost.superview) return;

        // 先做安全体检: 键盘还点得动吗?
        [self runSafetyCheckOnHost:strongHost];

        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"==== [%@] 稳定态全树 (从宿主父视图起) ====\n", [NSDate date]];
        NSInteger budget = 400;
        KGDumpTreeDetail(strongHost.superview, 0, out, &budget);
        [out appendFormat:@"==== [%@] 稳定态 宿主直接孩子 ====\n", [NSDate date]];
        NSArray<UIView *> *subs = strongHost.subviews;
        for (NSUInteger i = 0; i < subs.count; i++) {
            UIView *sub = subs[i];
            [out appendFormat:@"  #%lu %@ frame=%@ fg=%d a=%.2f h=%d\n",
                (unsigned long)i, NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
                KGLooksLikeKeyboardForeground(sub), sub.alpha, sub.hidden];
        }
        [out appendString:@"====\n"];
        KGWriteProbe(out);
    });
}

// 安全体检 —— 本版最重要的一道保险。
// 在键盘上取三个点做真实 hitTest: 如果三个点**全都**命中不到东西、
// 或者全都命中我们自己的玻璃层, 就说明键盘已经被挡住、点不动了。
// 这时立刻把玻璃层撤出宿主, 改挂到宿主父视图的最底层 (容器层, 绝不影响键盘),
// 并且写进探针。宁可没效果, 也绝不能弄坏用户的键盘。
- (void)runSafetyCheckOnHost:(UIView *)host {
    if (self.didRunSafetyCheck) return;
    self.didRunSafetyCheck = YES;
    if (!host || !host.window || self.usingContainerFallback) return;
    if (self.glassView.superview != host) return;

    UIWindow *window = host.window;
    NSArray<NSValue *> *samples = @[
        [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds))],
        [NSValue valueWithCGPoint:CGPointMake(host.bounds.size.width * 0.15, CGRectGetMidY(host.bounds))],
        [NSValue valueWithCGPoint:CGPointMake(host.bounds.size.width * 0.85, host.bounds.size.height * 0.35)],
    ];

    NSUInteger blocked = 0;
    NSMutableString *detail = [NSMutableString string];
    for (NSValue *v in samples) {
        CGPoint pt = [host convertPoint:v.CGPointValue toView:window];
        UIView *hit = [window hitTest:pt withEvent:nil];
        [detail appendFormat:@" (%@->%@)", NSStringFromCGPoint(pt),
            hit ? NSStringFromClass(hit.class) : @"nil"];
        if (!hit || hit == self.glassView || [hit isDescendantOfView:self.glassView]) blocked++;
    }

    if (blocked < samples.count) {
        KGLog(@"安全体检通过 (3 点命中正常)");
        return;
    }

    // 三点全部被挡 -> 键盘已经点不动了, 马上撤
    UIView *container = host.superview;
    KGWriteProbe([NSString stringWithFormat:
        @"[SAFETY %@] 键盘被挡住, 玻璃层撤出宿主。命中情况:%@\n", [NSDate date], detail]);
    [self.glassView removeFromSuperview];

    if (container) {
        // 改挂容器最底层: 在宿主之下, 永远不可能盖住按键
        self.glassView.frame = host.frame;   // 与 host 同父视图, 坐标系一致
        [container insertSubview:self.glassView atIndex:0];
        self.usingContainerFallback = YES;
        self.fallbackReferent = host;
        self.hostView = nil;                 // 不再把宿主当归属, 免得又被搬回去
        KGWriteProbe([NSString stringWithFormat:
            @"[SAFETY %@] 已改挂到容器层 %@ index 0, glassFrame=%@\n",
            [NSDate date], NSStringFromClass(container.class),
            NSStringFromCGRect(self.glassView.frame)]);
    } else {
        self.glassView = nil;
        self.hasAppliedStyle = NO;
        KGWriteProbe([NSString stringWithFormat:@"[SAFETY %@] 容器不可用, 已彻底停用玻璃层\n", [NSDate date]]);
    }
}

#pragma mark - 探测

// 广度优先, 取面积最大的「可用」宿主
- (UIView *)findInputSetHostIn:(UIView *)root {
    UIView *best = nil;
    CGFloat bestArea = 0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 4000) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if (KGIsUsableHost(current)) {
            CGRect f = current.frame;
            CGFloat area = f.size.width * f.size.height;
            if (area > bestArea) {
                bestArea = area;
                best = current;
            }
        }
        [queue addObjectsFromArray:current.subviews];
    }
    return best;
}

// 在宿主的直接孩子里认「原生键盘背景层」。
// 注意: 这**只**用于决定要不要隐藏它, 不再决定玻璃层插哪儿 (插哪儿只看按键前景)。
- (UIView *)backgroundInHost:(UIView *)host {
    CGRect hb = host.bounds;
    CGFloat hostArea = hb.size.width * hb.size.height;
    if (hostArea <= 0) return nil;

    // 名字带 Backdrop 的最大者 —— 这个最可信
    UIView *byName = nil;
    CGFloat best = 0;
    for (UIView *sub in host.subviews) {
        if (sub == self.glassView) continue;
        NSString *name = NSStringFromClass(sub.class);
        if (![name containsString:@"Backdrop"]) continue;
        CGFloat area = sub.frame.size.width * sub.frame.size.height;
        if (area > best) { best = area; byName = sub; }
    }
    return byName;
}

#pragma mark - 安装与拆卸

// 宿主的直接孩子里, 最靠上的那个「按键前景」。
// 玻璃层必须待在它下面 —— 待在它上面会盖住整块键盘。
- (UIView *)topmostForegroundInHost:(UIView *)host {
    NSArray<UIView *> *subs = host.subviews;
    for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; i--) {
        UIView *sub = subs[i];
        if (sub == self.glassView) continue;
        if (KGLooksLikeKeyboardForeground(sub)) return sub;
    }
    return nil;
}

- (void)placeGlassInHost:(UIView *)host {
    if (!self.glassView) {
        self.glassView = [[KGGlassView alloc] initWithFrame:host.bounds];
        self.hasAppliedStyle = NO;
    }
    // 保险丝: 这一层是纯装饰, 任何情况下都不许拦触摸
    self.glassView.userInteractionEnabled = NO;
    self.glassView.multipleTouchEnabled = NO;
    self.glassView.exclusiveTouch = NO;

    if (!CGRectEqualToRect(self.glassView.frame, host.bounds)) {
        self.glassView.frame = host.bounds;
    }

    if (self.glassView.superview != host) {
        // 首次进场: 插到按键前景的下面; 找不到前景就插最底层 (index 0)
        UIView *fg = [self topmostForegroundInHost:host];
        NSInteger target = fg ? [host.subviews indexOfObject:fg] : 0;
        [host insertSubview:self.glassView atIndex:(NSUInteger)MAX(0, target)];
        self.nativeBackdrop = [self backgroundInHost:host];
        self.nativeBackdropAlpha = self.nativeBackdrop ? self.nativeBackdrop.alpha : 1.0;
        self.hasNativeBackdrop = (self.nativeBackdrop != nil);
        return;
    }

    // 铁律 2: 已经在宿主里了, 平时绝不动它 —— 每次 insert 都会触发宿主重新布局,
    // 而布局又会回调到这里, 形成死循环把键盘卡死。
    // 只有一种情况必须纠正: 玻璃层被压到了按键前景的上面。
    UIView *fg = [self topmostForegroundInHost:host];
    if (!fg) return;
    NSInteger gi = [host.subviews indexOfObject:self.glassView];
    NSInteger fi = [host.subviews indexOfObject:fg];
    if (gi != NSNotFound && fi != NSNotFound && gi > fi) {
        KGLog(@"玻璃层被压到按键上面 (idx %ld > %ld), 纠正一次", (long)gi, (long)fi);
        [host insertSubview:self.glassView atIndex:(NSUInteger)fi];
    }
}

// 系统在键盘布局过程中可能会重设背景层外观, 每次布局都把我们要的状态补一遍 (幂等)
- (void)enforceNativeBackdropState {
    UIView *backdrop = self.nativeBackdrop;
    if (!backdrop || !self.hasNativeBackdrop) return;
    if (backdrop.superview == nil) return;
    // 只有名字明确写着 Backdrop、且子树里没有按键内容的才敢藏。别的视图一律不动 ——
    // 万一那其实是装着按键的容器, 藏掉它整块键盘就没了, 触摸也随之失效。
    if (!KGIsSafeToHide(backdrop)) return;
    backdrop.alpha = [KGPrefs hideNativeBackdrop] ? 0.0 : self.nativeBackdropAlpha;
}

- (void)applyStyleForMaterial:(KGMaterial)material {
    BOOL dark = (self.glassView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    KGStyle style = [KGPrefs styleForMaterial:material dark:dark];
    BOOL outline = [KGPrefs showLayerOutline];
    if (self.hasAppliedStyle && KGStyleEqual(style, self.appliedStyle)
        && self.glassView.showOutline == outline) {
        return;
    }
    self.appliedStyle = style;
    self.hasAppliedStyle = YES;
    self.glassView.showOutline = outline;
    [self.glassView applyStyle:style];
}

- (void)writeInstallProbeWithHost:(UIView *)host background:(UIView *)bg material:(KGMaterial)material {
    // 按「宿主 + 尺寸 + 背景 + 我们的 index」去重, 并限制条数。
    // 上一版每次布局都写, 探针文件被刷到 0.7MB / 3000+ 行, 全是动画中间态噪音。
    UIView *fg = [self topmostForegroundInHost:host];
    NSInteger idx = [host.subviews indexOfObject:self.glassView];
    NSInteger fgIdx = fg ? [host.subviews indexOfObject:fg] : NSNotFound;

    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%ld|%ld",
        NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        bg ? NSStringFromClass(bg.class) : @"none", (long)idx, (long)fgIdx];
    if ([signature isEqualToString:self.lastProbeSignature]) return;
    self.lastProbeSignature = signature;
    if (self.probeCount++ > 60) return;   // 上限, 防止探针再次失控

    KGWriteProbe([NSString stringWithFormat:
        @"[install %@] host=%@ hostFrame=%@ onScreen=%d bg=%@ fg=%@(idx %ld) glassIdx=%ld/%lu glassFrame=%@ hideNative=%d material=%ld blur=%.1f refraction=%.1f highlight=%.2f veil=%.2f radius=%.1f outline=%d\n",
        [NSDate date],
        NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        KGIsOnScreen(host),
        bg ? NSStringFromClass(bg.class) : @"none",
        fg ? NSStringFromClass(fg.class) : @"none", (long)fgIdx,
        (long)idx, (unsigned long)host.subviews.count,
        NSStringFromCGRect(self.glassView.frame),
        [KGPrefs hideNativeBackdrop], (long)material,
        self.appliedStyle.blur, self.appliedStyle.refraction,
        self.appliedStyle.highlight, self.appliedStyle.veil,
        self.appliedStyle.cornerRadius, [KGPrefs showLayerOutline]]);
}

- (void)restoreNativeBackdrop {
    UIView *backdrop = self.nativeBackdrop;
    if (backdrop && self.hasNativeBackdrop) {
        backdrop.alpha = self.nativeBackdropAlpha;
    }
    self.nativeBackdrop = nil;
    self.hasNativeBackdrop = NO;
}

- (void)teardown {
    if (self.glassView) {
        [self.glassView removeFromSuperview];
        self.glassView = nil;
        self.hasAppliedStyle = NO;
    }
    [self restoreNativeBackdrop];
    self.hostView = nil;
}

#pragma mark - 兜底路径 (宿主类名不认识时)

// 类名候选 (兜底路径用)。不同 iOS 版本用的私有类不同, 全部收进来 ——
// 命中哪个用哪个。
static NSArray<NSString *> *KGBackdropClassHints(void) {
    static NSArray *hints = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hints = @[ @"InputBackdrop", @"KeyboardBackdrop", @"UIKBBackdropView" ];
    });
    return hints;
}

- (UIView *)findBackdropByNameIn:(UIView *)root {
    UIView *best = nil;
    CGFloat bestArea = 0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 4000) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if (current != self.glassView) {
            NSString *name = NSStringFromClass(current.class);
            for (NSString *hint in KGBackdropClassHints()) {
                if (![name containsString:hint]) continue;
                CGRect f = current.frame;
                CGFloat area = f.size.width * f.size.height;
                if (area > bestArea) {
                    bestArea = area;
                    best = current;
                }
                break;
            }
        }
        [queue addObjectsFromArray:current.subviews];
    }
    return best;
}

- (void)legacyRefreshWithRoot:(UIView *)root {
    if (self.glassView.superview != nil) return;   // 已经装好了, 别乱动

    UIView *found = [self findBackdropByNameIn:root];
    if (!found) {
        KGLog(@"兜底也未找到背板 (root=%@)", NSStringFromClass(root.class));
        return;
    }
    if (!KGIsKeyboardSized(found) || !KGIsOnScreen(found)) return;

    UIView *host = found.superview;
    if (!host) return;

    KGLog(@"兜底路径命中背板 %@", NSStringFromClass(found.class));
    if (!self.glassView) {
        self.glassView = [[KGGlassView alloc] initWithFrame:found.frame];
        self.hasAppliedStyle = NO;
    }
    self.glassView.userInteractionEnabled = NO;
    self.glassView.frame = found.frame;

    UIView *fg = [self topmostForegroundInHost:host];
    NSInteger target = 0;
    if (fg && fg != found) target = [host.subviews indexOfObject:fg];
    [host insertSubview:self.glassView atIndex:(NSUInteger)MAX(0, target)];
    self.glassView.hidden = NO;

    self.hostView = host;
    self.nativeBackdrop = found;
    self.nativeBackdropAlpha = found.alpha;
    self.hasNativeBackdrop = YES;

    [self enforceNativeBackdropState];
    [self applyStyleForMaterial:[KGPrefs material]];
}

@end
