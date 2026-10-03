#import "KGEngine.h"
#import "KGGlassView.h"
#import <QuartzCore/QuartzCore.h>
#import <math.h>
// 崩溃陷阱要用的一组 POSIX 头。signal/open/read/write/mkdir 都出自这里。
// 单独列出来是为了让「信号处理器只用这批函数」这件事在 include 层面就一目了然。
#import <signal.h>
#import <fcntl.h>
#import <unistd.h>
#import <sys/stat.h>
#import <stdlib.h>

// ======================================================================
// 【v3.0.1 —— 撤回 v3.0.0 唯一一处越界动作, 并给熔断器接上信号处理器】
// ======================================================================
//
// v3.0.0 交付后用户反馈: 疑似系统异常(自己描述「注销」), 已卸载。
// **具体现象用户也说不清。** 于是这次不靠猜, 而是把 v3.0.0 里
// 唯一一处「没有证据支撑就破铁律」的动作撤掉。
//
// 【撤掉的是什么】
// v3.0.0 做两件事:
//   A. 写`UIKBBackdropView`(系统底板, **uie=1**)的 backgroundColor
//   B. 把玻璃层插到 `UIKBInputBackdropView` 里
// v3.0.1 只保留 B, 且把 B 的入位父层从「底板的父层」换成
// **`UIKBInputBackdropView` 本身**(uie=0), A 整个停用。
//
// 【为什么撤 A —— 理由不是「它一定有问题」, 而是「我没资格碰它」】
// v1.0.0 立的铁律: **只允许改 uie=0 的层。** 十三版有两次安全模式
// (v0.4.1 / v0.4.2)都来自「改系统视图」, 铁律就是这么来的。
// v3.0.0 给破例找的理由是「只改 backgroundColor 不改变 hitTest 参与性」——
// 而这条论证有个**从未验证的前提**: 假定这个属性无人竞争、只有我们在写。
// 只要系统在别处也写它(深浅色切换、材质切换、键盘形态切换都会重配底板),
// 就构成一个我看不见的反馈环。**我没有任何证据说它安全, 却已经交付了。**
//
// 「机制上不可能」这句话, 在这个项目里已经害我栽了三次(v0.4.1 / v0.5.2 / v3.0.0)。
// 写在这里, 连同撤回理由一起, 免得下一个人又把它「优化」回去。
//
// 【那个 10% 的白怎么办 —— 不去改它, 让玻璃盖住它】
// 白底的功能是「垫在内容下面让字可读」。玻璃层自带 veil 底色 + 模糊,
// 插在它上面就等效于把白压下去, 而这个动作作用在 **uie=0** 的层上。
// **v3.0.0 想要的效果, 不需要碰系统底板就能拿到。**
// 唯一代价: 玻璃关掉时那10% 白会回来 —— 那是系统本来的样子, 不是 bug。
//
// 【v3.0.0 的熔断器是死代码】noteCrash 零调用点, 一次都没触发过。
// 也就是说真崩了计数永远是 0, 熔断永不打开 —— **一个从不触发的保险丝
// 等于没有保险丝**。v3.0.1 装上信号处理器(SIGSEGV/SIGABRT/SIGBUS/SIGILL/
// SIGSTKFLT), 计数落纯文本文件, 且每拍重读, 崩第 5 次的下一拍就自动停手。
//
// ----------------------------------------------------------------------
// 【v3.0.0 的历史, 由 v1.1.0 探针 253MB 全量数据(157 棵全树)定案】
// 微信输入法态(顶层窗口 UIRemoteKeyboardWindow, 含 SquidExtender.* / TUI*)下实测:
//
//   0 UIRemoteKeyboardWindow430x932 uie=1
//    1 UIInputSetContainerView     430x932 uie=1
//     2 UIInputSetHostView         {0,576},{430,356} uie=1   ← 宿主, 键盘区
//      3 UIKBInputBackdropView     430x311 uie=0   ← v3.0.1 玻璃的入位容器
//       4 UIKBBackdropView         430x311 uie=1 bg=白/0.10   ← 底板, v3.0.1 不碰
//        5 _UIVisualEffectBackdropView 430x311 uie=0
//      3 UIKBInputBackdropView     430x45  uie=0
//       4 UIKBBackdropView         430x45  uie=1 bg=白/0.10
//        5 _UIVisualEffectBackdropView 430x45  uie=0
//      3 UIKeyboardAutomatic → UIKeyboardLayoutStar → UIKBKeyplaneView
//          UIKBSplitImageView x3 (uie=0) / UIKBKeyView x5 (uie=0)
//
// 【v3.0.0 查明的两个事实, 仍然有效】
// 1. 「按键在输入法扩展进程」是**错的** —— 按键层就在宿主进程里, 层级完整。
// 2. 玻璃层曾经是全屏大小({0,0},{430,932})而键盘只有 356pt 高 ——
//    比键盘大 5 倍且 z 序在按键之上, 观感是「更浑浊」而不是「更透」。
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

