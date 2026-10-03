#import "KGEngine.h"
#import "KGGlassView.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>

// ======================================================================
// 【v3.0.0 —— 推翻重做】
// ======================================================================
//
// 十三版(以及 v2.0.0)失败的根因, 由v1.1.0 探针的 253MB 原始数据一次性定位:
//
// 1) **v2.0.0「按键在输入法扩展进程」是错的。**
//    全量 157 棵全树里, 微信输入法(SquidExtender.*/ TUI*)的按键层
//    `UIKBKeyplaneView` / `UIKBKeyView` 就在**宿主进程**里, 层级完整。
//    我上一轮只看了 tail 截断片段就下了跨进程的结论, 这次全量统计纠正了。
//
// 2) **玻璃层插错了位置, 这是十三版"看不见"的直接原因。**
//    探针实测的树上有一行:
//        2KGGlassView  {0,0},{430,932} a=1.00 uie=0
//    —— 全屏 430x932, 挂在 UIInputSetContainerView 这一层。
//    键盘实际只占屏幕底部 356pt(UIInputSetHostView 是 {0,576},{430,356})。
//    玻璃层比键盘大5 倍, 且它的 z序在按键层**之上**, 于是它用一层
//    半透明白糊住了整个屏幕底部, 观感上就是「键盘更白了」而不是「更透了」。
//    用户看到的是"更浑浊", 不是"玻璃感"。
//
// 3) **真正该改的是系统自己的底板层。**
//    探针实测微信输入法态下有两块系统底板, 都是 uie=1 但**纯视觉**
//    (内部只装_ UIVisualEffectBackdropView, 自己不收触摸):
//        UIKBInputBackdropView 430x311 uie=0
//          UIKBBackdropView 430x311 uie=1  bg=1.00/1.00/1.00/0.10
//            _UIVisualEffectBackdropView 430x311 uie=0
//        UIKBInputBackdropView 430x45  uie=0
//          UIKBBackdropView 430x45  uie=1  bg=1.00/1.00/1.00/0.10
//            _UIVisualEffectBackdropView 430x45 uie=0
//    那个 **bg=白/0.10** 就是键盘"实心浅灰"的真正来源。
//    v0.7.x~v1.1.0 一直在调UIVisualEffectBackdropView 的 alpha, 调的是
//    效果图层而不是**底板本身的白**, 所以永远差一口。
//
// 【v3.0.0 的做法 —— 两条, 都只碰纯视觉层】
//A. 把 `UIKBBackdropView` 的白底 alpha 调低 (0.10 -> 用户设定值)。
//    这是"通透"的主要来源: 系统原本铺了一层10% 的白, 调低它等于
//    让下层 App 内容直接透上来。UIKBBackdropView 内部只有一层
//    _UIVisualEffectBackdropView, 不含按键/按钮, 机制上不参与触摸。
//    ——但它是 uie=1, 所以**只改 backgroundColor, 绝不加/删 subview**。
//    改颜色不改变 hitTest 链路, 这是 UIKit 的确定行为。
//
// B. 把玻璃层插到 `UIKBInputBackdropView` 里(与系统底板平级),
//    尺寸**严格等于该背板**, 不多不少。z序在系统底板之上、按键层之下。
//    这样玻璃只出现在键盘该在的位置, 不会糊到屏幕别处。
//
// 【v3.0.0 铁律 —— 继承 v0.7.2 的教训, 一条都不许破】
//  - 布局回调里**只观测不动手**。真正干活的是 0.4s 定时器。
//  - 且只在「宿主 frame 连续两次采样完全相同」时才动手。
//    理由: 在系统视图的 layoutSubviews 里改视图树 = 给自己造一个
//    可能不收敛的反馈环。v0.7.1 用户实测「打不了字」就是这么来的。
//  - 一次失败(崩溃)累计 5 次就永久熔断, 宁可什么都不做也不能进安全模式。
// ======================================================================

NSString * const KGProbeFilePath = @"/var/mobile/Documents/KeyboardGlass/tweak_probe.txt";

