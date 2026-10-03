#import "KGKeyboardInstaller.h"
#import "KGGlassLayer.h"
#import "KGPrefs.h"
#import <sys/stat.h>

#pragma mark - 视图判定

// 键盘宿主视图 —— UIInputSetHostView。它的 frame 就是键盘矩形本身。
//
// KG_LAYOUT_LOOP_NOTE (第 7 版教训):
//   一个进程里有**多个** UIInputSetHostView, 而且会随键盘动画在 576/621/932
//   之间变换位置和高度。对每个宿主都响应的话, 玻璃层会被几十次/秒地搬来搬去,
//   每次 insert 都触发宿主重新布局, 布局又回调到我们的 hook —— 反馈死循环,
//   键盘整个卡死。所以: 锁定一个可用宿主 + 玻璃层只插一次。
//
// KG_LAYER_NOTE (第 9 版定论):
//   稳定态快照实锤了两件事 —— 系统按键视图 UIKBKeyView 自己就是
//   userInteractionEnabled=0, 且在键盘区域做 hitTest 全部返回 nil。
//   说明这个键盘窗口的触摸派发不走 App 这边的 hitTest。往键盘里加 UIView
//   是在赌系统触摸路由的实现细节, 用户实测「玻璃那一片点不动」。
//   所以本版起玻璃层改成 **纯 CALayer** 挂在宿主的 layer 上:
//   hitTest 只遍历 view, layer 天生不参与触摸命中, 从机制上不可能挡触摸。
static BOOL KGClassIsInputSetHost(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return name.length > 0 && [name containsString:@"InputSetHost"];
}

// 屏幕可见性。键盘收起/弹出动画途中宿主会被推到 y = 屏高 (完全出屏), 那种状态不能认。
static BOOL KGIsOnScreen(UIView *view) {
    if (!view || !view.window) return NO;
    CGRect inWindow = [view convertRect:view.bounds toView:view.window];
    CGRect visible = CGRectIntersection(inWindow, view.window.bounds);
    if (CGRectIsNull(visible) || CGRectIsEmpty(visible)) return NO;
    CGFloat full = view.bounds.size.width * view.bounds.size.height;
    if (full <= 0) return NO;
    return (visible.size.width * visible.size.height) >= full * 0.6;
}

// 键盘尺寸资格: 宽度接近整屏, 且按屏宽折算至少 150pt 高。
static BOOL KGIsKeyboardSized(UIView *view) {
    if (!view || !view.superview) return NO;
    CGFloat screenWidth = view.window.bounds.size.width;
    if (screenWidth <= 0) screenWidth = UIScreen.mainScreen.bounds.size.width;
    if (screenWidth <= 0) return NO;
    if (view.frame.size.width < screenWidth * 0.85) return NO;
    return (view.frame.size.width * view.frame.size.height) >= screenWidth * 150.0;
}

// 「可用宿主」= 类名对 + 尺寸对 + 还在屏幕里 + 还挂在树上
static BOOL KGIsUsableHost(UIView *view) {
    if (!view || !view.superview) return NO;
    return KGClassIsInputSetHost(view) && KGIsKeyboardSized(view) && KGIsOnScreen(view);
}

// 往下找「这棵子树里有没有键盘按键内容」。
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

// 「按键前景」判定。玻璃层必须待在它下面。
static BOOL KGLooksLikeKeyboardForeground(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if (name.length == 0) return NO;
    if ([name containsString:@"Backdrop"]) return NO;
    if ([name containsString:@"Keyboard"]) return YES;
    if ([name containsString:@"Keyplane"]) return YES;
    return KGContainsKeyboardContent(view, 0);
}