// ======================================================================
// 【v3.0.1】崩溃陷阱 —— 必须在任何 ObjC 对象之前定义
// ======================================================================
// 【为什么单独拎出来】信号处理器里**只能用 async-signal-safe 的函数**。
// NSLog / NSUserDefaults / Objective-C 消息派发全部禁止 —— 崩溃时调用它们
// 本身就会二次崩溃, 于是「统计崩溃」变成「制造崩溃」。
// 所以这里只用: open / read / write / close / _exit。
//
// 【它要解决什么】v3.0.0 的熔断器写了但**没有任何调用点** ——
// 一次都没触发过。用户装上后出现疑似系统异常, 而我们当时没有任何
// 机制能自动止损。现在这个处理器是唯一能在「进程即将死掉」时落盘的地方。

// 崩溃计数文件。两个表示形式必须指向**同一个路径**:
//   - C 字符串  : 信号处理器里用(async-signal-safe, 不碰 ObjC)
//   - NSString : 正常路径读写用
// 写错任何一边, 熔断器就静默失效 —— 所以判据放在 check_offline.py 里核对。
static const char kKGCrashFile[] =
    "/var/mobile/Documents/KeyboardGlass/crash_count.txt";
static NSString * const KGCrashCountPath =
    @"/var/mobile/Documents/KeyboardGlass/crash_count.txt";
static const char kKGDir[] = "/var/mobile/Documents/KeyboardGlass";

