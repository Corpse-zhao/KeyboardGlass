#import "KGKeyboardInstaller.h"
#import "KGGlassView.h"
#import "KGPrefs.h"
#import <sys/stat.h>

#pragma mark - 视图判定

// 键盘宿主视图 —— UIInputSetHostView。
// 它的 frame 就是键盘矩形本身 (弹出时可以量到 430x291 这种尺寸)。
// 第 6 版把锚点从「按类名找背板」换成它, 原因见 KG_ANCHOR_NOTE。
//
// KG_ANCHOR_NOTE:
//   上一版是按类名 (InputBackdrop / KeyboardBackdrop / UIKBBackdropView) 在全树里
//   找面积最大的背板。用户设备上的探针显示: 全树里唯一命中的是 44x44 的
//   TUICandidateBackdropView (TextInputUI 的候选栏背板) —— 也就是说系统键盘那
//   块真正的背景层, 类名压根不在候选表里, 或者那一刻还没进视图树。
//   依赖类名猜测太脆, 于是改为依赖层级结构: 先拿到一定存在的宿主视图,
//   再在宿主的孩子里按「铺满」和「是不是按键前景」两条规则认背景层。
static BOOL KGClassIsInputSetHost(UIView *view) {
    NSString *name = NSStringFromClass(view.class);
    return name.length > 0 && [name containsString:@"InputSetHost"];
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

// 「按键前景」判定。玻璃层绝不能插到它上面 —— 那会把整个键盘盖住,
// 按键点不着 (v0.2.0 就是栽在这, 用户键盘直接打不了字)。
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
// 有些 iOS 版本的 UIKBInputBackdropView 是个容器, 按键也在里面。
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

static void KGDumpTree(UIView *view, NSUInteger depth, NSMutableString *out, NSInteger *budget) {
    if (!view || *budget <= 0 || depth > 12) return;
    (*budget)--;
    for (NSUInteger i = 0; i < depth; i++) [out appendString:@"  "];
    [out appendFormat:@"%@ | %@\n", NSStringFromClass(view.class), NSStringFromCGRect(view.frame)];
    for (UIView *sub in view.subviews) {
        KGDumpTree(sub, depth + 1, out, budget);
    }
}

// 整棵树 dump, 只在「找不到宿主」和第三方输入法扩展里用
static void KGDumpTreeOnce(UIView *root, NSString *tag) {
    static NSMutableSet *dumped = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dumped = [NSMutableSet set]; });
    if ([dumped containsObject:tag]) return;
    [dumped addObject:tag];

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"==== [%@] %@ 键盘视图树 ====\n", [NSDate date], tag];
    NSInteger budget = 300;
    KGDumpTree(root, 0, out, &budget);
    [out appendString:@"====\n"];
    KGWriteProbe(out);
    KGLog(@"已 dump %@ 视图树", tag);
}

// 只 dump 宿主视图的直接孩子 —— 这是本版最关键的诊断信息:
// 谁是背景层、谁是按键前景、我们在第几层, 一眼就能看出来。
static void KGDumpHostChildrenOnce(UIView *host, NSString *tag) {
    static NSMutableSet *dumped = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dumped = [NSMutableSet set]; });

    NSString *key = [NSString stringWithFormat:@"%@|%@", tag, NSStringFromClass(host.class)];
    if ([dumped containsObject:key]) return;
    [dumped addObject:key];

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"---- [%@] %@ 宿主视图 class=%@ frame=%@\n",
        [NSDate date], tag, NSStringFromClass(host.class), NSStringFromCGRect(host.frame)];
    NSArray<UIView *> *subs = host.subviews;
    for (NSUInteger i = 0; i < subs.count; i++) {
        UIView *sub = subs[i];
        [out appendFormat:@"  #%lu %@ frame=%@ fg=%d\n",
            (unsigned long)i, NSStringFromClass(sub.class), NSStringFromCGRect(sub.frame),
            KGLooksLikeKeyboardForeground(sub)];
    }
    [out appendString:@"----\n"];
    KGWriteProbe(out);
}

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

