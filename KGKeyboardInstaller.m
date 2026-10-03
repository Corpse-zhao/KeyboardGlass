#import "KGKeyboardInstaller.h"
#import "KGGlassView.h"
#import "KGPrefs.h"
#import <sys/stat.h>

// 探针写盘。定义在文件后面的「探针」小节里, 但熔断器要先用它,
// 所以这里前置声明 —— 顺序反了会编译报 implicit function declaration。
static void KGWriteProbe(NSString *content);

// 量一个 view 相对根的层级深度 (根自己算 0)。纯粹给探针用。
//
// v0.4.3 加这个的原因: 「按键在第几层」这个数字, 是这一整轮 bug 的关键变量。
// 原来的深度上限 4 恰好卡在按键真实深度 (6-7) 的下面, 导致
// firstKeyLayerInHost: 恒返回 nil, 而探针只打一个 `fg=none` ——
// 看日志完全猜不出「是没找到」还是「找到了但层号是 NSNotFound」。
// 现在把深度打进日志, 以后这类问题看一眼就能定位。
static NSInteger KGDepthOfView(UIView *view, UIView *root) {
    if (!view || !root) return -1;
    NSInteger depth = 0;
    UIView *cur = view;
    NSUInteger guard = 0;
    while (cur && cur != root && guard++ < 50) {
        cur = cur.superview;
        depth++;
    }
    return (cur == root) ? depth : -1;
}

#pragma mark - 崩溃熔断器

// 阈值取 5: 单次偶发异常(比如键盘正在重建时拿到半截视图)不该永久禁用插件,
// 但连续 5 次说明是稳定的代码缺陷, 必须停手。
static const NSInteger kKGCrashThreshold = 5;
// 统计窗口 10 分钟。超过这个时间没再崩 -> 视为偶发, 计数清零重新开始。
static const NSTimeInterval kKGCrashWindow = 600.0;
static NSString * const kKGCrashCountKey = @"CrashCount";
static NSString * const kKGCrashLastKey  = @"CrashLastTime";
static NSString * const kKGCircuitOpenKey = @"CircuitOpen";

// 记一次异常并在到阈值时熔断。
//
// 为什么要持久化: 崩溃时进程内存里的东西全丢, 计数只存在局部变量里等于没记。
// 写进 NSUserDefaults 才能跨进程累计 —— 而「反复重启 → 安全模式」本来就是
// 跨进程的现象, 必须在进程之间记得住。
//
// 注意这三个必须实现成 **类方法** (下面的 + 号版本), 不能写成文件顶部的静态
// C 函数 —— 那会落到 @implementation 之外, 报 "missing context for method
// declaration" + "method definition not found"。
static void KGRecordException(NSString *where, NSString *reason) {
    @try {
        NSUserDefaults *d = [KGPrefs defaults];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSTimeInterval last = [d doubleForKey:kKGCrashLastKey];
        NSInteger count = [d integerForKey:kKGCrashCountKey];

        // 超出统计窗口 -> 认为是偶发, 从头计数
        if (last <= 0 || (now - last) > kKGCrashWindow) count = 0;
        count += 1;
        [d setInteger:count forKey:kKGCrashCountKey];
        [d setDouble:now forKey:kKGCrashLastKey];

        if (count >= kKGCrashThreshold) {
            [d setBool:YES forKey:kKGCircuitOpenKey];
        }
        [d synchronize];

        KGWriteProbe([NSString stringWithFormat:
            @"[熔断] %@ 第 %ld 次异常: %@\n", where, (long)count, reason]);
    } @catch (NSException *ignored) {
        // 熔断器自己绝不能成为崩溃源
    }
}

static BOOL KGReadCircuitOpen(void) {
    return [[KGPrefs defaults] boolForKey:kKGCircuitOpenKey];
}

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
//
// v0.4.2 深度上限从 4 提到 8: 实测按键的**真实**层级是
//   UIInputSetHostView → _UIKBCompatInputView → UIKeyboardAutomatic
//     → UIKeyboardImpl → UIKeyboardLayoutStar → UIKBKeyplaneView → UIKBKeyView
// 也就是 Keyplane 在第 6 层、KeyView 在第 7 层。原来的上限 4 **够不到**,
// 于是 KGContainsKeyboardContent 恒返回 NO —— 直接后果有两个:
//   1) firstKeyLayerInHost: 永远找不到按键层 -> 玻璃层 target=0 -> 插到最上面,
//      正好压在按键上面 -> 用户实测「③ 只插玻璃层就打不了字」。
//   2) KGIsSafeToHide 的「肚子里有按键内容就别碰」这道保护也全部失效。
// 这一个深度上限, 同时造成了「挡触摸」和「保护失效」两个看似无关的现象。
//
// 【v0.5.0 补记】上限提到 8 之后触摸是修好了, 但那道保护**因为同一个原因
// 彻底失效** —— 深度够得到之后, 主体背景 UIKBBackdropView 内部确实包着按键区,
// 于是永远被判成「不能碰」。实测 hiddenBg=none 证实完整档从没藏掉过背景。
// 修法见下面 KGIsSafeToHide 的新判据: 改成「藏的不是按键的祖先就行」。
static const NSUInteger kKGMaxContentDepth = 8;

// 【v0.7.3】按键区底板的触摸安全下限。
//
// UIKBSplitImageView 这三张图既是观感上的「底板」(调淡它玻璃才能透上来),
// 也是 iOS 键盘**接收点击的实体层** —— 命中判定落在它上面。
// 2026-10-03 实测: 滑块拉满时只剩 15%, 结果「键盘能打字, 但键盘以外
// 全点不动」—— 整个键盘窗口失去响应。
//
// 所以调淡有硬下限, 这个值不要再往下调。观感上仍有 45% 透明, 玻璃感明显。
// 故意**不加 const**: 编译期常量折叠会把它从符号表里抹掉,
// verify_deb.py 的断言就查不到「这版到底有没有设触摸下限」。
// 运行期开销为零, 但能让这个安全下限在二进制里可被验证。
static CGFloat kKGTouchSafeFloor = 0.55;