// ----------------------------------------------------------------------
// 探针: 体积封顶 256KB。v1.1.0 那份 253MB 是没封顶的后果,
// 每次全量 dump 都往同一个文件追加, 用户根本传不回来。
// ----------------------------------------------------------------------
void KGProbeWrite(NSString *content) {
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSFileManager *fm = NSFileManager.defaultManager;
    NSString *dir = [KGProbeFilePath stringByDeletingLastPathComponent];
    if (![fm fileExistsAtPath:KGProbeFilePath] && ![fm fileExistsAtPath:dir]) {
        if (![fm createDirectoryAtPath:dir
            withIntermediateDirectories:YES attributes:nil error:NULL]) {
            return;
        }
    }
    NSDictionary *attr = [fm attributesOfItemAtPath:KGProbeFilePath error:NULL];
    unsigned long long sz = [attr fileSize];
    if (sz > 256 * 1024) {
        // 超限就整份重写, 只留最新这一段。
        [data writeToFile:KGProbeFilePath atomically:YES];
    } else {
        NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:KGProbeFilePath];
        if (h) {
            [h seekToEndOfFile];
            [h writeData:data];
            [h closeFile];
        } else {
            [data writeToFile:KGProbeFilePath atomically:YES];
        }
    }
}

#pragma mark - 选层工具

static NSString *KGCls(UIView *v) {
    return v ? NSStringFromClass(v.class) : @"(nil)";
}

static BOOL KGClassIs(UIView *v, NSString *needle) {
    return v && [KGCls(v) rangeOfString:needle].location != NSNotFound;
}

// 宿主视图: UIInputSetHostView。
// 微信输入法态下实测它 frame = {{0,576},{430,356}}, 正好是键盘区。
static BOOL KGIsHost(UIView *v) {
    return v && v.superview && KGClassIs(v, @"InputSetHost");
}

// 在屏: 可见面积 >= 自身面积的 60%
static BOOL KGIsOnScreen(UIView *v) {
    if (!v || !v.window) return NO;
    CGRect inWindow = [v convertRect:v.bounds toView:v.window];
    CGRect vis = CGRectIntersection(inWindow, v.window.bounds);
    if (CGRectIsNull(vis) || CGRectIsEmpty(vis)) return NO;
    CGFloat full = v.bounds.size.width * v.bounds.size.height;
    if (full <= 0) return NO;
    return (vis.size.width * vis.size.height) >= full * 0.6;
}

// 键盘尺寸: 宽 >= 85% 屏宽, 面积 >= 屏宽 x 150
static BOOL KGIsKeyboardSized(UIView *v) {
    if (!v || !v.superview) return NO;
    CGFloat sw = v.window.bounds.size.width;
    if (sw <= 0) sw = UIScreen.mainScreen.bounds.size.width;
    if (sw <= 0) return NO;
    if (v.frame.size.width < sw * 0.85) return NO;
    return (v.frame.size.width * v.frame.size.height) >= sw * 150.0;
}

// ======================================================================
// 【uied 铁律】只碰 uie=1 也安全的唯一前提: **只改 backgroundColor**
// ======================================================================
// v1.0.0 立的铁律是「只碰 uie=0 的层」。v3.0.0 之所以要碰 uie=1 的
// UIKBBackdropView, 是因为**键盘那块 10% 的白就铺在它身上**, 不调它
// 就等于没调。
//
// 但这条只在**只改 backgroundColor** 的前提下成立:
//   - 改 backgroundColor 不改变 view 的 hitTest 参与性(UIKit 契约)
//   - 加/删 subview、改 frame、改 alpha 则会**改变**命中区域, 铁律就破了
// 所以 v3.0.0 里对 UIKBBackdropView 只写 backgroundColor 一个属性,
// 绝不碰它别的地方。探针里能核对这一点: uie 始终是 1, 从没变过。
static BOOL KGTouchSafeForColorOnly(UIView *v) {
    // 纯视觉底板: 类名匹配即可。内部只有一层效果视图, 没有按键/按钮。
    if (KGClassIs(v, @"UIKBBackdropView")) return YES;
    return NO;
}

// 面积够大且在屏, 避免误伤某个 45x45 的小按钮底板
static BOOL KGIsBigEnough(UIView *v, UIView *host) {
    CGFloat ha = host.frame.size.width * host.frame.size.height;
    if (ha <= 0) return NO;
    CGFloat a = v.frame.size.width * v.frame.size.height;
    return a >= ha * 0.10;
}

@interface KGEngine ()
@property (nonatomic, weak)   UIView *seenHostView;
@property (nonatomic, weak)   UIView *seenContainer;
@property (nonatomic, strong) NSTimer *timer;
@property (nonatomic, assign) BOOL running;

// 稳定闸: 连续两次采样 frame 完全相同才允许动手
@property (nonatomic, assign) CGRect lastFrame;
@property (nonatomic, assign) NSInteger sameCount;
@property (nonatomic, assign) BOOL hasLastFrame;