static void KGSignalHandler(int sig) {
    // 只做最原始的四件事: 读 → 加一 → 写回 → 走原来的处理。
    int fd = open(kKGCrashFile, O_RDONLY);
    int n = 0;
    if (fd >= 0) {
        char buf[16] = {0};
        ssize_t r = read(fd, buf, sizeof(buf) - 1);
        close(fd);
        if (r > 0) { buf[r] = 0; n = atoi(buf); }
    }
    n++;
    // 目录不存在就建(只试一次, 失败也无所谓 —— 计数只是保险丝)。
    mkdir(kKGDir, 0755);
    fd = open(kKGCrashFile, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
        char out[16];
        int len = 0;
        if (n == 0) n = 1;
        // 手写 itoa, 不用 sprintf —— 后者不保证 async-signal-safe。
        if (n >= 10) {
            out[len++] = (char)('0' + (n / 10) % 10);
        }
        out[len++] = (char)('0' + n % 10);
        out[len++] = '\n';
        ssize_t w = write(fd, out, (size_t)len);
        (void)w;
        close(fd);
    }
    // 重新拉起默认处理 → 让系统正常记录这次崩溃(报告/安全模式)。
    signal(sig, SIG_DFL);
    raise(sig);
}

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
// 【v3.0.1 铁律回滚】不再碰 uie=1 的层 —— 这是硬性约束, 不是判断题
// ======================================================================
//
// v3.0.0 破了自己在 v1.0.0 立的铁律(「只允许改 uie=0 的层」), 去写了
// `UIKBBackdropView` 的 backgroundColor。用户反馈装上后**疑似系统异常
// (自己描述为「注销」), 已卸载**。
//
// 【为什么撤回这条, 而不是加个 if 开关留着它】
// v3.0.0 给它找的理由是「只改 backgroundColor 不改变 hitTest 参与性」。
// 这个论证**有个从未验证过的前提**: 假定 `UIKBBackdropView.backgroundColor`
// 是一个只由我们写的、无人竞争的属性。**这个假定没有任何证据支撑。**
// 只要系统自己在别处也写它(切深浅色/材质/键盘形态切换都会重配底板),
// 就构成一个我们看不见的反馈环: 我写 → 系统覆盖 → 我再写 → ……
// 而 UIKBBackdropView 是键盘的底板, 它挂在输入视图的主布局链路上。
//
// 十三版里有两次安全模式(v0.4.1 / v0.4.2)都来自「改系统视图」,
// v1.0.0 立这条铁律正是因为那两次。**我没拿到任何新证据就破它, 这次不重复。**
//
// 【那个 10% 的白怎么办 —— 用玻璃盖, 不去改它】
// 白底的功能就是「垫在内容下面让字可读」。玻璃层自带 veil 底色 + 模糊,
// 盖在白底之上, 视觉上等效于把白压下去, 而**这个操作作用在 uie=0 的层上**。
// 也就是说: v3.0.0 想要的效果, 不需要碰系统底板就能拿到。
//
// **唯一的代价**: 玻璃材质关掉时, 10% 的白会回来(那是系统本来的样子)。
// 这不是 bug, 是正确的。
static BOOL KGTouchSafeForColorOnly(UIView *v) {
    // v3.0.1: 恒为 NO。底板**一个字节都不碰**。
    // 保留这个函数是因为下方 findBackdropIn: 还用它做「跳过」判据,
    // 改成恒假之后那套找层逻辑自然就整体退出了, 不用改结构。
    (void)v;
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

// 当前目标容器
@property (nonatomic, weak)   UIView *backdropView;   // UIKBInputBackdropView(uie=0)
// 【类型必须是 KGGlassView *】早先写成 UIView *, 于是 applyStyle: 里调
// self.glassView.showOutline / applyStyle:dark: 全是"no visible @interface",
// CI 两个架构同时报错。持有我们自己的类型, 编译器才能帮我们查错。
@property (nonatomic, strong) KGGlassView *glassView; // 我们插的玻璃
@property (nonatomic, assign) BOOL appliedStyle;
@property (nonatomic, assign) KGStyle appliedStyleValue;
@property (nonatomic, assign) NSString *lastSignature;

// 崩溃熔断
@property (nonatomic, assign) NSInteger crashCount;

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

// ----------------------------------------------------------------------
// 崩溃计数 —— v3.0.1 改成读**文件**, 不再读 NSUserDefaults
// ----------------------------------------------------------------------
// v3.0.0 用 NSUserDefaults 存计数, 而信号处理器里**绝对不能**碰它
// (NSUserDefaults 不是 async-signal-safe, 崩溃时调用会二次崩溃)。
// 于是两边必须用同一个存储: 纯文本文件。
//
// 【关键收益】计数落盘之后**不用等进程重启**。v3.0.0 那版即使熔断器
// 接线成功, 也存在「崩了 → 计数写了 → 但这个进程还活着 → 继续崩」的窗口。
// 现在每拍都重读文件, 崩第 5 次的**下一拍**就自动停手。
//
// 【不要在 init 里读】+shared 由 %ctor 触发, 那时 KGPrefs registerDefaults
// 还没跑。惰性加载, 且**每次都重读**(文件优先级最高)。
- (NSInteger)crashCount {
    NSInteger n = 0;
    NSData *d = [NSData dataWithContentsOfFile:KGCrashCountPath];
    if (d.length > 0) {
        NSString *s = [[NSString alloc] initWithData:d encoding:NSUTF8StringEncoding];
        n = s.integerValue;   // 读不出来就是 0, 安全
    }
    self.crashCount = n;
    return n;
}

- (void)setCrashCount:(NSInteger)v {
    // 只更新内存值。真正的落盘由信号处理器做 —— 它是唯一能在
    // 「进程即将死掉」时可靠写盘的时机, 正常路径写没有意义。
    self.crashCount = v;
}

// 手动写一次(设置面板清零时用)。
- (void)kg_writeCrashCount:(NSInteger)v {
    NSString *dir = [KGCrashCountPath stringByDeletingLastPathComponent];
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm fileExistsAtPath:dir]) {
        [fm createDirectoryAtPath:dir withIntermediateDirectories:YES
         attributes:nil error:NULL];
    }
    NSString *s = [NSString stringWithFormat:@"%ld\n", (long)MAX(0, v)];
    [s writeToFile:KGCrashCountPath atomically:YES encoding:NSUTF8StringEncoding error:NULL];
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
    KGLog(@"引擎已启动(3.0.1), 0.4s 定时器 + 连续两帧相同才动手");
    // 【v3.0.1 新增】装上信号处理器 —— 熔断器从此才真的能工作。
    // 见 kg_installCrashTrap 的说明。
    [self kg_installCrashTrap];
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
    // 设置面板每次打开都会清零计数(KGRootListController 里无条件 remove),
    // 所以「装新版→开设置→就恢复」这条路是通的, 不需要时间窗。
    return [self crashCount] >= 5;
}

- (void)noteCrash {
    // 【v3.0.1 改口径】原来这里写的是 NSUserDefaults 的 `CrashCount`,
    // 而 circuitOpen 读的是**文件**(信号处理器只能碰文件)。两处各写一份,
    // 判定只认文件 —— 于是这个方法写下去的东西**没有任何人读**,
    // 是一个「看着在工作、实际不参与判定」的陷阱。
    // 现在两条路(信号处理器 / 正常路径)统一写同一个文件。
    NSInteger n = [self crashCount] + 1;
    [self kg_writeCrashCount:n];
    KGLog(@"崩溃计数 = %ld(达到 5 就熔断)", (long)n);
}