static BOOL KGContainsKeyboardContent(UIView *view, NSUInteger depth) {
    if (!view || depth > kKGMaxContentDepth) return NO;
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
// 判据: 面积门槛 (排除按键内部自带的小 backdrop) + **不是按键层的祖先**。
//
// 【v0.5.0 关键修正】原来这里写的是「肚子里没有按键内容才可藏」。
// v0.4.3 把深度上限从 4 提到 8 修好了触摸, 却**顺手把这道保护也弄失效了** ——
// 深度够得到之后, 主体背景 UIKBBackdropView 内部确实包着按键区, 于是它被判成
// 「肚子里有按键, 不能碰」, 永远不被选中藏。实测日志实锤:
//     [install ...] mode=3 ... hiddenBg=none
// 也就是「③ 完整档」从来没真正藏掉过任何背景层, 玻璃层一直压在一块
// 不透明的原生背板上面 —— 这才是「没达到预期玻璃效果」的第二重原因。
//
// 现在换判据: **藏的不是按键的祖先, 就不会带走按键。**
// 主体背景是按键的**兄弟**(都在 UIView{{0,45},{430,243}} 容器下), 藏掉它按键还在。
// 这比「肚子里有没有按键」更准 —— 后者把「按键的祖先」和「按键的兄弟」一锅端了。
static BOOL KGIsSafeToHide(UIView *view, UIView *keyLayer) {
    NSString *name = NSStringFromClass(view.class);
    if (![name containsString:@"Backdrop"]) return NO;
    if (!view) return NO;
    // 祖先关系: view 是 keyLayer 或 keyLayer 的祖先 -> 藏它等于连按键一起藏。
    UIView *cur = keyLayer;
    NSUInteger guard = 0;
    while (cur && guard++ < 40) {
        if (cur == view) return NO;
        cur = cur.superview;
    }
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
//
// 【v0.7.0 关键修正: 必须按 backgroundColor 的 alpha 排序输出】
// v0.4.2~v0.6.0 一直把「键盘实心浅灰」归咎于别的东西, 而真正的元凶
// (_UIVisualEffectBackdropView, bg alpha 0.85) 就在这份 dump 里躺着 ——
// 只是它埋在很深的层级, 而**排在它上面的那层恰好 alpha 很低**(外层
// UIKBBackdropView 只有 0.10), 读的时候一眼扫过去就跳过了。
//
// 教训: 排查「哪一层不透明」时, **要按不透明度排序, 不能按出现顺序读**。
// 同一个 dump, 按出现顺序读会一直盯着最外层那层淡的, 永远找不到里面那层浓的。
// 所以这里额外输出一份「按 bg alpha 降序」的重点嫌疑清单。
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

// 【v0.7.0 新增】按「不透明度」排序列出整棵子树里所有带背景色的层。
// 这份清单的用途: 一眼看出「哪几层在挡着玻璃」, 不用再去逐层推理。
// 只列 alpha > 0.02 的(全透明的不值得占位), 按 alpha 降序。
static void KGDumpOpaqueRanking(UIView *root, NSMutableString *out) {
    if (!root) return;
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0;
    CGFloat rootArea = root.frame.size.width * root.frame.size.height;
    if (rootArea <= 0) rootArea = 1;

    while (queue.count > 0 && guard++ < 4000) {
        UIView *v = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!v) continue;

        UIColor *bg = v.backgroundColor;
        if (bg) {
            // getWhite: 只对灰度空间有效, 纯 RGB 颜色会返回 NO -> 这层就漏了。
            // 两个都试, 只要能取到 alpha 就算数。
            CGFloat a = 0, r = 0, g = 0, b = 0;
            if (![bg getRed:&r green:&g blue:&b alpha:&a]) {
                if (![bg getWhite:NULL alpha:&a]) { a = 0.0; }
            }
            if (a > 0.02) {
                CGFloat area = v.frame.size.width * v.frame.size.height;
                // 相对面积也要打: 铺满整块键盘的层才是挡玻璃的元凶,
                // 一个 44x44 的小色块 alpha 再高也不影响观感。
                [lines addObject:[NSString stringWithFormat:
                    @"  bgAlpha=%.2f  relArea=%.0f%%  a=%.2f h=%d  %@  %@",
                    a, 100.0 * area / rootArea, v.alpha, v.hidden ? 1 : 0,
                    NSStringFromClass(v.class), NSStringFromCGRect(v.frame)]];
            }
        }
        [queue addObjectsFromArray:v.subviews];
    }

    // alpha 降序 —— 这就是「先看最浓的」的正确读法
    [lines sortUsingComparator:^NSComparisonResult(NSString *a, NSString *b) {
        CGFloat aa = [[a substringFromIndex:8] doubleValue];
        CGFloat bb = [[b substringFromIndex:8] doubleValue];
        if (aa > bb) return NSOrderedAscending;
        if (aa < bb) return NSOrderedDescending;
        return NSOrderedSame;
    }];

    [out appendFormat:@"==== 不透明层排行 (共 %lu 层, 按 bgAlpha 降序) ====\n",
     (unsigned long)lines.count];
    for (NSString *l in lines) [out appendFormat:@"%@\n", l];
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
// 真正的主流程。由 refreshWithHost: 包着 @try 调用。
- (void)kg_refreshWithHost:(UIView *)host;
// 【v0.7.2】下面这两个在 kg_workerTick 里就被调用, 但定义都在文件更靠后的
// 位置 —— 私有方法不写前置声明会报 "no visible @interface declares the
// selector"。跟静态 C 函数不同, 这条编译器不认, 必须自己声明。
- (void)refreshWithHost:(UIView *)host;
- (UIView *)findInputSetHostIn:(UIView *)root;
- (void)restoreNativeBackdrops;
// v0.7.3: 顶部助手条整组藏。定义在 kg_refreshWithHost: 之后, 但调用在前。
- (void)hideTopAssistantBarInHost:(UIView *)host;
// v0.5.0: 从 KGGlassLayer (纯 CALayer) 换成 KGGlassView (UIView + UIVisualEffectView)。
// 换的原因见 KGGlassView.h —— CABackdropLayer 采不到别的窗口的内容, 玻璃等于全透明。
@property (nonatomic, strong) KGGlassView *glassView;
@property (nonatomic, weak)   UIView *hostView;          // 锁定的宿主
// 键 = 被隐藏的原生背景层 (弱引用, 键盘重建时自动失效)
// 值 = 它的原始 alpha (恢复用)
// v0.4.0 起是「一组」而不是「一个」—— 见 KG_BACKDROP_SCAN_NOTE。
@property (nonatomic, strong) NSMapTable<UIView *, NSNumber *> *hiddenBackdrops;
// v0.4.1: 锁定的**唯一**一层背景 (批量隐藏会让键盘哑掉, 见 KG_TOUCH_LESSON)
@property (nonatomic, weak)   UIView *cachedBackdrop;
// v0.6.0: 按键区自带的那层底色。与 cachedBackdrop 是**两件不同的事**, 见
// enforceKeyplaneBackdropInHost:。
//
// 【为什么是数组而不是单个 weak 视图 —— 探针实锤】
// v0.6.0 初版写的是 `@property (weak) UIView *cachedKeyplaneBackdrop`, 配合
// 「BFS 找面积最大的一层」。看完 2026-10-02 13:48 的稳定态全树才发现这是错的:
//   UIKBKeyplaneView {{0,0},{430,243}}
//     UIKBSplitImageView {{0,0},{430,243}} h=1  -> UIImageView   ← 面积并列最大
//     UIKBSplitImageView {{0,0},{430,243}} h=0  -> UIImageView   ← 真正在显示的那张
//     UIKBSplitImageView {{0,0},{430,243}} h=0  -> UIImageView
//     UIKBKeyView x5
// **三张 SplitImageView 面积完全相同**, 「挑最大的」只能靠遍历顺序碰运气,
// 而第一张恰好 h=1(隐藏) —— 挑中它 = 调淡一个看不见的东西 = 用户看到的
// 「还是没变化」。所以必须**整组收集、全部调淡**, 一个都不能漏。
@property (nonatomic, strong) NSMutableArray<UIView *> *cachedKeyplaneBackdrops;
// v0.7.0: 系统毛玻璃自己糊的那层浓白底 (_UIVisualEffectBackdropView, bg alpha 0.85)。
// 「键盘实心浅灰」的真正元凶, 见 systemBlurVeilsInHost:。
@property (nonatomic, strong) NSMutableArray<UIView *> *cachedBlurVeils;
// v0.7.3: 顶部 45pt 助手条(含它内部的 VisualEffect 层), 整组藏, 见
// hideTopAssistantBarInHost:。这是截图里那条不透光灰条的真身。
@property (nonatomic, strong) NSMutableArray<UIView *> *cachedAssistantBars;
@property (nonatomic, assign) BOOL hasAppliedStyle;
@property (nonatomic, assign) KGStyle appliedStyle;
// v0.6.0: 上一次处理的工作模式。restoreNativeBackdrops 只在它变化时调一次,
// 避免「每次 layout 都恢复 -> 每次都重扫整棵树」。见 kg_refreshWithHost: 里的说明。
@property (nonatomic, assign) KGWorkMode lastAppliedMode;
@property (nonatomic, assign) BOOL didDumpStableTree;
@property (nonatomic, assign) BOOL didRunTouchDiag;
@property (nonatomic, copy)   NSString *lastProbeSignature;
@property (nonatomic, assign) NSUInteger probeCount;

// ---- v0.7.2: 「只观测」与「定时器干活」之间传递状态用的 ivar ----
// 布局回调只写 seenHostView / seenContainerView / dirty 三个, 别的都不碰。
@property (nonatomic, weak)   UIView *seenHostView;
@property (nonatomic, weak)   UIView *seenContainerView;
@property (nonatomic, assign) BOOL dirty;
// 唯一那个定时器。repeats, 永不销毁 —— 2.5Hz 的空转开销可以忽略,
// 而「键盘什么时候弹出」我们无从预知, 装个常驻轮询最省事也最不容易漏。
@property (nonatomic, strong) NSTimer *workerTimer;
// 稳定性闸用: 上一次采样到的宿主 frame, 以及它连续相同的次数。
@property (nonatomic, assign) CGRect lastSampledFrame;
@property (nonatomic, assign) NSInteger stableCount;
// 熔断后彻底闭嘴用的静默计数。
@property (nonatomic, assign) NSInteger silentTicks;
@end

@implementation KGKeyboardInstaller

#pragma mark - 崩溃熔断器 (类方法实现)

+ (void)noteHandledException:(NSException *)exception where:(NSString *)where {
    KGRecordException(where, exception.reason);
}

+ (BOOL)isCircuitOpen {
    return KGReadCircuitOpen();
}

+ (void)resetCircuit {
    NSUserDefaults *d = [KGPrefs defaults];
    [d setInteger:0 forKey:kKGCrashCountKey];
    [d setDouble:0 forKey:kKGCrashLastKey];
    [d setBool:NO forKey:kKGCircuitOpenKey];
    [d synchronize];
}

+ (instancetype)shared {
    static KGKeyboardInstaller *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        shared = [[KGKeyboardInstaller alloc] init];
    });
    return shared;
}

#pragma mark - 对外入口