// 当前生效的目标层
@property (nonatomic, weak)   UIView *backdropView;   // UIKBBackdropView
// 【类型必须是 KGGlassView *】早先写成 UIView *, 于是 applyStyle: 里调
// self.glassView.showOutline / applyStyle:dark: 全是"no visible @interface",
// CI 两个架构同时报错。持有我们自己的类型, 编译器才能帮我们查错。
@property (nonatomic, strong) KGGlassView *glassView; // 我们插的玻璃
@property (nonatomic, assign) BOOL appliedStyle;
@property (nonatomic, assign) KGStyle appliedStyleValue;
@property (nonatomic, assign) NSString *lastSignature;

// 崩溃熔断
@property (nonatomic, assign) NSInteger crashCount;
@property (nonatomic, assign) BOOL    crashLoaded;

// 底板原始颜色。还原时要用, 必须在第一次改动**之前**抓住。
@property (nonatomic, strong) UIColor *savedBackdropColor;

// 探针节流: 状态没变就不重复写文件
@property (nonatomic, assign) NSInteger tickCount;
@end

@implementation KGEngine

+ (instancetype)shared {
    static KGEngine *inst = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ inst = [[KGEngine alloc] init]; });
    return inst;
}

// 【不要在 init 里读 NSUserDefaults】+shared 由 %ctor 触发, 那时
// KGPrefs registerDefaults 还没跑, 读到的全是 0。崩溃计数改成惰性加载。
- (NSInteger)crashCount {
    if (!self.crashLoaded) {
        self.crashLoaded = YES;
        NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:KGPrefsSuiteName];
        self.crashCount = [d integerForKey:@"CrashCount"];
    }
    return self.crashCount;
}

- (void)setCrashCount:(NSInteger)v {
    self.crashLoaded = YES;
    self.crashCount = v;
}

#pragma mark - 观测入口(布局回调里只做这一件事)

- (void)noteHostLayout:(UIView *)host {
    // 【铁律】这里一行都不许动视图树。v0.7.1 的"打不了字"就是在这里
    // 埋下的: 回调里改 frame -> 触发下一次 layout -> 再次回调, 乒乓不收敛。
    self.seenHostView = host;
}

- (void)noteContainerLayout:(UIView *)root {
    // 兜底: 记下容器, 用来在宿主消失时仍能找回键盘区。
    self.seenContainer = root;
}

#pragma mark - 定时器

- (void)startWorker {
    if (self.running) return;
    self.running = YES;
    self.timer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                 repeats:YES
                                                   block:^(NSTimer *t) {
        [[KGEngine shared] tick];
    }];
    KGLog(@"引擎已启动(3.0.0), 0.4s 定时器 + 连续两帧相同才动手");
}

- (void)stopWorker {
    self.running = NO;
    [self.timer invalidate];
    self.timer = nil;
}

#pragma mark - 熔断

- (BOOL)circuitOpen {
    // 【简化】只看次数, 不看时间窗。
    // 原设计想用「10 分钟内 5 次」来自动恢复, 但 CrashLastTime 存的是
    // NSDate 对象, 一旦用户换机/重装导致读不出来, 熔断就永远解不开 ——
    // 表现就是「插件明明装了却啥也不干」, 比崩一次更难排查。
    // 设置面板每次打开都会清零计数(KGRootListController 里无条件remove),
    // 所以「装新版→开设置→就恢复」这条路是通的, 不需要时间窗。
    return [self crashCount] >= 5;
}

- (void)noteCrash {
    self.crashCount = [self crashCount] + 1;
    NSUserDefaults *d = [[NSUserDefaults alloc] initWithSuiteName:KGPrefsSuiteName];
    [d setObject:@([self crashCount]) forKey:@"CrashCount"];
    KGLog(@"崩溃计数 = %ld(达到 5 就熔断)", (long)[self crashCount]);
}

#pragma mark - 主循环