// KG_BACKDROP_SCAN_NOTE (v0.4.0 真正的病根):
//   v0.2.x~0.3.x 的 backgroundInHost: 只扫宿主的**直接孩子**, 于是只命中了
//   那个 45pt 的助手条背景 UIKBInputBackdropView。真正的主体背景是嵌在
//   UIView{{0,45},{430,243}} 容器子树里的 UIKBInputBackdropView → UIKBBackdropView,
//   它压根不是直接孩子, 于是从来没被隐藏过。后果完全对得上用户反馈
//   「顶部透明了, 主体没变化」: 顶部那块被藏了, 主体那块 (白 0.10) 还压在
//   玻璃层下面, 玻璃层采到的就是它自己 —— 白上加白, 等于什么都没发生。
//
// KG_TOUCH_LESSON (v0.4.1 血泪, 优先级高于上面那条):
//   v0.4.0 把「藏背景」从 1 层扩到「所有整宽的 Backdrop 层」, 结果用户立刻
//   反馈「又不能点击了」。原因: alpha=0 会让整棵子树退出 hitTest ——
//   「子树里没有按键内容」只能保证按键本身还在, **不能保证这层不参与
//   触摸派发**。iOS 键盘的触摸走自己的窗口路由, 藏掉哪一层会哑, 光靠静态
//   判据推不出来, 只能实测。
//   所以铁律改成: **一次只藏一层, 而且必须是可以一键回滚的单层。**
//   「主体没变化」的观感问题, 靠调整这一层的插入 z 序来解决(让玻璃层压住
//   它), 而不是靠把更多层一起藏掉。
//
// 判据保留面积门槛 (排除按键内部自带的小 backdrop) + 无按键内容 (防止按键
// 自己消失), 但**不再批量隐藏**。
static BOOL KGIsSafeToHide(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    if (![name containsString:@"Backdrop"]) return NO;
    // 肚子里有按键内容的一律不能碰: alpha<=0.01 的视图会被 hitTest 跳过,
    // 藏错对象会把整块键盘连触摸一起弄没 (v0.2.0 实锤过)。
    if (KGContainsKeyboardContent(view, 0)) return NO;
    // 背景板都是整屏宽的。这条同时排掉了某些按键内部自带的小 backdrop。
    CGFloat screenWidth = view.window ? view.window.bounds.size.width
                                      : UIScreen.mainScreen.bounds.size.width;
    if (screenWidth <= 0) return NO;
    if (view.frame.size.width < screenWidth * 0.8) return NO;
    return YES;
}

static BOOL KGStyleEqual(KGStyle a, KGStyle b) {
    return a.blur == b.blur
        && a.refraction == b.refraction
        && a.highlight == b.highlight
        && a.veil == b.veil
        && a.cornerRadius == b.cornerRadius
        && a.dark == b.dark;
}

// 各档位「做哪几件事」的开关。把判断收在这里, 而不是散在主流程里 ——
// v0.4.1 加 Glass 档时, 因为散着写漏改了枚举, 差点又把「藏背景」带上。
// v0.4.1 起两个动作**完全解耦**, 就能单独验证「玻璃层本身是否挡触摸」。
static BOOL KGModeShowsGlass(KGWorkMode mode) {
    return mode == KGWorkModeGlass || mode == KGWorkModeFull;
}

static BOOL KGModeHidesBackdrop(KGWorkMode mode) {
    return mode == KGWorkModeHide || mode == KGWorkModeFull;
}

#pragma mark - 探针

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

// 带外观信息的树 dump。光看类名和 frame 分不出「哪一层是可见的键盘背景」。
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

static void KGDumpHostChildren(UIView *host, NSString *tag) {
    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"---- [%@] %@ 宿主视图 class=%@ frame=%@ onScreen=%d sublayers=%lu\n",
        [NSDate date], tag, NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        KGIsOnScreen(host), (unsigned long)host.layer.sublayers.count];
    NSArray<UIView *> *subs = host.subviews;
    for (NSUInteger i = 0; i < subs.count; i++) {
        UIView *sub = subs[i];
        [out appendFormat:@"  #%lu %@ frame=%@ fg=%d a=%.2f h=%d layerIdx=%ld\n",
            (unsigned long)i, NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
            KGLooksLikeKeyboardForeground(sub), sub.alpha, sub.hidden,
            (long)[host.layer.sublayers indexOfObject:sub.layer]];
    }
    [out appendString:@"----\n"];
    KGWriteProbe(out);
}