// ======================================================================
// 【v0.7.2】下面这两个方法由 %hook 在**布局回调**里调用。
//
// 铁律: 这里只允许做「记一个弱引用 + 置一个 BOOL」。任何 addSubview /
// removeFromSuperview / 改 frame / 改 alpha / setNeedsLayout 都是错的 ——
// 见 Tweak.x 文件头那段完整死因分析。
//
// 尤其注意: **不要在这里加 @try**。@try 展开本身有开销, 而这个方法每秒可能
// 被调几万次(实测 v0.7.1 一次键盘弹出就走了 7.5 万次)。异常捕获统一放在
// 定时器那条路径上, 那儿每 0.4s 才跑一次。
// ======================================================================

- (void)noteHostLayout:(UIView *)host {
    if (!host) return;
    // 记下**最后一个**出现过的宿主。多个宿主并存时以最后出现的为准 ——
    // 展开态下真正承载按键的那个总是最后被布局的那个。
    self.seenHostView = host;
    self.dirty = YES;
}

- (void)noteContainerLayout:(UIView *)root {
    if (!root) return;
    self.seenContainerView = root;
    self.dirty = YES;
}

#pragma mark - 定时器 (唯一真正干活的地方)

- (void)startWorker {
    if (self.workerTimer) return;
    self.workerTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                      target:self
                                                    selector:@selector(workerTick:)
                                                    userInfo:nil
                                                     repeats:YES];
    // NSRunLoopCommonModes: 键盘弹出动画期间 runloop 模式会变, 用默认模式
    // 的定时器在滚动/追踪期间是不触发的, 那正是最需要它工作的时候。
    [[NSRunLoop mainRunLoop] addTimer:self.workerTimer forMode:NSRunLoopCommonModes];
    KGLog(@"工作线程已启动: 间隔 0.4s, 稳定性闸 = 连续 2 次 frame 相同");
    // 把触摸下限打进日志: 这是本版最关键的安全参数, 出问题时第一眼就要看到它。
    KGLog(@"按键区底板触摸安全下限 = %.2f (底板 alpha 不会再低于这个值)", kKGTouchSafeFloor);
}

- (void)workerTick:(NSTimer *)timer {
    if ([KGKeyboardInstaller isCircuitOpen]) return;
    @try {
        [self kg_workerTick];
    } @catch (NSException *exception) {
        [KGKeyboardInstaller noteHandledException:exception where:@"workerTick"];
    }
}

- (void)kg_workerTick {
    if (self.silentTicks > 0) { self.silentTicks--; return; }

    // 没有任何布局回调来过 -> 键盘压根没在屏幕上, 什么都不用做。
    if (!self.seenHostView || !self.seenHostView.superview) {
        // 【v0.7.2 兜底】UIInputSetHostView 的 hook 万一没触发(某些 iOS 版本
        // 换了宿主类名、或 %hook 因类不存在被跳过), 就退到容器视图里找。
        // v0.7.1 及以前这条兜底挂在 viewDidLayoutSubviews 里, 现在统一搬到
        // 定时器里 —— 定时器是唯一允许做全树查找的地方。
        if (self.seenContainerView) {
            UIView *found = [self findInputSetHostIn:self.seenContainerView];
            if (found && KGIsUsableHost(found)) {
                self.seenHostView = found;
                self.dirty = YES;
                self.lastSampledFrame = CGRectNull;
                self.stableCount = 0;
            }
        }
    }
    if (!self.seenHostView || !self.seenHostView.superview) {
        // 顺带清理: 键盘整个走了就把玻璃撤掉, 别留个孤儿 view 挂在那儿。
        if (self.glassView.superview) {
            [self teardown];
        }
        self.dirty = NO;
        return;
    }

    // 【稳定性闸 —— v0.7.2 的核心】
    // 宿主 frame 必须**连续两次采样完全相同**, 才认为键盘已经彻底稳定。
    // 动画期间 frame 每时每刻都在变, 这一闸直接把整个动画期挡在外面,
    // 我们不在动画里改视图树, 也就不会有反馈乒乓。
    CGRect frame = self.seenHostView.frame;
    if (!CGRectEqualToRect(frame, self.lastSampledFrame)) {
        self.lastSampledFrame = frame;
        self.stableCount = 1;
        return;                     // 变了 -> 只记录, 本轮不动手
    }
    if (self.stableCount < 2) { self.stableCount++; return; }

    // 收起 / 出屏: 玻璃必须**彻底离开视图树**。
    //
    // 【v0.7.1 教训】v0.7.1 这里改成「不 return, 让玻璃留在宿主里只是隐藏」,
    // 理由是怕「动画结束后没人来重装」。那个理由本身没错(确实是死锁的一部分),
    // 但解法错了 —— 玻璃常驻宿主, 它的 frame 就成了宿主布局的一个自变量:
    // 我们按宿主尺寸写玻璃 frame -> 宿主重排 -> 尺寸又变 -> 再写 ……
    // 两个布局解互相拉扯, 键盘卡在动画里出不来。
    // 正确解法就是这一版: 收起就**真的撤掉**, 靠定时器在展开稳定后重装。
    // 死锁的另一半(装不回来)由定时器解决, 不该由「常驻玻璃」来解决。
    if (!KGIsKeyboardSized(self.seenHostView) || !KGIsOnScreen(self.seenHostView)) {
        if (self.glassView.superview) {
            KGLog(@"键盘收起, 撤掉玻璃 (hostFrame=%@)",
                  NSStringFromCGRect(self.seenHostView.frame));
            [self.glassView removeFromSuperview];
        }
        // 收起后缓存的层全属于上一棵子树, 必须丢掉, 否则下次 enforce 会拿
        // 一批已经不在树上的旧层去写 alpha。
        [self restoreNativeBackdrops];
        self.hostView = nil;
        self.dirty = NO;
        // 【v0.7.2】稳定性闸必须在这里归零。stableCount 只增不减, 一旦某次
        // 稳定后放行就永远是 2 —— 下一轮展开动画刚开始的那一帧就会被误判成
        // 「已稳定」, 于是又在动画期里改视图树, 乒乓死循环就回来了。
        // 归零后下一次展开必须重新连续两次采样相同才放行。
        self.stableCount = 0;
        self.lastSampledFrame = CGRectNull;
        return;
    }

    // 收起 -> 展开的过渡期: 脏标记还在, 但稳定性闸已经放行了, 可以干活。
    if (!self.dirty && self.glassView.superview) return;
    self.dirty = NO;

    [self refreshWithHost:self.seenHostView];
}

#pragma mark - 主流程

- (void)refreshWithHost:(UIView *)host {
    if ([KGKeyboardInstaller isCircuitOpen]) return;
    @try {
        [self kg_refreshWithHost:host];
    } @catch (NSException *exception) {
        [KGKeyboardInstaller noteHandledException:exception where:@"refreshWithHost"];
    }
}