#pragma mark -

@interface KGKeyboardInstaller ()
@property (nonatomic, strong) KGGlassView *glassView;
@property (nonatomic, weak)   UIView *hostView;          // UIInputSetHostView
@property (nonatomic, weak)   UIView *nativeBackdrop;    // 宿主里的原生背景层
@property (nonatomic, assign) CGFloat nativeBackdropAlpha;
@property (nonatomic, assign) BOOL hasNativeBackdrop;
@property (nonatomic, assign) KGStyle appliedStyle;
@property (nonatomic, assign) BOOL hasAppliedStyle;
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

// 最理想的入口: 直接从 UIInputSetHostView 的 layoutSubviews 进来, 宿主视图
// 现成的, 不用遍历、时机也最准。
- (void)handleHostView:(UIView *)host {
    if (!KGClassIsInputSetHost(host)) return;
    [self refreshWithHost:host];
}

// root 传 UIInputWindowController.view (UIInputSetContainerView)
- (void)handleLayout:(UIView *)root {
    if (!root) return;

    [KGPrefs debugLog];

    UIView *host = [self findInputSetHostIn:root];
    if (host) {
        [self refreshWithHost:host];
        return;
    }

    // 万一某些 iOS 版本里宿主视图不叫 InputSetHost*: 退回上一版的老路子 ——
    // 按背板类名在全树里找面积最大的那块, 装到它父视图上。宁可两条路都留着,
    // 也不要出现「换了锚点反而彻底找不到」这种退化。
    KGDumpTreeOnce(root, @"容器(未找到宿主, 走背板兜底)");
    [self legacyRefreshWithRoot:root];
}