#pragma mark -

@interface KGKeyboardInstaller ()
@property (nonatomic, strong) KGGlassLayer *glassLayer;
@property (nonatomic, weak)   UIView *hostView;          // 锁定的宿主
// 键 = 被隐藏的原生背景层 (弱引用, 键盘重建时自动失效)
// 值 = 它的原始 alpha (恢复用)
// v0.4.0 起是「一组」而不是「一个」—— 见 KG_BACKDROP_SCAN_NOTE。
@property (nonatomic, strong) NSMapTable<UIView *, NSNumber *> *hiddenBackdrops;
// v0.4.1: 锁定的**唯一**一层背景 (批量隐藏会让键盘哑掉, 见 KG_TOUCH_LESSON)
@property (nonatomic, weak)   UIView *cachedBackdrop;
@property (nonatomic, assign) BOOL hasAppliedStyle;
@property (nonatomic, assign) KGStyle appliedStyle;
@property (nonatomic, assign) BOOL didDumpStableTree;
@property (nonatomic, assign) BOOL didRunTouchDiag;
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

- (void)handleHostView:(UIView *)host {
    if (!KGClassIsInputSetHost(host)) return;
    // 锁定宿主: 其它宿主一律不理, 否则玻璃层会被来回搬, 触发布局死循环
    if (self.hostView && self.hostView != host && KGIsUsableHost(self.hostView)) return;
    [self refreshWithHost:host];
}

// root 传 UIInputWindowController.view (UIInputSetContainerView)
- (void)handleLayout:(UIView *)root {
    if (!root) return;

    [KGPrefs debugLog];

    if (KGIsUsableHost(self.hostView)) {
        [self refreshWithHost:self.hostView];
        return;
    }

    UIView *host = [self findInputSetHostIn:root];
    if (host) {
        [self refreshWithHost:host];
        return;
    }

    // 兜底: 宿主类名不认识时, 按背板类名找最大那块
    [self legacyRefreshWithRoot:root];
}

#pragma mark - 主流程

- (void)refreshWithHost:(UIView *)host {
    [KGPrefs debugLog];

    KGWorkMode mode = [KGPrefs workMode];
    KGMaterial material = [KGPrefs material];

    if (mode != KGWorkModeProbe && material == KGMaterialOff) {
        [self teardown];
        return;
    }

    // 键盘收起 / 移出屏幕: 只是藏起来, 千万不能因此换宿主
    if (!KGIsKeyboardSized(host) || !KGIsOnScreen(host)) {
        if (self.glassLayer.superlayer) self.glassLayer.hidden = YES;
        return;
    }

    if (self.hostView != host) {
        KGLog(@"锁定宿主 %@ frame=%@ mode=%ld", NSStringFromClass(host.class),
              NSStringFromCGRect(host.frame), (long)mode);
        self.hostView = host;
        [self.glassLayer removeFromSuperlayer];
        [self restoreNativeBackdrops];
        self.glassLayer.hidden = YES;

        KGDumpHostChildren(host, mode == KGWorkModeProbe ? @"锁定宿主(纯探针)" : @"锁定宿主");
        [self scheduleStableTreeDump:host];
    }

    // 从「插玻璃层」切到更低的档时, 必须把已经插进去的玻璃层撤掉
    if (!KGModeShowsGlass(mode) && self.glassLayer.superlayer) {
        KGLog(@"工作模式降到 %ld, 撤掉已插入的玻璃层", (long)mode);
        [self.glassLayer removeFromSuperlayer];
    }
    // 从「藏背景」切到更低档时, 必须恢复原生背景
    if (!KGModeHidesBackdrop(mode)) {
        [self restoreNativeBackdrops];
    }

    if (KGModeShowsGlass(mode)) {
        [self placeGlassInHost:host];
        self.glassLayer.hidden = NO;
        [self applyStyleForMaterial:material];
    }

    if (KGModeHidesBackdrop(mode)) {
        [self enforceNativeBackdropStateInHost:host];
    }

    [self writeInstallProbeWithHost:host material:material mode:mode];
}