- (void)kg_refreshWithHost:(UIView *)host {
    KGWorkMode mode = [KGPrefs workMode];
    KGMaterial material = [KGPrefs material];

    if (mode != KGWorkModeProbe && material == KGMaterialOff) {
        [self teardown];
        return;
    }

    // 【v0.7.2】收起态的判定与处理**全部上移到定时器**里(见 kg_workerTick)。
    // 这里被调用时, 宿主已经通过「键盘尺寸 + 在屏 + frame 连续两次相同」
    // 三道闸, 也就是说**键盘已经彻底稳定**, 现在改视图树是安全的。
    // v0.7.1 那个「收起态不 return、让玻璃常驻」的改法已整个删除 ——
    // 它就是让宿主 frame 乒乓不收敛的元凶, 详见 Tweak.x 文件头。

    if (self.hostView != host) {
        KGLog(@"锁定宿主 %@ frame=%@ mode=%ld", NSStringFromClass(host.class),
              NSStringFromCGRect(host.frame), (long)mode);
        self.hostView = host;
        [self.glassView removeFromSuperview];
        [self restoreNativeBackdrops];
        // 换宿主时强制让下面那一次「模式变化检查」成立 —— 新宿主上的旧缓存
        // (底板层/背景层) 全部属于上一棵子树, 必须重新选。
        self.lastAppliedMode = (KGWorkMode)-1;
        self.glassView.hidden = YES;
        // 【v0.7.2 修】这两个「一次性」开关原来置位后永不复位, 于是键盘第二次
        // 弹出就再也不 dump 了 —— 而用户恰恰经常是「收起 -> 再弹」才看到问题。
        // 每次换宿主都复位, 保证每轮键盘弹出都有完整快照。
        self.didDumpStableTree = NO;
        self.didRunTouchDiag = NO;
        self.lastProbeSignature = nil;
        // 探针条数也一起重置, 否则第二次弹出就没日志可看了。
        self.probeCount = 0;

        KGDumpHostChildren(host, mode == KGWorkModeProbe ? @"锁定宿主(纯探针)" : @"锁定宿主");
        [self scheduleStableTreeDump:host];
    }

    // 从「插玻璃层」切到更低的档时, 必须把已经插进去的玻璃撤掉
    if (!KGModeShowsGlass(mode) && self.glassView.superview) {
        KGLog(@"工作模式降到 %ld, 撤掉已插入的玻璃", (long)mode);
        [self.glassView removeFromSuperview];
    }

    // 从「藏背景 / 调淡底板」切到更低档时, 必须恢复原生背景。
    //
    // 【v0.6.0 修: 原来这里是「每次 layout 都恢复」, 是性能与正确性双 bug】
    // 后果: 在「③ 只插玻璃层」档下, 每一次 layoutSubviews 都会
    //   restoreNativeBackdrops -> 清空 hiddenBackdrops + 清空 cachedKeyplaneBackdrops
    // 然后紧接着的 enforceKeyplaneBackdropInHost: 又得**整棵重扫**(上限 500 节点)
    // 重新选一遍底板。键盘动画期间 layoutSubviews 每秒能走几十次, 等于每秒几十次
    // 全树 BFS —— 这正是 v0.4.0 记过的「重扫有可能选中另一层 / 把键盘搞死」。
    // 而且更隐蔽的是: 恢复时 alpha 会被写回原值, 下一帧又调淡,
    // 观感上就是**底色按帧闪烁**。
    //
    // 修法: restoreNativeBackdrops **只在模式真的变了的那一帧调一次**。
    // 模式没变就说明本轮仍然在藏/在调淡, enforce 会持续维持, 不需要恢复。
    // 换宿主的情况在上面 self.hostView != host 分支里已经恢复过了, 不重复。
    if (mode != self.lastAppliedMode) {
        [self restoreNativeBackdrops];
        self.lastAppliedMode = mode;
    }

    if (KGModeShowsGlass(mode)) {
        [self placeGlassInHost:host];
        self.glassView.hidden = NO;
        [self applyStyleForMaterial:material];
    }

    // v0.6.0: 按键区底色调淡是**独立于「藏背景」**的一件事, 所以 Glass 档也做。
    // 「藏背景」是 Hide/Full 档的事 (v0.4.1 起刻意解耦, 用于二分隔离);
    // 「调淡按键区底色」则是让按键区变玻璃的必要步骤, 只要玻璃在就该做。
    if (KGModeShowsGlass(mode) || KGModeHidesBackdrop(mode)) {
        [self enforceKeyplaneBackdropInHost:host];
        // 【v0.7.3】藏掉顶部 45pt 助手条(截图里那条不透光的灰条)。
        // 玻璃档也做 —— 那条灰条横在玻璃上方, 不藏的话观感上就是「键盘上面
        // 浮着一道脏影子」, 比玻璃本身不生效还难看。
        [self hideTopAssistantBarInHost:host];
        // 【v0.7.3 重大回退】enforceSystemBlurVeilInHost: **整个停用**。
        //
        // 2026-10-03 用户实测: 「只要唤出键盘, 就点不了键盘以外的东西了」。
        // 当时最自然的猜测是「玻璃挡了触摸」, 但探针证明不是:
        //   veilDesc=none 61 次全中 -> 那层 85% 白底**一次都没被锁定过**。
        // 也就是说 v0.7.0 的判据(systemBlurVeilsInHost: 要求类名含
        // "VisualEffectBackdrop" 且自身 bgAlpha > 0.25)在真机上**从来没命中过** ——
        // 探针 dump 里这些层的 bg 一律显示为 `-`(取不到 backgroundColor,
        // 它们是 UIVisualEffect 的内部层, 颜色由 effect 渲染, 不是背景色)。
        //
        // 所以「点不了键盘外」是**另一个原因**, 而它恰恰出自我 v0.6.0 引入的
        // enforceKeyplaneBackdropInHost: —— 那三张 UIKBSplitImageView 是
        // 按键区整块的底板, 把它调到 15% 之后, 按键区失去了承接触摸的实体层。
        // iOS 键盘的触摸派发落在按键区底板上, 底板一淡, 整窗命中判定失效。
        //
        // 修法见 enforceKeyplaneBackdropInHost: 的 alpha 下限保护。
        // 保留这个方法与它的日志, 供将来 iOS 版本变化时复查, 但不再调用。
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
        // 【v0.7.0 新增】按不透明度排序列出所有带背景色的层。
        // 这是「哪一层在挡玻璃」的直接答案, 以后不用再靠推理猜。
        KGDumpOpaqueRanking(strongHost, out);
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
        @"[touch-diag %@] window=%@ winUserEnabled=%d glassIsView=%d 命中:%@\n",
        [NSDate date], NSStringFromClass(window.class), window.userInteractionEnabled,
        (self.glassView != nil), detail]);
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

// 宿主里**包住整个按键区的那一层**。玻璃层要插在它下面。
//
// 【v0.4.3 实锤修正】这个方法原来只扫宿主的直接孩子, 于是永远返回 nil。
// 起因是配套的 KGContainsKeyboardContent 深度上限只有 4 层, 而实测按键在
// 第 6-7 层 (UIInputSetHostView → _UIKBCompatInputView → UIKeyboardAutomatic
// → UIKeyboardImpl → UIKeyboardLayoutStar → UIKBKeyplaneView → UIKBKeyView),
// 4 层够不到 -> 判据恒为 NO -> 这里恒返回 nil。
// 后果: placeGlassInHost: 里 `if (fg)` 不成立, target 停在 0, 玻璃层被插到
// **最底层**, 也就是压在所有按键上面。用户实测「③ 只插玻璃层就打不了字」——
// 这就是那个「玻璃层挡触摸」的真正原因, 不是玻璃层本身的问题。
//
// 现在改成 BFS: 找出**同时是按键区祖先、又在宿主里最靠上**的那一层。
// 对本例就是 _UIKBCompatInputView —— 玻璃插到它下面, 背景之上、按键之下。
- (UIView *)firstKeyLayerInHost:(UIView *)host {
    if (!host) return nil;
    // BFS: 队列里天然是「层级由浅到深」, 第一个命中就是最靠上的祖先。
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:host];
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 2000) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!current) continue;
        // 宿主本身不算, 我们要找的是它下面的那一层
        if (current != host && KGContainsKeyboardContent(current, 0)) {
            return current;
        }
        [queue addObjectsFromArray:current.subviews];
    }
    return nil;
}