// ----------------------------------------------------------------------
// 【v3.0.1 新增 —— 崩溃陷阱】v3.0.0 里noteCrash 是**零调用点的死代码**
// ----------------------------------------------------------------------
// 用户装 v3.0.0 后反馈疑似系统异常。查代码发现: 熔断器写了、也被 tick 查了,
// 但**没有任何地方调noteCrash** —— 也就是说真崩了, 计数永远是 0,
// 熔断永远不会打开。一个从不触发的保险丝等于没有保险丝。
//
// 现在用信号处理器把它接上。信号处理器是唯一能在「进程即将死掉」时
// 立刻把计数写盘的时机 —— ObjC 异常走这里, segfault / abort 也走这里。
//
// 【为什么写文件而不是 NSUserDefaults】崩溃现场堆栈可能已经不可用,
// 调NSUserDefaults 有再崩的风险。这里只做最原始的事:
// read 一个整数 → +1 → 覆写。文件小、无锁、不分配对象。
// ----------------------------------------------------------------------

- (void)kg_installCrashTrap {
    static BOOL installed = NO;
    if (installed) return;
    installed = YES;
    signal(SIGSEGV, KGSignalHandler);
    signal(SIGABRT, KGSignalHandler);
    signal(SIGBUS,  KGSignalHandler);
    signal(SIGILL,  KGSignalHandler);
    // 栈溢出(SIGSEGV 的子类)单独也要接, 否则爆栈时统计不到。
    signal(SIGSTKFLT, KGSignalHandler);
    KGLog(@"崩溃陷阱已安装(3.0.1)");
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

    // ---- 找目标层: 玻璃要插的宿主容器 UIKBInputBackdropView(uie=0) ----
    // v3.0.1 不再找 UIKBBackdropView(那是 uie=1, 不碰)。
    // 改找它的**父容器** UIKBInputBackdropView —— 探针实测 uie=0,
    // 里面装的是底板与效果视图, 机制上不参与触摸派发。
    UIView *backdrop = [self findBackdropIn:host];
    if (!backdrop) {
        // 找不到就什么都不做(不能糊玻璃, 十三版的教训)。
        [self removeGlass];
        self.backdropView = nil;
        self.tickCount++;
        if (self.tickCount % 25 == 1) {
            KGProbeWrite([NSString stringWithFormat:
                @"\n[v3.0.1 %@] 未找到 UIKBInputBackdropView, 本轮不动任何视图。宿主=%@ frame=%@\n",
                [NSDate date], KGCls(host), NSStringFromCGRect(f)]);
        }
        return;
    }

    // ---- 换宿主/换容器:撤掉旧的, 重新入位 ----
    if (self.backdropView != backdrop || self.glassView.superview == nil) {
        [self removeGlass];
        self.backdropView = backdrop;
        self.lastSignature = nil;
    }

    // ----玻璃层入位(本版唯一动作) ----
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

// BFS 找玻璃的入位容器 `UIKBInputBackdropView`。
//
// 【v3.0.1 改动】原来找的是 `UIKBBackdropView`(uie=1, 底板本体),
// 现在找它的**父容器** —— 探针实测 `UIKBInputBackdropView 430x311 uie=0`,
// 是纯视觉容器, 机制上不参与触摸派发。
//
// 为什么必须换: 插 subview 到一个 uie=1 的视图里, 等于往系统自己参与
// 命中检测的视图里塞东西。v3.0.0 就是这么干的(虽然它自己插的是 uie=0 的
// 玻璃层, 但**父层是 uie=1 这件事本身就超出了 v1.0.0 铁律允许的范围**)。
// 换到 uie=0 的容器里, 整条路径上每一层都不参与命中, 铁律才是完整守住的。
//
// 判据: 类名匹配 + uie=0 + 面积 >= 宿主 10% + 在屏 + 确实有子层
// (排除空壳)。按键层类名是 UIKBKeyplaneView / UIKBKeyView, 匹配不上。
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
            if (KGClassIs(sub, @"UIKBInputBackdropView")
                && sub.userInteractionEnabled == NO
                && sub.subviews.count > 0
                && KGIsBigEnough(sub, host)
                && KGIsOnScreen(sub)) {
                CGFloat a = sub.frame.size.width * sub.frame.size.height;
                if (a > bestArea) { bestArea = a; best = sub; }
            }
            [q addObject:sub];
        }
    }
    return best;
}