// 键盘稳定下来之后: 一次触摸诊断 + 一次带外观信息的全树 dump
- (void)scheduleStableTreeDump:(UIView *)host {
    if (self.didDumpStableTree) return;
    self.didDumpStableTree = YES;

    __weak UIView *weakHost = host;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        UIView *strongHost = weakHost;
        if (!strongHost || !strongHost.superview) return;

        [self logTouchDiagnosticOnHost:strongHost];

        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"==== [%@] 稳定态全树 (从宿主父视图起) ====\n", [NSDate date]];
        NSInteger budget = 400;
        KGDumpTreeDetail(strongHost.superview, 0, out, &budget);
        [out appendFormat:@"==== [%@] 稳定态 宿主直接孩子 ====\n", [NSDate date]];
        NSArray<UIView *> *subs = strongHost.subviews;
        for (NSUInteger i = 0; i < subs.count; i++) {
            UIView *sub = subs[i];
            [out appendFormat:@"  #%lu %@ frame=%@ fg=%d a=%.2f h=%d layerIdx=%ld\n",
                (unsigned long)i, NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
                KGLooksLikeKeyboardForeground(sub), sub.alpha, sub.hidden,
                (long)[strongHost.layer.sublayers indexOfObject:sub.layer]];
        }
        [out appendString:@"====\n"];
        KGWriteProbe(out);
    });
}

// 一次性触摸诊断: 在键盘上取 3 个点做 hitTest。
// 注意这只是**诊断**, 不做任何动作 —— v0.2.2 曾拿它当「键盘被挡」的判据并把
// 玻璃层撤走, 结果发现 App 这边对键盘窗口做 hitTest 本来就全是 nil (键盘窗口
// 的触摸不走 App 的 hitTest 派发), 那个判据是假的。
- (void)logTouchDiagnosticOnHost:(UIView *)host {
    if (self.didRunTouchDiag) return;
    self.didRunTouchDiag = YES;
    if (!host || !host.window) return;

    UIWindow *window = host.window;
    NSArray<NSValue *> *samples = @[
        [NSValue valueWithCGPoint:CGPointMake(CGRectGetMidX(host.bounds), CGRectGetMidY(host.bounds))],
        [NSValue valueWithCGPoint:CGPointMake(host.bounds.size.width * 0.15, CGRectGetMidY(host.bounds))],
        [NSValue valueWithCGPoint:CGPointMake(host.bounds.size.width * 0.85, host.bounds.size.height * 0.35)],
    ];

    NSMutableString *detail = [NSMutableString string];
    for (NSValue *v in samples) {
        CGPoint pt = [host convertPoint:v.CGPointValue toView:window];
        UIView *hit = [window hitTest:pt withEvent:nil];
        [detail appendFormat:@" (%@->%@)", NSStringFromCGPoint(pt),
            hit ? NSStringFromClass(hit.class) : @"nil"];
    }
    KGWriteProbe([NSString stringWithFormat:
        @"[touch-diag %@] window=%@ winUserEnabled=%d glassIsLayer=%d 命中:%@\n",
        [NSDate date], NSStringFromClass(window.class), window.userInteractionEnabled,
        (self.glassLayer != nil), detail]);
}

#pragma mark - 探测

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

// 宿主直接孩子里, **最靠下的那个真正含按键内容**的视图。
//
// 为什么不能用「名字带 Keyboard 的」当按键层 (v0.4.0 修正):
//   UIKeyboardDockView 类名里带 Keyboard, 但它 alpha=0, 是个空壳占位层,
//   按名字判定会把它当成按键区, 于是玻璃层插到它下面 —— 而真正的主体背景
//   容器 (UIView{{0,45},...}) 恰好在它上面, 玻璃层又被压回背景之下。
//   判据换成「子树里确实有 Keyplane / KeyView / KeyboardLayout」, 这是按键
//   的定义, 不受类名命名干扰。
//
// 玻璃层插到这一层之下 = 所有背景之上、所有按键之下。
- (UIView *)firstKeyLayerInHost:(UIView *)host {
    NSArray<UIView *> *subs = host.subviews;
    for (NSUInteger i = 0; i < subs.count; i++) {
        UIView *sub = subs[i];
        if (KGContainsKeyboardContent(sub, 0)) return sub;
    }
    return nil;
}