- (void)tick {
    if (!self.running) return;
    if ([self circuitOpen]) return;
    if (!NSThread.isMainThread) return;

    // ---- 找宿主 ----
    UIView *host = self.seenHostView;
    if (!host || !host.window) {
        host = nil;
        for (UIView *v in [self candidateHostsIn:self.seenContainer]) {
            if (KGIsHost(v) && KGIsOnScreen(v) && KGIsKeyboardSized(v)) { host = v; break; }
        }
    }
    if (!host || !host.window) {
        [self teardownAll];
        self.hasLastFrame = NO;
        return;
    }
    if (!KGIsOnScreen(host) || !KGIsKeyboardSized(host)) {
        [self teardownAll];
        self.hasLastFrame = NO;
        return;
    }

    // ---- 稳定闸: 连续两次 frame 相同才动手 ----
    CGRect f = host.frame;
    if (!self.hasLastFrame) {
        self.lastFrame = f;
        self.hasLastFrame = YES;
        self.sameCount = 1;
        return;
    }
    if (!CGRectEqualToRect(f, self.lastFrame)) {
        self.lastFrame = f;
        self.sameCount = 1;
        return;   // 还在动, 下一拍再看
    }
    self.sameCount++;
    if (self.sameCount < 2) return;   // 需要连续两次相同(当前这次 + 上一拍)

    // ---- 材质关闭就彻底还原 ----
    if ([KGPrefs material] == KGMaterialOff) {
        [self teardownAll];
        return;
    }

    // ---- 找目标层: 系统底板 UIKBBackdropView ----
    UIView *backdrop = [self findBackdropIn:host];
    if (!backdrop) {
        // 找不到就什么都不做(不能糊玻璃, 十三版的教训)。
        [self removeGlass];
        self.backdropView = nil;
        self.tickCount++;
        if (self.tickCount % 25 == 1) {
            KGProbeWrite([NSString stringWithFormat:
                @"\n[v3.0.0 %@] 未找到 UIKBBackdropView, 本轮不动任何视图。宿主=%@ frame=%@\n",
                [NSDate date], KGCls(host), NSStringFromCGRect(f)]);
        }
        return;
    }

    // ---- 换宿主/换底板: 还原旧的, 重新入位 ----
    if (self.backdropView != backdrop || self.glassView.superview == nil) {
        [self restoreBackdrop];
        [self removeGlass];
        self.backdropView = backdrop;
        self.lastSignature = nil;
    }

    // ---- A. 调低系统底板的白(键盘"实心浅灰"的真凶) ----
    [self applyBackdropColor:backdrop];

    // ---- B. 玻璃层插到 UIKBInputBackdropView 里, 尺寸严格等于背板 ----
    [self placeGlassInBackdrop:backdrop host:host];

    // ---- 样式 ----
    [self applyStyle];

    // ---- 探针: 每 25 拍(约 10 秒)写一次状态 ----
    self.tickCount++;
    if (self.tickCount % 25 == 1) {
        [self writeProbe:host backdrop:backdrop];
    }
}

// 在容器子树里 BFS 找宿主
- (NSArray<UIView *> *)candidateHostsIn:(UIView *)root {
    if (!root) return @[];
    NSMutableArray<UIView *> *out = [NSMutableArray array];
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0;
    while (q.count > 0 && guard++ < 3000) {
        UIView *cur = q.firstObject;
        [q removeObjectAtIndex:0];
        for (UIView *sub in cur.subviews) {
            if (KGIsHost(sub)) [out addObject:sub];
            [q addObject:sub];
        }
    }
    return out;
}

// BFS 找系统底板 UIKBBackdropView。
// 判据: 类名匹配 + 面积 >= 宿主 10% + 在屏。
// 明确排除按键层: 按键层类名是 UIKBKeyplaneView / UIKBKeyView, 匹配不上。
- (UIView *)findBackdropIn:(UIView *)host {
    if (!host) return nil;
    UIView *best = nil;
    CGFloat bestArea = 0;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:host];
    NSUInteger guard = 0;
    while (q.count > 0 && guard++ < 4000) {
        UIView *cur = q.firstObject;
        [q removeObjectAtIndex:0];
        for (UIView *sub in cur.subviews) {
            if (KGTouchSafeForColorOnly(sub) && KGIsBigEnough(sub, host) && KGIsOnScreen(sub)) {
                CGFloat a = sub.frame.size.width * sub.frame.size.height;
                if (a > bestArea) { bestArea = a; best = sub; }
            }
            [q addObject:sub];
        }
    }
    return best;
}

#pragma mark - A. 系统底板调色