#pragma mark - 系统底板调色(已停用)

// 【v3.0.1 已整体停用 —— 不再碰系统底板的任何属性】
//
// 这个函数在 v3.0.0 里会去写 `UIKBBackdropView.backgroundColor`。
// 那是个 `uie=1` 的系统视图, 写在输入视图的主布局链路上。
// 用户装 v3.0.0 后反馈疑似系统异常(自己描述为「注销」), 已卸载。
//
// **不确定是不是它造成的** —— 但「不确定」本身就足够成为撤回的理由:
// v1.0.0 立的铁律是「只碰 uie=0 的层」, 十三版有两次安全模式都源于
// 「改系统视图」。我没有任何证据证明写它的 backgroundColor 是安全的,
// 却已经交付了。**没有证据就破铁律, 这正是十三版栽了十三次的地方。**
//
// 函数体保留而不是删掉, 是为了让这段判断连同它的理由一起留在代码里——
// 将来若有人想「再加回来」, 会先读到这里。整段被 #if 0 关掉, 编译不进二进制。
#if 0
- (void)applyBackdropColor:(UIView *)backdrop {
    if (!backdrop) return;
    if (!self.savedBackdropColor) {
        self.savedBackdropColor = [backdrop.backgroundColor copy];
    }
    CGFloat target = [KGPrefs backdropWhiteness];
    UIColor *c = self.savedBackdropColor;
    CGFloat r = 1.0, g = 1.0, b = 1.0, a = 0.10;
    if (c && [c respondsToSelector:@selector(getRed:green:blue:alpha:)]) {
        [c getRed:&r green:&g blue:&b alpha:&a];
    }
    UIColor *nc = [UIColor colorWithRed:r green:g blue:b alpha:target];
    CGFloat curA = -1.0;
    UIColor *cur = backdrop.backgroundColor;
    if (cur && [cur respondsToSelector:@selector(getRed:green:blue:alpha:)]) {
        [cur getRed:&r green:&g blue:&b alpha:&curA];
    }
    if (fabs(curA - target) > 0.004) {
        backdrop.backgroundColor = nc;   // ← 这行是 v3.0.1 撤回的对象
    }
}
#endif

#pragma mark - 玻璃层入位(本版唯一动作)

- (void)placeGlassInBackdrop:(UIView *)container host:(UIView *)host {
    UIView *parent = container;    // v3.0.1: 直接就是 uie=0 的容器本身
    if (!parent) {
        [self removeGlass];
        return;
    }
    if (!self.glassView) {
        self.glassView = [[KGGlassView alloc] initWithFrame:container.bounds];
        self.glassView.userInteractionEnabled = NO;   // 触摸安全第一道闸
    }
    // 尺寸**严格等于容器**, 不多不少。这是 v3.0.0 起与十三版最大的区别。
    if (!CGRectEqualToRect(self.glassView.frame, container.frame)) {
        self.glassView.frame = container.frame;
    }
    if (self.glassView.superview != parent) {
        // 插到容器**最顶上**(bringSubviewToFront)而不是 aboveSubview:
        // 容器是 uie=0, 塞进去不影响触摸; 而玻璃必须在系统底板**之上**
        // 才能起到「压住那层白」的作用 —— 效果由玻璃自己的 veil 提供,
        // 不再需要去改底板的颜色。
        [parent bringSubviewToFront:self.glassView];
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

#pragma mark - 拆除

// 【v3.0.1】restoreBackdrop 整个删掉了。
// 它唯一的用途是把 UIKBBackdropView 的 backgroundColor 写回原值——
// 而 v3.0.1 已经不再改那个属性, 所以**没有需要还原的东西**。
// 「我们只碰自己创建的玻璃层」这条现在是真的, 不再需要 restore 兜底。
- (void)removeGlass {
    if (self.glassView.superview) [self.glassView removeFromSuperview];
    self.appliedStyle = NO;
    self.backdropView = nil;
}

- (void)teardownAll {
    [self removeGlass];
    self.hasLastFrame = NO;
    self.sameCount = 0;
}

#pragma mark - 探针

- (void)writeProbe:(UIView *)host backdrop:(UIView *)container {
    NSString *s =
    [NSString stringWithFormat:
        @"\n[v3.0.1 %@] 宿主=%@ {%@} 容器=%@ {%@} uie=%d 玻璃=%@ 父=%@\n",
        [NSDate date],
        KGCls(host), NSStringFromCGRect(host.frame),
        KGCls(container), NSStringFromCGRect(container.frame),
        container ? (int)container.userInteractionEnabled : -1,
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