// 找出宿主里**唯一一层**可以隐藏的原生背景。
//
// v0.4.1 关键改动: 从「收集全部」改成「只挑一层」。
// v0.4.0 批量隐藏导致键盘哑掉 —— alpha=0 会让整棵子树退出 hitTest,
// 「子树里无按键内容」只能保证按键还在, 保证不了这层不参与触摸派发。
// 一次只动一层, 哑了也只有一层可回滚, 不会再出现「不知道是哪层害的」。
//
// 挑选规则: 递归 BFS 找到**面积最大**的那一层 (主体背景永远比 45pt 助手条大),
// 这样正好解决 v0.4.0 之前的「只藏到助手条、主体没变化」问题 ——
// 主体背景藏了, 玻璃层下方才第一次真正透出 App 内容。
- (UIView *)backdropInHost:(UIView *)host {
    if (!host) return nil;

    UIView *best = nil;
    CGFloat bestArea = 0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:host];
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 4000) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!current) continue;

        if (current != host && KGIsSafeToHide(current)) {
            CGFloat area = current.frame.size.width * current.frame.size.height;
            if (area > bestArea) {
                bestArea = area;
                best = current;
            }
            // 命中即止: 不再往这层子树里钻。藏外层自然连带藏内层,
            // 避免父子都被记进状态里搞乱恢复逻辑。
            continue;
        }
        [queue addObjectsFromArray:current.subviews];
    }
    return best;
}

#pragma mark - 安装与拆卸

// 把玻璃层挂到宿主的 layer 上 (不是 subview!)。
// hitTest 只遍历 view, 所以挂在 layer 上的玻璃层**永远不可能**挡住触摸。
- (void)placeGlassInHost:(UIView *)host {
    if (!self.glassLayer) {
        self.glassLayer = [[KGGlassLayer alloc] init];
        self.hasAppliedStyle = NO;
    }

    if (!CGRectEqualToRect(self.glassLayer.frame, host.bounds)) {
        self.glassLayer.frame = host.bounds;
    }

    CALayer *hostLayer = host.layer;

    if (self.glassLayer.superlayer != hostLayer) {
        // 首次进场: 插到「第一个按键层」的下面 —— 即所有背景之上、所有按键之下
        UIView *fg = [self firstKeyLayerInHost:host];
        NSInteger target = 0;
        if (fg) {
            NSInteger li = [hostLayer.sublayers indexOfObject:fg.layer];
            if (li != NSNotFound) target = li;
        }
        [hostLayer insertSublayer:self.glassLayer atIndex:(NSUInteger)MAX(0, target)];
        KGLog(@"玻璃层入位: host=%@ sublayers=%lu 目标位置=%ld (前景=%@)",
              NSStringFromClass(host.class), (unsigned long)hostLayer.sublayers.count,
              (long)target, fg ? NSStringFromClass(fg.class) : @"none");
        return;
    }

    // 已在宿主里: 平时绝不动它 (避免触发布局), 只在压到按键上面时纠正一次
    UIView *fg = [self firstKeyLayerInHost:host];
    if (!fg) return;
    NSInteger gi = [hostLayer.sublayers indexOfObject:self.glassLayer];
    NSInteger fi = [hostLayer.sublayers indexOfObject:fg.layer];
    // gi 必然有效 (superlayer 就是 hostLayer), 保险起见还是判一下
    if (gi != NSNotFound && fi != NSNotFound && gi > fi) {
        KGLog(@"玻璃层被压到按键上面 (layer idx %ld > %ld), 纠正一次", (long)gi, (long)fi);
        [hostLayer insertSublayer:self.glassLayer atIndex:(NSUInteger)fi];
    }
}