// ======================================================================
// 【v0.7.3 新增】藏掉顶部那条 45pt 助手条 —— 截图里那条「不透光的灰条」
// ======================================================================
//
// 2026-10-03 用户实测截图, 像素实测: 灰条位于屏幕 577pt~621pt, 厚度 44pt,
// 内部 RGB 恒为 218,218,225, 43 行完全均匀 —— **一点都不透光**。
//
// 与探针层级对照, 坐标分毫不差地吻合:
//   宿主 UIInputSetHostView frame={{0,576},{430,356}}
//     #1 UIKBInputBackdropView frame={{0,0},{430,45}}   -> 屏幕 576..621
// 且它的内部结构是:
//   UIKBVisualEffectView        {{0,0},{430,45}} a=1.00 h=1  <- 外层被系统隐藏
//     _UIVisualEffectBackdropView {{0,0},{430,45}} a=1.00 h=0 <- 内层没藏, 继续画
//
// 【这就是 v0.7.0「命中即止」那个 bug 的第二次发作】
// v0.7.0 我在 backdropInHost: 里藏了**外层** UIKBBackdropView(白 10%),
// 以为「藏外层自然连带藏内层」。实测证明这是**错的**, 而且这次外层
// UIKBVisualEffectView 本身已经是 h=1(系统自己藏的), 我们又藏了它的兄弟层,
// 结果内层 _UIVisualEffectBackdropView 完好无损地继续画 —— 就是那条灰条。
//
// 修法: 助手条**整组一起藏**, 内外都藏, 不留漏网的。
// 注意只藏这一条 45pt 的, 主体背景(430x243 以上)不在这组里, 不受影响。
- (void)hideTopAssistantBarInHost:(UIView *)host {
    if (!self.hiddenBackdrops) {
        self.hiddenBackdrops = [NSMapTable weakToStrongObjectsMapTable];
    }
    if (!self.cachedAssistantBars) {
        self.cachedAssistantBars = [NSMutableArray array];
        NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:host];
        NSUInteger guard = 0;
        CGFloat hostArea = host.frame.size.width * host.frame.size.height;
        if (hostArea <= 0) return;

        while (queue.count > 0 && guard++ < 4000) {
            UIView *current = queue.firstObject;
            [queue removeObjectAtIndex:0];
            if (!current) continue;

            // 只认「贴着宿主顶部、且很薄」的那条 —— 就是助手条。
            // 厚度门槛用比例而不是绝对值, 这样 iPad / 不同键盘高度都适用。
            CGRect f = current.frame;
            CGFloat area = f.size.width * f.size.height;
            if (current != host
                && fabs(f.origin.y) < 1.0
                && f.size.height > 8.0
                && f.size.height < host.frame.size.height * 0.25
                && area >= hostArea * 0.6) {
                [self.hiddenBackdrops setObject:@(current.alpha) forKey:current];
                [self.cachedAssistantBars addObject:current];
                // 整组: 把它的子树里所有 VisualEffect 层也一并收进来。
                // 「藏外层连带藏内层」这个假设已被实测否掉两次, 不再依赖它。
                NSMutableArray<UIView *> *sub = [NSMutableArray arrayWithObject:current];
                NSUInteger g2 = 0;
                while (sub.count > 0 && g2++ < 200) {
                    UIView *c = sub.firstObject;
                    [sub removeObjectAtIndex:0];
                    NSString *n = NSStringFromClass(c.class);
                    if ([n containsString:@"VisualEffect"] || [n containsString:@"Backdrop"]) {
                        [self.hiddenBackdrops setObject:@(c.alpha) forKey:c];
                        [self.cachedAssistantBars addObject:c];
                        continue;   // 这类层是叶子, 不用再往下
                    }
                    [sub addObjectsFromArray:c.subviews];
                }
                continue;
            }
            [queue addObjectsFromArray:current.subviews];
        }
        if (self.cachedAssistantBars.count > 0) {
            KGLog(@"锁定顶部助手条 %lu 层: %@",
                  (unsigned long)self.cachedAssistantBars.count,
                  [[self.cachedAssistantBars valueForKey:@"class"] componentsJoinedByString:@","]);
        }
    }

    for (UIView *v in self.cachedAssistantBars) {
        if (!v.superview) continue;
        if (fabs(v.alpha) > 0.001) v.alpha = 0.0;
    }
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
    UIView *keyLayer = [self firstKeyLayerInHost:host];

    UIView *best = nil;
    CGFloat bestArea = 0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:host];
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 4000) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!current) continue;

        if (current != host && KGIsSafeToHide(current, keyLayer)) {
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

// 找出**系统毛玻璃自己糊的那层 85% 白底**, 整组返回。
//
// 【v0.7.0 新增 —— 这才是「键盘实心浅灰」的真正元凶】
//
// 2026-10-03 用户实测 v0.6.0 仍然「还是没效果」。回头逐行读探针才发现,
// 真正的元凶一直摆在日志里, 只是之前没人往下读:
//
//   UIKBInputBackdropView   a=0.00
//     UIKBBackdropView            bg=1.00/1.00/1.00/0.10   ← 白 10%, 很淡
//       _UIVisualEffectBackdropView bg=1.00/1.00/1.00/0.85  ← ★★★ 白 85%
//
// `_UIVisualEffectBackdropView` 是系统自己的模糊层, 它**自带 85% 不透明的
// 白色底色**。浅色键盘那层「实心浅灰」就是它, 跟按键区、跟 SplitImageView
// 全都无关。所以 v0.4.2~v0.6.0 一直在调淡/隐藏别的东西, 效果当然出不来。
//
// 【为什么旧代码碰不到它】—— backdropInHost: 里有一句「命中即止, 不往这层子树里钻」:
//   它藏的是**外层** UIKBBackdropView(白 10%), 藏完就 stop, 于是内层那个
//   白 85% 完好无损地继续显示。
//   「藏外层自然连带藏内层」这个假设在这里是**错的** —— 因为藏的是 alpha,
//   而内层自己也有独立 alpha, 内层照样画。
//
// 判据: 类名含 "VisualEffectBackdrop" (系统模糊内核), 且自己带高 alpha 背景色。
// 调淡它的 alpha = 让系统模糊透出底下的 App 画面, 这正是 iOS 26 的观感。
- (NSArray<UIView *> *)systemBlurVeilsInHost:(UIView *)host {
    if (!host) return @[];
    NSMutableArray<UIView *> *found = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:host];
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 4000) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!current) continue;

        NSString *name = NSStringFromClass(current.class);
        if ([name containsString:@"VisualEffectBackdrop"]) {
            // 只收「自己糊了浓白底」的那些。若哪天系统改成不糊底了(alpha 已经很低),
            // 就不必动它 —— 动了反而会把它本来就有的模糊也一起弄没。
            //
            // 【为什么用 getRed: 而不是 getWhite:】getWhite: 只对**灰度空间**的
            // 颜色有效, 遇到纯 RGB 颜色会返回 NO —— 那就等于这层被漏掉,
            // 改完版本用户反馈「还是没效果」。两个都试一遍, 拿 alpha 就行。
            UIColor *bg = current.backgroundColor;
            CGFloat a = 0.0;
            if (bg) {
                CGFloat r = 0, g = 0, b = 0;
                if ([bg getRed:&r green:&g blue:&b alpha:&a]) {
                    // 已取到
                } else if (![bg getWhite:NULL alpha:&a]) {
                    a = 0.0;   // 真的取不到就当没有
                }
            }
            if (a > 0.25) {
                [found addObject:current];
            }
        }
        // 这里**不能** continue: 必须继续往下钻, 因为外层没有 BackgroundColor,
        // 内层才有。我们要的就是内层这个。
        [queue addObjectsFromArray:current.subviews];
    }
    return found;
}

// 找出**按键区自带的那些不透明底板层**, 整组返回。
//
// 【v0.6.0 新增, 「按键区不透明」的唯一解法】
//
// 用户的原话是「按键区不透明」。这是一个**独立于玻璃插入位置**的问题:
// 按键区容器 (_UIKBCompatInputView) 子树里压着一层不透明底板, 而它:
//   1) 类名里既没有 "Backdrop" 也不带 backgroundColor -> backdropInHost: 选不中
//   2) 面积跟整个按键区一样大, 且压在玻璃层**上面**
// 于是玻璃插在按键之下时, 键缝透出玻璃, 按键区自己那块实色仍然盖在玻璃上 ——
// 观感就是「背景变了, 按键区没变」。v0.4.2 就记过这件事, 一直没解决。
//
// 【为什么用「整组」而不是「挑一层」—— 探针实锤, 别再改回去】
// 2026-10-02 13:48 稳定态全树 (a=alpha h=hidden bg=backgroundColor):
//   _UIKBCompatInputView {{0,45},{430,243}} bg=-
//     UIKeyboardAutomatic -> UIKeyboardImpl -> UIKeyboardLayoutStar
//       UIKBKeyplaneView {{0,0},{430,243}} bg=-
//         UIKBSplitImageView {{0,0},{430,243}} h=1  -> UIImageView
//         UIKBSplitImageView {{0,0},{430,243}} h=0  -> UIImageView
//         UIKBSplitImageView {{0,0},{430,243}} h=0  -> UIImageView
//         UIKBKeyView x5
// 三个关键事实:
//   a) 从容器到 Keyplane, **每一层 bg=-**, 一层背景色都没有
//      —— 说明按键区的实色是**画出来的**(SplitImageView 里的 UIImageView),
//         不是 backgroundColor。这也解释了为什么「藏 backgroundColor」这条路
//         注定无效: 根本没有 backgroundColor 可藏。
//   b) **三张 SplitImageView 面积完全相同**(都 430x243), 「挑面积最大的」
//      等于靠遍历顺序碰运气, 而第一张 h=1 是隐藏的 —— 挑中它就等于什么都没做。
//   c) 它们是 **UIKBKeyView 的兄弟**, 不是按键的祖先
//      —— 所以调淡它们的 alpha 不会连带把按键调淡, 触摸也不受影响
//         (UIKBKeyView 自己 uie=0, 真实触摸由系统自己在更低层处理)。
//
// 【为什么不用「把玻璃盖到按键之上」那个办法 —— 它已被实测否掉两次】
// v0.2.0 (纯 CALayer) 和 v0.5.2 (UIView + userInteractionEnabled=NO) 两次实测
// 「打开就不能打字」。所以 v0.6.0 **彻底删掉 GlassOverKeys 开关**。
// 正确做法是反过来: **玻璃留在按键之下(安全), 单独把那层底色调淡**。
//
// 判据: 在按键区容器子树里, 找**不含按键内容**、且面积 >= 按键区 60% 的层, 全都要。
- (NSArray<UIView *> *)keyplaneBackdropsInHost:(UIView *)host {
    UIView *keyLayer = [self firstKeyLayerInHost:host];
    if (!keyLayer) return @[];

    // 按键区的顶层容器 = 按键层在宿主下的那个祖先
    UIView *keyContainer = [self ancestorOf:keyLayer under:host];
    if (!keyContainer) return @[];

    CGFloat containerArea = keyContainer.frame.size.width * keyContainer.frame.size.height;
    if (containerArea <= 0) return @[];

    NSMutableArray<UIView *> *found = [NSMutableArray array];
    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:keyContainer];
    NSUInteger guard = 0;
    while (queue.count > 0 && guard++ < 500) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];
        if (!current) continue;

        // 容器自己不算 —— 要找的是容器**里面**那些底板
        if (current != keyContainer) {
            // 肚子里有按键的一律不能碰: 那可能是按键的包装层, 调淡了按键跟着淡
            if (!KGContainsKeyboardContent(current, 0)) {
                CGFloat area = current.frame.size.width * current.frame.size.height;
                // 面积门槛: 只处理跟按键区差不多大的那些层, 排除零碎小色块
                if (area >= containerArea * 0.6) {
                    [found addObject:current];
                }
                continue;   // 命中即止, 不往里钻 (底板层自己肚子里不会有第二层底板)
            }
        }
        [queue addObjectsFromArray:current.subviews];
    }
    return found;
}