- (void)applyBackdropColor:(UIView *)backdrop {
    if (!backdrop) return;
    // 【原色只抓一次】这是还原能否正确的前提。
    // 早先的写法是「每拍都把当前色存成原色」, 结果第二次 tick 存进去的
    // 已经是「我们」自己改过的值 —— 还原时等于还原成目标值, 插件一关白色就
    // 永久留下。这正是十三版里「卸载插件后键盘还是花的」的来源。
    if (!self.savedBackdropColor) {
        self.savedBackdropColor = [backdrop.backgroundColor copy];
    }
    CGFloat target = [KGPrefs backdropWhiteness];
    UIColor *c = self.savedBackdropColor;
    CGFloat r = 1.0, g = 1.0, b = 1.0, a = 0.10;
    if (c && [c respondsToSelector:@selector(getRed:green:blue:alpha:)]) {
        [c getRed:&r green:&g blue:&b alpha:&a];
    }
    // 只改 alpha, 保持原来的色相(系统那块是白1,1,1)。
    UIColor *nc = [UIColor colorWithRed:r green:g blue:b alpha:target];
    CGFloat curA = -1.0;
    UIColor *cur = backdrop.backgroundColor;
    if (cur && [cur respondsToSelector:@selector(getRed:green:blue:alpha:)]) {
        [cur getRed:&r green:&g blue:&b alpha:&curA];
    }
    if (fabs(curA - target) > 0.004) {
        backdrop.backgroundColor = nc;
    }
}

#pragma mark - B. 玻璃层入位

- (void)placeGlassInBackdrop:(UIView *)backdrop host:(UIView *)host {
    if (!backdrop) return;
    // 玻璃要插在 backdrop 的**父层**(UIKBInputBackdropView), 与 backdrop 平级,
    // 这样玻璃盖住系统底板、但在按键层之下。
    UIView *parent = backdrop.superview;
    if (!parent) {
        [self removeGlass];
        return;
    }
    if (!self.glassView) {
        self.glassView = [[KGGlassView alloc] initWithFrame:backdrop.bounds];
        self.glassView.userInteractionEnabled = NO;   // 触摸安全第一道闸
    }
    // 尺寸**严格等于底板**, 不多不少。这是 v3.0.0 与十三版最大的区别。
    if (!CGRectEqualToRect(self.glassView.frame, backdrop.frame)) {
        self.glassView.frame = backdrop.frame;
    }
    if (self.glassView.superview != parent) {
        // 用 insertSubview:aboveSubview: 把玻璃插在系统底板正上方。
        // 若底板已是父层最后一个子视图, aboveSubview 也能正常工作。
        [parent insertSubview:self.glassView aboveSubview:backdrop];
        KGLog(@"玻璃入位: parent=%@ frame=%@",
              KGCls(parent), NSStringFromCGRect(self.glassView.frame));
    }
    self.glassView.hidden = NO;
}

#pragma mark - 样式

- (void)applyStyle {
    KGStyle st = [KGPrefs styleForCurrentMaterialDark:NO];
    if (!self.glassView) return;
    if (self.appliedStyle && KGStyleEqual(st, self.appliedStyleValue)) return;
    self.appliedStyleValue = st;
    self.appliedStyle = YES;
    self.glassView.showOutline = [KGPrefs showLayerOutline];
    [self.glassView applyStyle:st dark:NO];
}

#pragma mark - 还原/ 拆除

- (void)restoreBackdrop {
    if (self.backdropView && self.savedBackdropColor) {
        self.backdropView.backgroundColor = self.savedBackdropColor;
    }
    self.backdropView = nil;
    self.savedBackdropColor = nil;
}

- (void)removeGlass {
    if (self.glassView.superview) [self.glassView removeFromSuperview];
    self.appliedStyle = NO;
}

- (void)teardownAll {
    [self restoreBackdrop];
    [self removeGlass];
    self.hasLastFrame = NO;
    self.sameCount = 0;
}

#pragma mark - 探针

- (void)writeProbe:(UIView *)host backdrop:(UIView *)backdrop {
    NSString *s =
    [NSString stringWithFormat:
        @"\n[v3.0.0 %@] 宿主=%@ {%@} 底板=%@ {%@} bg=%@ 白度=%.2f 玻璃=%@ 父=%@\n",
        [NSDate date],
        KGCls(host), NSStringFromCGRect(host.frame),
        KGCls(backdrop), NSStringFromCGRect(backdrop.frame),
        [self colorDesc:backdrop.backgroundColor],
        [KGPrefs backdropWhiteness],
        self.glassView ? (self.glassView.superview ? @"已入位" : @"游离") : @"无",
        self.glassView ? KGCls(self.glassView.superview) : @"-"];
    KGProbeWrite(s);
}

- (NSString *)colorDesc:(UIColor *)c {
    if (!c) return @"nil";
    CGFloat r = 0, g = 0, b = 0, a = 0;
    if (![c respondsToSelector:@selector(getRed:green:blue:alpha:)]) return @"?";
    [c getRed:&r green:&g blue:&b alpha:&a];
    return [NSString stringWithFormat:@"%.2f/%.2f/%.2f/%.2f", r, g, b, a];
}

@end