// 隐藏 / 恢复原生背景层。
//
// v0.4.1: 目标恒为**一层**。扫描一次就锁定, 之后只重新应用 alpha。
// 不在每次布局时重扫 —— 重扫有可能选中另一层 (键盘动画中子树结构会变),
// 「藏 A 层 → 触发重排 → 选中 B 层 → 藏 B 层 → …」这种链会把键盘搞死。
//
// 性能: backdropInHost: 是全子树 BFS (上限 4000 节点), 而 layoutSubviews 在
// 键盘动画期间每秒能走几十次, 绝对不能每次都跑。
- (void)enforceNativeBackdropStateInHost:(UIView *)host {
    if (!self.hiddenBackdrops) {
        self.hiddenBackdrops = [NSMapTable weakToStrongObjectsMapTable];
    }

    // 锁定的层离树了才重选 —— 键盘重建时会换一批视图
    if (!self.cachedBackdrop || !self.cachedBackdrop.superview) {
        self.cachedBackdrop = [self backdropInHost:host];
        if (self.cachedBackdrop) {
            [self.hiddenBackdrops setObject:@(self.cachedBackdrop.alpha)
                                     forKey:self.cachedBackdrop];
            KGLog(@"锁定背景层 %@ frame=%@",
                  NSStringFromClass(self.cachedBackdrop.class),
                  NSStringFromCGRect(self.cachedBackdrop.frame));
        } else {
            KGLog(@"没找到可隐藏的背景层");
        }
    }

    UIView *bg = self.cachedBackdrop;
    if (!bg || !bg.superview) return;
    NSNumber *origin = [self.hiddenBackdrops objectForKey:bg];
    if (!origin) return;

    CGFloat target = [KGPrefs hideNativeBackdrop] ? 0.0 : origin.doubleValue;
    // 只在真的需要改时才写。alpha 赋值会触发重排, 无脑写等于自激。
    if (fabs(bg.alpha - target) > 0.001) {
        bg.alpha = target;
    }
}

- (void)applyStyleForMaterial:(KGMaterial)material {
    if (!self.glassLayer) return;
    BOOL dark = (self.hostView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    KGStyle style = [KGPrefs styleForMaterial:material dark:dark];
    BOOL outline = [KGPrefs showLayerOutline];
    if (self.hasAppliedStyle && KGStyleEqual(style, self.appliedStyle)
        && self.glassLayer.showOutline == outline) {
        return;
    }
    self.appliedStyle = style;
    self.hasAppliedStyle = YES;
    self.glassLayer.showOutline = outline;
    [self.glassLayer applyStyle:style dark:dark];
}

- (void)writeInstallProbeWithHost:(UIView *)host material:(KGMaterial)material mode:(KGWorkMode)mode {
    UIView *fg = KGModeShowsGlass(mode) ? [self firstKeyLayerInHost:host] : nil;
    NSInteger gi = self.glassLayer ? [host.layer.sublayers indexOfObject:self.glassLayer] : NSNotFound;
    NSInteger fi = fg ? [host.layer.sublayers indexOfObject:fg.layer] : NSNotFound;
    // 被锁定的那一层背景 (v0.4.1 起恒为单层)
    UIView *bg = self.cachedBackdrop;
    NSNumber *bgOrigin = bg ? [self.hiddenBackdrops objectForKey:bg] : nil;
    NSString *bgDesc = bg
        ? [NSString stringWithFormat:@"%@(%@,origin=%.2f,now=%.2f)",
           NSStringFromClass(bg.class), NSStringFromCGRect(bg.frame),
           bgOrigin ? bgOrigin.doubleValue : -1.0, bg.alpha]
        : @"none";

    // 玻璃层正下方那三层是谁 —— 玻璃是 backdrop 层, 采样源就在它下面。
    // 如果这三层里有东西仍然不透明, 玻璃就采不到键盘外面的画面。
    NSMutableString *underDesc = [NSMutableString string];
    NSArray<CALayer *> *subs = host.layer.sublayers;
    if (gi > 0) {
        for (NSInteger i = gi - 1; i >= 0 && i >= gi - 3; i--) {
            CALayer *l = subs[(NSUInteger)i];
            [underDesc appendFormat:@"[%ld]%@ hidden=%d opacity=%.2f ",
                (long)i, NSStringFromClass(l.class), l.hidden ? 1 : 0, l.opacity];
        }
    }
    if (underDesc.length == 0) [underDesc appendString:@"none"];

    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%ld|%ld|%ld",
        NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        bg ? NSStringFromClass(bg.class) : @"none", (long)gi, (long)fi, (long)mode];
    if ([signature isEqualToString:self.lastProbeSignature]) return;
    self.lastProbeSignature = signature;
    if (self.probeCount++ > 60) return;

    KGWriteProbe([NSString stringWithFormat:
        @"[install %@] mode=%ld host=%@ hostFrame=%@ onScreen=%d glassLayerIdx=%ld/%lu fg=%@(layer %ld) hideNative=%d material=%ld blur=%.1f refraction=%.1f highlight=%.2f veil=%.2f radius=%.1f outline=%d\n"
        @"         hiddenBg=%@\n"
        @"         underGlass=%@\n",
        [NSDate date], (long)mode,
        NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        KGIsOnScreen(host),
        (long)gi, (unsigned long)host.layer.sublayers.count,
        fg ? NSStringFromClass(fg.class) : @"none", (long)fi,
        [KGPrefs hideNativeBackdrop], (long)material,
        self.appliedStyle.blur, self.appliedStyle.refraction,
        self.appliedStyle.highlight, self.appliedStyle.veil,
        self.appliedStyle.cornerRadius, [KGPrefs showLayerOutline],
        bgDesc, underDesc]);
}