#pragma mark - 安装与拆卸

// 把玻璃视图插到宿主里。**是 subview, 不是 layer。**
//
//
// 把玻璃视图插到宿主里。**永远在按键之下, 没有例外。**
//
// 【v0.6.0 重大简化】v0.4.2~v0.5.2 有一个 GlassOverKeys 开关, 控制玻璃插在
// 按键之下还是之上。这个方向**已被实测否掉两次**:
//   v0.2.0 (纯 CALayer):     打开就「打不了字」
//   v0.5.2 (UIView + uie=NO): 打开仍然「打不了字」
// 两次架构完全不同, 结论却一样 —— 说明「玻璃盖住按键」这条路本身走不通,
// 不是某一行实现写错了。所以 v0.6.0 把这个开关整个删掉, 不再试第三遍。
//
// 【那「按键区不透明」怎么办】—— 换方向解决:
//   玻璃留在按键之下(安全, 实测能打字), 单独把按键区自带的那层不透明底色调淡。
//   按键自己还在, 只是它脚下的底色透明了, 玻璃从键缝透上来。
//   见 keyplaneBackdropInHost:。
//
// 【为什么「显式 userInteractionEnabled=NO」也挡不住】—— 写清楚, 免得以后
// 又有人拿「机制上不可能」当依据:
//   UIKit 确实保证 hitTest 跳过 uie=NO 的视图。但 iOS 键盘的触摸**不完全走
//   UIView 的 hitTest 派发** —— v0.2.2 早就实测到「键盘区域 hitTest 全部返回
//   nil」, 说明系统另有路由。既然如此, 玻璃插在按键**上方**时, 玻璃的模糊/
//   遮罩效果本身就会改变系统对按键的命中判定 (屏幕上「点在玻璃上」,
//   系统据此找不到下层按键)。
//   **「机制上不可能」不等于「实测不会」—— 这已经是第三次栽在这句话上。**
- (void)placeGlassInHost:(UIView *)host {
    if (!self.glassView) {
        self.glassView = [[KGGlassView alloc] initWithFrame:host.bounds];
        self.hasAppliedStyle = NO;
    }

    if (!CGRectEqualToRect(self.glassView.frame, host.bounds)) {
        self.glassView.frame = host.bounds;
    }

    UIView *fg = [self firstKeyLayerInHost:host];

    // 【v0.7.2 改: 撤掉 v0.7.1 的 insertSubview:atIndex:0「暂驻底部」】
    //
    // v0.7.1 这么改的动机是: 收起态里 firstKeyLayerInHost: 返回 nil, 旧代码
    // 会把玻璃撤出宿主, 而展开动画结束时 layoutSubviews 不再被调, 没人来重装
    // —— 探针里 21 次采样有 12 次 glassViewIdx=NSNotFound, 用户看到的就是
    // 「压根没有玻璃」。**动机是对的, 解法是错的。**
    //
    // 错在哪: 玻璃常驻宿主之后, 它的 frame 就成了宿主布局的一个自变量:
    //   我们按宿主尺寸写玻璃 frame -> 宿主重排 -> 尺寸变了 -> 我们再写 …
    // 两个布局解互相拉扯, 乒乓不收敛。v0.7.1 探针里同一秒 25 次采样,
    // 宿主 frame 在 {{0,932},{430,243}} 与 {{0,857},{430,75}} 之间来回跳,
    // 75513 行 dock 视图 dump —— **键盘被卡死在展开动画里, 所以打不了字。**
    //
    // 正确解法: 找不到按键就**老实撤掉**。「展开后装不回来」这个死锁由
    // 定时器解决(见 kg_workerTick)—— 它每 0.4s 主动检查一次, 不依赖
    // 「有没有人恰好在那一刻调 layoutSubviews」。用一个轮询解决时序问题,
    // 比在视图树里做时间假设稳得多。
    if (!fg) {
        if (self.glassView.superview) {
            KGLog(@"按键层未就位, 撤掉玻璃: host=%@ subviews=%lu",
                  NSStringFromClass(host.class), (unsigned long)host.subviews.count);
            [self.glassView removeFromSuperview];
        }
        self.glassView.hidden = YES;
        return;
    }
    // insertSubview:belowSubview: 要求 sibling 关系。fg 可能是宿主的孙辈,
    // 直接用它会抛异常 —— 必须先取它在宿主下的那个祖先。
    UIView *anchor = [self ancestorOf:fg under:host];
    if (!anchor) {
        if (self.glassView.superview) [self.glassView removeFromSuperview];
        self.glassView.hidden = YES;
        return;
    }

    if (self.glassView.superview != host) {
        [host insertSubview:self.glassView belowSubview:anchor];
        KGLog(@"玻璃视图入位: host=%@ subviews=%lu anchor=%@",
              NSStringFromClass(host.class), (unsigned long)host.subviews.count,
              NSStringFromClass(anchor.class));
        return;
    }

    // 已在宿主里: 平时绝不动它 (避免触发布局反馈循环), 只在 z 序与目标不符时纠正。
    NSUInteger currentIndex = [host.subviews indexOfObject:self.glassView];
    if (currentIndex == NSNotFound) return;

    NSInteger targetIndex = (NSInteger)[host.subviews indexOfObject:anchor];
    if (targetIndex == (NSInteger)NSNotFound) return;
    if (targetIndex < 0) targetIndex = 0;
    if (targetIndex > (NSInteger)host.subviews.count - 1) {
        targetIndex = (NSInteger)host.subviews.count - 1;
    }

    if ((NSInteger)currentIndex != targetIndex) {
        KGLog(@"玻璃视图 z 序需纠正: %lu -> %ld",
              (unsigned long)currentIndex, (long)targetIndex);
        [host insertSubview:self.glassView belowSubview:anchor];
    }
}

// 从 view 往上找到 host 那一层祖先 (host 的直接孩子)。找不到返回 nil。
// insertSubview:belowSubview: 只接受兄弟, 拿不到这一层就不能插。
- (UIView *)ancestorOf:(UIView *)view under:(UIView *)host {
    if (!view || !host) return nil;
    UIView *cur = view;
    NSUInteger guard = 0;
    while (cur && guard++ < 40) {
        if (cur.superview == host) return cur;
        if (cur == host) return nil;
        cur = cur.superview;
    }
    return nil;
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
    // v0.6.0: 按键区底色的调淡**不在这里**做 —— 它是独立的一件事, 由
    // enforceKeyplaneBackdropInHost: 负责, 且 Glass 档也要做。
}