// 老路子 (v0.1.0 的做法): 类名找背板 + 面积择优。只作为兜底。
- (void)legacyRefreshWithRoot:(UIView *)root {
    UIView *found = [self findBackdropByNameIn:root];
    if (!found) {
        KGLog(@"兜底也未找到背板 (root=%@)", NSStringFromClass(root.class));
        return;
    }
    if (!KGIsKeyboardSized(found)) {
        KGLog(@"忽略小背板 %@ frame=%@", NSStringFromClass(found.class), NSStringFromCGRect(found.frame));
        return;
    }
    if (self.glassView && self.glassView.superview == found.superview
        && self.nativeBackdrop == found) {
        [self enforceNativeBackdropState];
        [self applyStyleForMaterial:[KGPrefs material]];
        return;
    }

    UIView *host = found.superview;
    if (!host) return;

    [self restoreNativeBackdrop];
    if (!self.glassView) {
        self.glassView = [[KGGlassView alloc] initWithFrame:found.frame];
        self.hasAppliedStyle = NO;
    }
    self.glassView.userInteractionEnabled = NO;
    self.glassView.frame = found.frame;

    // 同样必须压在按键前景下面
    UIView *fg = [self topmostForegroundInHost:host];
    NSInteger target;
    if (fg && fg != found) {
        target = [host.subviews indexOfObject:fg];
        NSInteger cur = [host.subviews indexOfObject:self.glassView];
        if (cur != NSNotFound && cur < target) target--;
        [host insertSubview:self.glassView atIndex:(NSUInteger)MAX(0, target)];
    } else {
        [host insertSubview:self.glassView aboveSubview:found];
    }
    self.glassView.hidden = NO;

    self.hostView = host;
    self.nativeBackdrop = found;
    self.nativeBackdropAlpha = found.alpha;
    self.hasNativeBackdrop = YES;

    [self enforceNativeBackdropState];
    [self applyStyleForMaterial:[KGPrefs material]];
    [self writeInstallProbeWithHost:host background:found material:[KGPrefs material]];
    KGLog(@"兜底路径命中背板 %@", NSStringFromClass(found.class));
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

// 第三方输入法扩展: 目前只做记录, 结构拿到之后再对准 hook
- (void)handleExtensionLayout:(UIView *)root {
    if (!root) return;
    [KGPrefs debugLog];
    KGDumpTreeOnce(root, @"输入法扩展");

    UIView *host = [self findInputSetHostIn:root];
    if (host) [self refreshWithHost:host];
}

#pragma mark - 主流程

- (void)refreshWithHost:(UIView *)host {
    [KGPrefs debugLog];

    KGMaterial material = [KGPrefs material];
    if (material == KGMaterialOff) {
        [self teardown];
        return;
    }

    // 键盘收起时宿主还在树里, 但尺寸会缩到 0 或很小。这时把玻璃层藏起来 ——
    // 不藏的话它会顶着一整块键盘大小的 frame 悬在已经收起的键盘位置上。
    if (!KGIsKeyboardSized(host)) {
        self.glassView.hidden = YES;
        return;
    }

    BOOL hostChanged = (self.hostView != host);
    if (hostChanged) {
        KGLog(@"宿主切换 -> %@ frame=%@", NSStringFromClass(host.class),
              NSStringFromCGRect(host.frame));
        // 换宿主了: 先把旧宿主上的东西清干净再装
        [self restoreNativeBackdrop];
        [self.glassView removeFromSuperview];
        self.hostView = host;
        KGDumpHostChildrenOnce(host, @"系统键盘");
    }

    UIView *bg = [self backgroundInHost:host];
    if (!bg) KGDumpHostChildrenOnce(host, @"系统键盘(未认出背景层)");

    // 认不出背景层时, 退到宿主最底层 —— 至少不会盖住按键, 但很可能被
    // 原生背景挡住。探针里会写 bg=none, 便于下一轮定位。
    [self installOnHost:host background:bg];
    self.glassView.hidden = NO;

    [self enforceNativeBackdropState];
    [self applyStyleForMaterial:material];
    [self writeInstallProbeWithHost:host background:bg material:material];
}

#pragma mark - 探测

// 广度优先, 取面积最大的 UIInputSetHostView (可能有多个, 键盘本体最大)
- (UIView *)findInputSetHostIn:(UIView *)root {
    UIView *best = nil;
    CGFloat bestArea = 0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 4000) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if (KGClassIsInputSetHost(current)) {
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

// 在宿主的孩子里认原生键盘背景层。
// 规则: 铺满宿主 75% 以上 (且高过 100pt) 的视图里, 优先挑名字带 Backdrop 的;
//      名字里带 Backdrop 的不是前景, 所以挑它一定安全。
//      其次挑第一个「不像按键前景」的; 若全都是前景, 就不认背景 (返回 nil)。
- (UIView *)backgroundInHost:(UIView *)host {
    CGRect hb = host.bounds;
    CGFloat hostArea = hb.size.width * hb.size.height;
    if (hostArea <= 0) return nil;

    NSMutableArray<UIView *> *covers = [NSMutableArray array];
    for (UIView *sub in host.subviews) {
        if (sub == self.glassView) continue;
        CGRect f = sub.frame;
        CGFloat area = f.size.width * f.size.height;
        if (area >= hostArea * 0.75 && f.size.height >= 100.0) {
            [covers addObject:sub];
        }
    }

    // 1) 铺满的那几个里, 名字带 Backdrop 的
    for (UIView *sub in covers) {
        NSString *name = NSStringFromClass(sub.class);
        if ([name containsString:@"Backdrop"]) return sub;
    }
    // 2) 铺满的那几个里, 第一个不是按键前景的
    for (UIView *sub in covers) {
        if (!KGLooksLikeKeyboardForeground(sub)) return sub;
    }
    // 3) 整棵孩子里名字带 Backdrop 的最大者 (不要求铺满)
    UIView *byName = nil;
    CGFloat best = 0;
    for (UIView *sub in host.subviews) {
        if (sub == self.glassView) continue;
        NSString *name = NSStringFromClass(sub.class);
        if (![name containsString:@"Backdrop"]) continue;
        CGFloat area = sub.frame.size.width * sub.frame.size.height;
        if (area > best) { best = area; byName = sub; }
    }
    if (byName) return byName;

    // 4) 兜底: 只有「不像前景」的第一个孩子才敢当背景
    for (UIView *sub in host.subviews) {
        if (sub == self.glassView) continue;
        if (!KGLooksLikeKeyboardForeground(sub)) return sub;
    }
    return nil;
}

#pragma mark - 安装与拆卸

// 宿主的直接孩子里, 最靠上的那个「按键前景」。
// 玻璃层必须插到它下面 —— 插到上面就会盖住整块键盘 (v0.2.0 的教训)。
- (UIView *)topmostForegroundInHost:(UIView *)host {
    NSArray<UIView *> *subs = host.subviews;
    for (NSInteger i = (NSInteger)subs.count - 1; i >= 0; i--) {
        UIView *sub = subs[i];
        if (sub == self.glassView) continue;
        if (KGLooksLikeKeyboardForeground(sub)) return sub;
    }
    return nil;
}

- (void)installOnHost:(UIView *)host background:(UIView *)bg {
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

    // 背景层换了才重建引用, 免得把用户的 alpha 反复覆盖成 0
    if (bg && bg.superview == host && self.nativeBackdrop != bg) {
        [self restoreNativeBackdrop];
        self.nativeBackdrop = bg;
        self.nativeBackdropAlpha = bg.alpha;
        self.hasNativeBackdrop = YES;
    }

    // 位置目标: 紧贴在按键前景的下面。这样不管宿主里 [背景,前景] 还是
    // [前景,背景] 哪种顺序, 玻璃层都在按键之下 —— 按键永远可点、可见。
    //   找得到前景 -> 插到它的 index (它自己会往后挪一位, 正好压在玻璃上)
    //   找不到前景 -> 插到 index 0 (最底层), 宁可看不见也绝不盖按键
    UIView *fg = [self topmostForegroundInHost:host];
    NSInteger target;
    if (fg) {
        target = [host.subviews indexOfObject:fg];
        NSInteger cur = [host.subviews indexOfObject:self.glassView];
        if (cur != NSNotFound && cur < target) target--;   // 先移除自己会左移
    } else {
        target = 0;
    }

    NSInteger curIdx = [host.subviews indexOfObject:self.glassView];
    BOOL placedRight = (self.glassView.superview == host) && (curIdx == target);
    if (!placedRight) {
        [host insertSubview:self.glassView atIndex:(NSUInteger)MAX(0, target)];
    }
}

// 系统在键盘布局过程中可能会重设背景层外观, 每次布局都把我们要的状态补一遍 (幂等)
- (void)enforceNativeBackdropState {
    UIView *backdrop = self.nativeBackdrop;
    if (!backdrop || !self.hasNativeBackdrop) return;
    if (backdrop.superview == nil) return;
    // 只有名字明确写着 Backdrop 的才敢藏。别的视图 (哪怕长得像背景) 一律不动 ——
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
    static CGRect lastLogged = {0};
    static NSUInteger logged = 0;
    if (logged > 0 && CGRectEqualToRect(lastLogged, self.glassView.frame)) return;
    lastLogged = self.glassView.frame;
    logged++;

    UIView *fg = [self topmostForegroundInHost:host];
    NSInteger idx = [host.subviews indexOfObject:self.glassView];
    NSInteger fgIdx = fg ? [host.subviews indexOfObject:fg] : NSNotFound;

    KGWriteProbe([NSString stringWithFormat:
        @"[install %@] host=%@ hostFrame=%@ bg=%@ fg=%@(idx %ld) glassIdx=%ld/%lu glassFrame=%@ hideNative=%d material=%ld blur=%.1f refraction=%.1f highlight=%.2f veil=%.2f radius=%.1f outline=%d\n",
        [NSDate date],
        NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
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

@end