- (void)restoreNativeBackdrops {
    if (!self.hiddenBackdrops) return;
    // NSMapTable 弱键: 键盘视图被系统释放后 key 会自动变 nil。必须先判空再用
    // objectForKey: —— 给 nil 当 key 查会抛异常。
    for (UIView *bg in [[self.hiddenBackdrops keyEnumerator] allObjects]) {
        if (!bg) continue;
        NSNumber *origin = [self.hiddenBackdrops objectForKey:bg];
        if (origin) bg.alpha = origin.doubleValue;
    }
    [self.hiddenBackdrops removeAllObjects];
    self.cachedBackdrop = nil;
}

- (void)teardown {
    if (self.glassLayer) {
        [self.glassLayer removeFromSuperlayer];
        self.glassLayer = nil;
        self.hasAppliedStyle = NO;
    }
    [self restoreNativeBackdrops];
    self.hostView = nil;
}

#pragma mark - 兜底路径 (宿主类名不认识时)

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

        if (current != nil) {
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
    if (!KGModeShowsGlass([KGPrefs workMode])) return;   // 只有「插玻璃层」的档位才动视图
    if (self.glassLayer.superlayer != nil) return;       // 已经装好了, 别乱动

    UIView *found = [self findBackdropByNameIn:root];
    if (!found) return;
    if (!KGIsKeyboardSized(found) || !KGIsOnScreen(found)) return;

    UIView *host = found.superview;
    if (!host) return;

    KGLog(@"兜底路径命中背板 %@", NSStringFromClass(found.class));
    if (!self.glassLayer) {
        self.glassLayer = [[KGGlassLayer alloc] init];
        self.hasAppliedStyle = NO;
    }
    self.glassLayer.frame = found.frame;

    UIView *fg = [self firstKeyLayerInHost:host];
    NSInteger target = 0;
    if (fg && fg != found) {
        NSInteger li = [host.layer.sublayers indexOfObject:fg.layer];
        if (li != NSNotFound) target = li;
    }
    [host.layer insertSublayer:self.glassLayer atIndex:(NSUInteger)MAX(0, target)];
    self.glassLayer.hidden = NO;

    self.hostView = host;
    [self enforceNativeBackdropStateInHost:host];

    [self applyStyleForMaterial:[KGPrefs material]];
}

@end