// 调淡按键区自带的那些底板层 —— 「按键区不透明」的解法。
//
// v0.6.0 新增。这个与上面藏主体背景是**两件不同的事**:
//   主体背景 (UIKBBackdropView)  = 键盘整体那块底, 藏掉它玻璃能透出 App
//   按键区底板 (SplitImageView)   = 按键区自己脚下那块, 调淡它按键区才变玻璃
// 用户反馈「按键区不透明」指的是**后者**, v0.4.2 就记录过这个问题, 一直没解决。
//
// 【为什么用「调淡」而不是「藏掉」】—— 藏掉(alpha=0)实测会哑掉触摸
// (v0.4.0「又不能点击了」)。调淡成 0.25 而不是 0: 视觉上足够透
// (玻璃能透上来), 但整棵子树仍在, 按键照常响应。
//
// 【为什么可以整组一起调】—— 探针实锤这三张 SplitImageView 是 UIKBKeyView 的
// **兄弟**而不是祖先, 所以调淡它们不会连带调淡按键, 也不影响按键的触摸。
- (void)enforceKeyplaneBackdropInHost:(UIView *)host {
    if (!self.hiddenBackdrops) {
        self.hiddenBackdrops = [NSMapTable weakToStrongObjectsMapTable];
    }

    // 整组重选的条件: 从没选过, 或者**任何一个**离树了(键盘重建会换一批视图)。
    // 少了「任何一个」这个条件就会漏 —— 三张图可能只重建了两张。
    BOOL needReselect = NO;
    if (!self.cachedKeyplaneBackdrops) {
        needReselect = YES;
    } else {
        for (UIView *v in self.cachedKeyplaneBackdrops) {
            if (!v.superview) { needReselect = YES; break; }
        }
    }

    if (needReselect) {
        self.cachedKeyplaneBackdrops = [[self keyplaneBackdropsInHost:host] mutableCopy];
        for (UIView *v in self.cachedKeyplaneBackdrops) {
            [self.hiddenBackdrops setObject:@(v.alpha) forKey:v];
        }
        if (self.cachedKeyplaneBackdrops.count > 0) {
            KGLog(@"锁定按键区底板 %lu 层: %@",
                  (unsigned long)self.cachedKeyplaneBackdrops.count,
                  [[self.cachedKeyplaneBackdrops valueForKey:@"class"] componentsJoinedByString:@","]);
        } else {
            KGLog(@"没找到可调淡的按键区底板层");
        }
    }

    // 0 = 完全不动 (保持系统原样), 1 = 只留底色保证触摸与字都正常
    //
    // ============================ v0.7.3 关键修正 ============================
    // 2026-10-03 用户实测: 「只要唤出键盘, 就点不了键盘以外的东西了」。
    // 原代码是 `origin * (1.0 - MIN(0.85, strength))`, 滑块拉满时只留 15%。
    //
    // 【为什么 15% 会让整个键盘窗口点不动】—— 这三张 UIKBSplitImageView
    // 不是装饰, 它们是**按键区整块区域的实体底板**, iOS 键盘的触摸派发
    // 落在底板上。底板 alpha 压到 15% 之后, 命中测试判定整块区域「不算实体」,
    // 于是从按键区一直往上, **整个键盘窗口都失去响应** —— 表现就是
    // 「键盘能显示、能打字(按键自己走另一条路由), 但键盘以外的任何东西都点不到」。
    //
    // 注意这里的误判代价: 我第一反应是「玻璃挡了触摸」(玻璃一直好好的,
    // userInteractionEnabled=NO), 探针里 veilDesc=none 61 次全中直接推翻了它。
    // **别把触摸问题默认归给「那个新加的视图」, 先确认它到底有没有被改过。**
    //
    // 下限取 0.55: 观感上仍然明显透出玻璃(45% 透明), 但实体层足够撑住
    // 命中判定。这是从 v0.7.0 的 0.15 一步提到 0.55 的原因。
    CGFloat strength = [KGPrefs keyplaneDim];
    for (UIView *kb in self.cachedKeyplaneBackdrops) {
        if (!kb.superview) continue;
        NSNumber *origin = [self.hiddenBackdrops objectForKey:kb];
        if (!origin) continue;

        CGFloat target = origin.doubleValue;
        if (strength > 0.001) {
            CGFloat keep = MAX(kKGTouchSafeFloor, 1.0 - MIN(0.85, strength));
            target = origin.doubleValue * keep;
        }
        if (fabs(kb.alpha - target) > 0.001) {
            kb.alpha = target;
        }
    }
}

// 调淡系统毛玻璃自己糊的那层浓白底 —— 「键盘实心浅灰」的真正解法。
//
// v0.7.0 新增。**这个才是元凶**, 前面五个版本全在调别的东西:
//
//   _UIVisualEffectBackdropView bg=1.00/1.00/1.00/0.85
//
// 它是系统自己的模糊层, 自带 85% 浓白。调淡它 = 键盘整体透出底下的 App 画面,
// 观感上就是 iOS 26 那种「键盘浮在 App 上、内容隐约可见」的样子。
//
// 【为什么必须调 alpha 而不是换 effect】—— 换成 UIBlurEffect 的其他档位
// 只会换掉模糊半径, 换不掉那 85% 白底(它跟着 UIBlurEffect 一起生成)。
// 要让白色退下去, 只能动 alpha。
//
// 【为什么留 0.06 而不是归零】—— 归零会让这层子树退出 hitTest,
// v0.4.0 实测「又不能点击了」。留一点点既透得过去, 子树也还在。
- (void)enforceSystemBlurVeilInHost:(UIView *)host {
    if (!self.hiddenBackdrops) {
        self.hiddenBackdrops = [NSMapTable weakToStrongObjectsMapTable];
    }

    BOOL needReselect = NO;
    if (!self.cachedBlurVeils) {
        needReselect = YES;
    } else {
        for (UIView *v in self.cachedBlurVeils) {
            if (!v.superview) { needReselect = YES; break; }
        }
    }

    if (needReselect) {
        self.cachedBlurVeils = [[self systemBlurVeilsInHost:host] mutableCopy];
        for (UIView *v in self.cachedBlurVeils) {
            [self.hiddenBackdrops setObject:@(v.alpha) forKey:v];
        }
        if (self.cachedBlurVeils.count > 0) {
            KGLog(@"锁定系统毛玻璃白底 %lu 层: %@",
                  (unsigned long)self.cachedBlurVeils.count,
                  [[self.cachedBlurVeils valueForKey:@"class"] componentsJoinedByString:@","]);
        } else {
            KGLog(@"没找到系统毛玻璃白底层");
        }
    }

    CGFloat strength = [KGPrefs keyplaneDim];
    if (strength <= 0.001) return;   // 拖到 0 = 完全保持系统原样

    for (UIView *v in self.cachedBlurVeils) {
        if (!v.superview) continue;
        NSNumber *origin = [self.hiddenBackdrops objectForKey:v];
        if (!origin) continue;
        // 最多只留 6% 底色。再高就又变回「实心浅灰」了。
        CGFloat target = origin.doubleValue * (1.0 - MIN(0.94, strength));
        if (fabs(v.alpha - target) > 0.001) {
            v.alpha = target;
        }
    }
}

- (void)applyStyleForMaterial:(KGMaterial)material {
    if (!self.glassView) return;
    BOOL dark = (self.hostView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    KGStyle style = [KGPrefs styleForMaterial:material dark:dark];
    BOOL outline = [KGPrefs showLayerOutline];
    if (self.hasAppliedStyle && KGStyleEqual(style, self.appliedStyle)
        && self.glassView.showOutline == outline) {
        return;
    }
    self.appliedStyle = style;
    self.hasAppliedStyle = YES;
    self.glassView.showOutline = outline;
    [self.glassView applyStyle:style dark:dark];
}

- (void)writeInstallProbeWithHost:(UIView *)host material:(KGMaterial)material mode:(KGWorkMode)mode {
    UIView *fg = KGModeShowsGlass(mode) ? [self firstKeyLayerInHost:host] : nil;
    // v0.5.0: 玻璃从 layer 变成 view, 下标要在 subviews / sublayers 两边都记一份。
    // 两边对不上就说明 view 树和 layer 树不同步, 那正是「看不见」的高发场景。
    NSInteger vi = self.glassView ? [host.subviews indexOfObject:self.glassView] : NSNotFound;
    NSInteger li = self.glassView ? [host.layer.sublayers indexOfObject:self.glassView.layer] : NSNotFound;
    NSInteger fi = fg ? [host.subviews indexOfObject:[self ancestorOf:fg under:host]] : NSNotFound;

    // 【v0.7.1 新增】玻璃位置的**明确判据**, 不再让读日志的人自己推。
    //
    // v0.7.0 的探针里 glassViewIdx 出现两种值: 一个真实下标, 一个 9223372036854775807
    // —— 后者就是 NSNotFound 泄漏成整数(NSUIntegerMax 转 NSInteger 的结果)。
    // 光看这一串数字判断不出「是没装上去」还是「装上了但被撤了」。
    // 这里换成人话:
    //   absent  = 玻璃根本不在宿主里
    //   bottom  = 在最底下(按键层这轮没找到, 下轮会重装)
    //   underKeys = 装在按键区之下 ← 正常工作的状态
    //   OVERKEYS = 压在按键区之上 ← 有问题
    NSString *glassPos = @"absent";
    if (self.glassView && self.glassView.superview == host && vi != NSNotFound) {
        if (fi != NSNotFound) {
            glassPos = (vi < fi) ? @"underKeys" : @"OVERKEYS";
        } else {
            glassPos = (vi == 0) ? @"bottom" : [NSString stringWithFormat:@"idx%ld", (long)vi];
        }
    }

    // 被锁定的那一层背景 (v0.4.1 起恒为单层)
    UIView *bg = self.cachedBackdrop;
    NSNumber *bgOrigin = bg ? [self.hiddenBackdrops objectForKey:bg] : nil;
    NSString *bgDesc = bg
        ? [NSString stringWithFormat:@"%@(%@,origin=%.2f,now=%.2f)",
           NSStringFromClass(bg.class), NSStringFromCGRect(bg.frame),
           bgOrigin ? bgOrigin.doubleValue : -1.0, bg.alpha]
        : @"none";

    // v0.6.0: 按键区底板层的状态。「按键区不透明」就看这一行 ——
    // keyBg= 不是 none 说明找到了并调淡了, 还是 none 说明压根没找到那层底板。
    // 探针实锤是整组(3 张 UIKBSplitImageView), 所以这里报**逐层**明细,
    // 而且带 h= —— 因为其中一张 h=1, 只报「找到 1 层」会误判成没生效。
    NSMutableString *kbDesc = [NSMutableString string];
    for (UIView *kb in self.cachedKeyplaneBackdrops) {
        NSNumber *kbOrigin = [self.hiddenBackdrops objectForKey:kb];
        [kbDesc appendFormat:@"%@(%@,origin=%.2f,now=%.2f,h=%d) ",
           NSStringFromClass(kb.class), NSStringFromCGRect(kb.frame),
           kbOrigin ? kbOrigin.doubleValue : -1.0, kb.alpha, kb.hidden ? 1 : 0];
    }
    if (kbDesc.length == 0) [kbDesc appendString:@"none"];

    // v0.7.0: 系统毛玻璃那层浓白底的状态。「键盘实心浅灰」就看这一行 ——
    // veilDesc= 不是 none 且 now 明显小于 origin, 说明那 85% 白底已经被调淡了。
    NSMutableString *veilDesc = [NSMutableString string];
    for (UIView *v in self.cachedBlurVeils) {
        NSNumber *origin = [self.hiddenBackdrops objectForKey:v];
        CGFloat bgA = 0;
        UIColor *c = v.backgroundColor;
        if (c) {
            CGFloat r = 0, g = 0, b = 0;
            if (![c getRed:&r green:&g blue:&b alpha:&bgA]) {
                if (![c getWhite:NULL alpha:&bgA]) { bgA = 0.0; }
            }
        }
        [veilDesc appendFormat:@"%@(bgA=%.2f,origin=%.2f,now=%.2f) ",
           NSStringFromClass(v.class), bgA,
           origin ? origin.doubleValue : -1.0, v.alpha];
    }
    if (veilDesc.length == 0) [veilDesc appendString:@"none"];

    // v0.7.3: 顶部助手条的状态。「键盘上方那条灰条」就看这一行 ——
    // 期望看到 now=0.00(已藏)。如果 now 还是 1.00, 说明整组没藏干净。
    NSMutableString *barDesc = [NSMutableString string];
    for (UIView *v in self.cachedAssistantBars) {
        NSNumber *origin = [self.hiddenBackdrops objectForKey:v];
        [barDesc appendFormat:@"%@(origin=%.2f,now=%.2f) ",
           NSStringFromClass(v.class), origin ? origin.doubleValue : -1.0, v.alpha];
    }
    if (barDesc.length == 0) [barDesc appendString:@"none"];

    // 玻璃正下方那三层是谁 —— 玻璃是 backdrop, 采样源就在它下面。
    // 如果这几层里有东西仍然不透明, 玻璃就采不到键盘外面的画面。
    //
    // KG_PROBE_CRASH (v0.4.2 安全模式实锤, 优先级最高):
    //   `if (vi > 0)` 挡不住 NSNotFound —— NSNotFound 是 NSUIntegerMax,
    //   强转成 NSInteger 后是 18446744073709551615, 它**大于 0**, 条件照样成立。
    //   于是循环从 i = NSNotFound-1 开始, 拿它去下标 subs 立刻 NSRangeException。
    //   而 vi 恰好在「玻璃不存在」时等于 NSNotFound —— 也就是 Probe 档
    //   (v0.4.1 的默认档!) 每次布局都必崩。崩溃发生在 layoutSubviews 里,
    //   键盘一起就崩 → 反复重启 → 安全模式。
    //   教训: **拿 NSNotFound 当下标用, 不能靠 `> 0` 判**, 必须显式比 NSNotFound。
    NSMutableString *underDesc = [NSMutableString string];
    NSArray<UIView *> *subs = host.subviews;
    if (vi != NSNotFound && vi > 0 && vi <= (NSInteger)subs.count) {
        for (NSInteger i = vi - 1; i >= 0 && i >= vi - 3; i--) {
            UIView *v = subs[(NSUInteger)i];
            [underDesc appendFormat:@"[%ld]%@ a=%.2f h=%d ",
                (long)i, NSStringFromClass(v.class), v.alpha, v.hidden ? 1 : 0];
        }
    }
    if (underDesc.length == 0) [underDesc appendString:@"none"];

    // signature 要把底板层数和真实 alpha 都算进去: v0.6.0 之前只记了类名,
    // 结果「3 张图里只调淡了 1 张」这种状态探针完全看不出来(签名没变就不重写)。
    NSString *signature = [NSString stringWithFormat:@"%@|%@|%@|%ld|%ld|%ld|%ld|%@|%.3f|%lu|%.3f|%@|%@|%@",
        NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        bg ? NSStringFromClass(bg.class) : @"none",
        (long)vi, (long)li, (long)fi, (long)mode,
        kbDesc, bg.alpha,
        (unsigned long)self.cachedKeyplaneBackdrops.count, [KGPrefs keyplaneDim],
        veilDesc, glassPos, barDesc];
    if ([signature isEqualToString:self.lastProbeSignature]) return;
    self.lastProbeSignature = signature;
    // 【v0.7.2】总条数硬闸 400 条。签名去重挡不住「状态一直在变」的情况 ——
    // v0.7.1 宿主 frame 乒乓, 签名每次都不同, 结果单次键盘弹出就写了 17MB /
    // 23.5 万行, 手机发回来时微信都卡。架构修好后签名本该稳定, 但留这道闸
    // 兜底: 探针是诊断手段, 永远不值得把用户的存储和流量吃光。
    if (self.probeCount++ > 400) return;

    KGWriteProbe([NSString stringWithFormat:
        @"[install %@] mode=%ld host=%@ hostFrame=%@ onScreen=%d glassPos=%@ glassViewIdx=%ld/%lu glassLayerIdx=%ld/%lu fg=%@ subIdx=%ld fgDepth=%ld stable=%ld dirty=%d timer=%d\n"
        @"         blurStyle=%.1f effect=%ld refraction=%.1f highlight=%.2f veil=%.2f radius=%.1f outline=%d material=%ld dark=%d keyDim=%.2f\n"
        @"         hiddenBg=%@\n"
        @"         keyBg=%@\n"
        @"         veilDesc=%@\n"
        @"         topBar=%@\n"
        @"         underGlass=%@\n",
        [NSDate date], (long)mode,
        NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        KGIsOnScreen(host), glassPos,
        (long)vi, (unsigned long)host.subviews.count,
        (long)li, (unsigned long)host.layer.sublayers.count,
        fg ? NSStringFromClass(fg.class) : @"none", (long)fi, (long)KGDepthOfView(fg, host),
        (long)self.stableCount, self.dirty ? 1 : 0, self.workerTimer ? 1 : 0,
        self.appliedStyle.blur, (long)self.glassView.activeEffectStyle,
        self.appliedStyle.refraction,
        self.appliedStyle.highlight, self.appliedStyle.veil,
        self.appliedStyle.cornerRadius, [KGPrefs showLayerOutline],
        (long)material, self.appliedStyle.dark, [KGPrefs keyplaneDim],
        bgDesc, kbDesc, veilDesc, barDesc, underDesc]);
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
    // v0.6.0: 按键区底板也要清, 否则它留在缓存里, 下次切档时 enforce 会拿
    // 一批已经不在树上的旧层去写 alpha —— 轻则没效果, 重则报错。
    self.cachedKeyplaneBackdrops = nil;
    // v0.7.0: 同理, 系统毛玻璃白底。
    self.cachedBlurVeils = nil;
    // v0.7.3: 同理, 顶部助手条。
    self.cachedAssistantBars = nil;
}

- (void)teardown {
    if (self.glassView) {
        [self.glassView removeFromSuperview];
        self.glassView = nil;
        self.hasAppliedStyle = NO;
    }
    [self restoreNativeBackdrops];
    self.hostView = nil;
    // 强制下次进来时重新走一遍「模式变化 -> 恢复 -> 重选」, 避免拿旧缓存的层
    // 去写 alpha(teardown 之后视图已经被系统回收了)。
    self.lastAppliedMode = (KGWorkMode)-1;
}

@end
