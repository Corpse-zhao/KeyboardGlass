#import "KGKeyboardInstaller.h"
#import "KGGlassView.h"
#import "KGPrefs.h"
#import <sys/stat.h>

// 探针写盘(熔断器要先用它, 所以前置声明)
static void KGWriteProbe(NSString *content);

// 样式比较: 玻璃层只在这几个数变了的时候才需要重设, 否则每 0.4s 重建一次
// UIVisualEffectView 会白白丢掉内核缓存的模糊结果, 观感反而更糙。
// 差值用 0.01 兜住浮点噪声 —— 用户拖滑块时的值本来就带小数。
static inline BOOL KGStyleEqual(KGStyle a, KGStyle b) {
    return fabs(a.blur - b.blur) < 0.01
        && fabs(a.refraction - b.refraction) < 0.01
        && fabs(a.highlight - b.highlight) < 0.01
        && fabs(a.veil - b.veil) < 0.01
        && fabs(a.cornerRadius - b.cornerRadius) < 0.01
        && a.dark == b.dark;
}

#pragma mark - 崩溃熔断器

static const NSInteger kKGCrashThreshold = 5;
static const NSTimeInterval kKGCrashWindow = 600.0;
static NSString * const kKGCrashCountKey = @"CrashCount";
static NSString * const kKGCrashLastKey  = @"CrashLastTime";
static NSString * const kKGCircuitOpenKey = @"CircuitOpen";

@implementation KGKeyboardInstaller

+ (void)noteHandledException:(NSException *)exception where:(NSString *)where {
    @try {
        NSUserDefaults *d = [KGPrefs defaults];
        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        NSTimeInterval last = [d doubleForKey:kKGCrashLastKey];
        NSInteger count = [d integerForKey:kKGCrashCountKey];
        if (last <= 0 || (now - last) > kKGCrashWindow) count = 0;
        count += 1;
        [d setInteger:count forKey:kKGCrashCountKey];
        [d setDouble:now forKey:kKGCrashLastKey];
        if (count >= kKGCrashThreshold) {
            [d setBool:YES forKey:kKGCircuitOpenKey];
            KGWriteProbe([NSString stringWithFormat:
                @"[熔断] %@ 第 %ld 次异常, 插件已停用: %@\n",
                where, (long)count, exception.reason]);
        }
        [d synchronize];
    } @catch (NSException *ignored) {
        // 熔断器自己绝不能成为崩溃源
    }
}

+ (BOOL)isCircuitOpen {
    return [[KGPrefs defaults] boolForKey:kKGCircuitOpenKey];
}

+ (void)resetCircuit {
    NSUserDefaults *d = [KGPrefs defaults];
    [d removeObjectForKey:kKGCrashCountKey];
    [d removeObjectForKey:kKGCircuitOpenKey];
    [d synchronize];
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

#pragma mark - 视图判定 —— 全部基于探针实测

static NSInteger KGDepthOf(UIView *view, UIView *root) {
    if (!view || !root) return -1;
    NSInteger depth = 0;
    UIView *cur = view;
    NSUInteger guard = 0;
    while (cur && cur != root && guard++ < 60) {
        cur = cur.superview;
        depth++;
    }
    return (cur == root) ? depth : -1;
}

// 键盘宿主视图
static BOOL KGIsHost(UIView *v) {
    if (!v || !v.superview) return NO;
    NSString *n = NSStringFromClass(v.class);
    return [n containsString:@"InputSetHost"];
}

// 在屏
static BOOL KGIsOnScreen(UIView *v) {
    if (!v || !v.window) return NO;
    CGRect inWindow = [v convertRect:v.bounds toView:v.window];
    CGRect vis = CGRectIntersection(inWindow, v.window.bounds);
    if (CGRectIsNull(vis) || CGRectIsEmpty(vis)) return NO;
    CGFloat full = v.bounds.size.width * v.bounds.size.height;
    if (full <= 0) return NO;
    return (vis.size.width * vis.size.height) >= full * 0.6;
}

// 键盘尺寸: 宽度接近整屏, 面积 >= 屏宽 x 150
static BOOL KGIsKeyboardSized(UIView *v) {
    if (!v || !v.superview) return NO;
    CGFloat sw = v.window.bounds.size.width;
    if (sw <= 0) sw = UIScreen.mainScreen.bounds.size.width;
    if (sw <= 0) return NO;
    if (v.frame.size.width < sw * 0.85) return NO;
    return (v.frame.size.width * v.frame.size.height) >= sw * 150.0;
}

// ======================================================================
// 【v1.0.0 唯一的选层铁律】只允许挑中 userInteractionEnabled == 0 的层
// ======================================================================
// 理由见头文件: uie=0 的层不在 hitTest 链路里, 改它的 alpha 在机制上
// 不可能影响点击。十一版里七版在调UIKBSplitImageView(实测 uie=0),
// 全部无效 —— 这条铁律把那七版的无用功一次性归零。
//
// 注意: uie=0 **不等于** 可以为所欲为。仍然要检查:
//   - 该层不能是按键层的祖先(否则按键跟着一起淡)
//   - 面积要大到能遮住目标区域
//   - 要整组处理, 不能只动一半
static BOOL KGPickable(UIView *v, UIView *keyLayer) {
    if (!v) return NO;
    // 【核心】必须 uie=0。uie=1 的层一律不碰。
    if (v.userInteractionEnabled) return NO;

    // 不能是按键层的祖先 —— 否则连按键一起淡掉
    UIView *cur = keyLayer;
    NSUInteger guard = 0;
    while (cur && guard++ < 40) {
        if (cur == v) return NO;
        cur = cur.superview;
    }
    return YES;
}

// 把按键区底下的按键层找出来(BFS, 第一个命中就是最靠上的祖先)
static UIView *KGKeyLayerIn(UIView *host) {
    if (!host) return nil;
    NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:host];
    NSUInteger guard = 0;
    while (q.count > 0 && guard++ < 4000) {
        UIView *cur = q.firstObject;
        [q removeObjectAtIndex:0];
        NSMutableArray<UIView *> *next = [NSMutableArray array];
        for (UIView *sub in cur.subviews) {
            NSString *n = NSStringFromClass(sub.class);
            if ([n containsString:@"Keyplane"] || [n containsString:@"KeyboardLayout"]) {
                return sub;
            }
            [next addObject:sub];
        }
        [q addObjectsFromArray:next];
    }
    return nil;
}

#pragma mark -

@interface KGKeyboardInstaller ()
- (void)refreshWithHost:(UIView *)host;

@property (nonatomic, strong) KGGlassView *glassView;
@property (nonatomic, weak)   UIView *hostView;

// 被我们改过 alpha 的层 -> 原始 alpha (弱键 + 恢复表)
@property (nonatomic, strong) NSMapTable<UIView *, NSNumber *> *touchedLayers;

// 每类动作各自缓存, 键盘重建时按需重选
@property (nonatomic, strong) NSMutableArray<UIView *> *veilLayers;    // d4/d5 系统浓白
@property (nonatomic, strong) NSMutableArray<UIView *> *barLayers;     // d2/d4 顶部 45pt 助手条
@property (nonatomic, strong) NSMutableArray<UIView *> *keyBottomLayers; // 按键区底板(纯视觉)
@property (nonatomic, weak)   UIView *fullscreenWhiteView;             // _UIRemoteView 全屏白底

@property (nonatomic, assign) BOOL hasAppliedStyle;
@property (nonatomic, assign) KGStyle appliedStyle;
@property (nonatomic, assign) BOOL didDumpTree;
@property (nonatomic, assign) NSUInteger probeCount;
@property (nonatomic, copy)   NSString *lastSignature;

// 观测 -> 定时器
@property (nonatomic, weak)   UIView *seenHostView;
@property (nonatomic, weak)   UIView *seenContainerView;
@property (nonatomic, assign) BOOL dirty;
@property (nonatomic, strong) NSTimer *workerTimer;
@property (nonatomic, assign) CGRect lastSampledFrame;
@property (nonatomic, assign) NSInteger stableCount;
@end

@implementation KGKeyboardInstaller

+ (instancetype)shared {
    static KGKeyboardInstaller *shared = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [[KGKeyboardInstaller alloc] init]; });
    return shared;
}

#pragma mark - 布局回调(只观测)

- (void)noteHostLayout:(UIView *)host {
    if (!host) return;
    self.seenHostView = host;
    self.dirty = YES;
}

- (void)noteContainerLayout:(UIView *)root {
    if (!root) return;
    self.seenContainerView = root;
    self.dirty = YES;
}

#pragma mark - 定时器(唯一动手的地方)

- (void)startWorker {
    if (self.workerTimer) return;
    self.workerTimer = [NSTimer scheduledTimerWithTimeInterval:0.4
                                                      target:self
                                                    selector:@selector(workerTick:)
                                                    userInfo:nil
                                                     repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:self.workerTimer forMode:NSRunLoopCommonModes];
    KGLog(@"v1.0.0 已启动: 0.4s 定时器, 稳定性闸=连续2帧相同");
    KGLog(@"v1.0.0 铁律: 只改 userInteractionEnabled=0 的层 —— 原理上不可能影响点击");
    KGLog(@"v1.0.0 重启: 按键区底板调淡(删除 0.55 触摸下限, 实测该层 uie=0 本就与触摸无关)");
    KGLog(@"v1.0.0 停用: 工作模式二分隔离(改按 uie 判据单线选层, 不再需要档位)");
}

- (void)workerTick:(NSTimer *)timer {
    if ([KGKeyboardInstaller isCircuitOpen]) return;
    @try {
        [self kg_workerTick];
    } @catch (NSException *e) {
        [KGKeyboardInstaller noteHandledException:e where:@"workerTick"];
    }
}

- (void)kg_workerTick {
    // 宿主不在 -> 先试着从容器里找(某些版本 hook 不触发)
    if (!self.seenHostView || !self.seenHostView.superview) {
        UIView *root = self.seenContainerView;
        if (root) {
            NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:root];
            NSUInteger guard = 0;
            while (q.count > 0 && guard++ < 3000) {
                UIView *cur = q.firstObject;
                [q removeObjectAtIndex:0];
                if (KGIsHost(cur) && KGIsKeyboardSized(cur) && KGIsOnScreen(cur)) {
                    self.seenHostView = cur;
                    self.dirty = YES;
                    self.lastSampledFrame = CGRectNull;
                    self.stableCount = 0;
                    break;
                }
                [q addObjectsFromArray:cur.subviews];
            }
        }
    }

    UIView *host = self.seenHostView;
    if (!host || !host.superview) {
        if (self.glassView.superview) [self teardown];
        self.dirty = NO;
        return;
    }

    // 稳定性闸: 连续两次 frame 相同才动手, 动画期一律不碰。
    // (v0.7.2 定论: 在布局回调里改视图树会形成不收敛的乒乓, 把键盘卡死)
    CGRect frame = host.frame;
    if (!CGRectEqualToRect(frame, self.lastSampledFrame)) {
        self.lastSampledFrame = frame;
        self.stableCount = 1;
        return;
    }
    if (self.stableCount < 2) { self.stableCount++; return; }

    // 收起 -> 彻底恢复, 并关掉全屏白底
    if (!KGIsKeyboardSized(host) || !KGIsOnScreen(host)) {
        if (self.glassView.superview) [self.glassView removeFromSuperview];
        [self restoreAll];
        // v1.0.0: 键盘不在屏幕上时, 那个 932pt 全屏白底必须关掉。
        // 它 uie=0, 关掉不影响任何手势 —— 纯粹是视觉残留。
        [self setFullscreenWhiteHidden:YES];
        self.hostView = nil;
        self.dirty = NO;
        self.stableCount = 0;
        self.lastSampledFrame = CGRectNull;
        return;
    }

    if (!self.dirty && self.glassView.superview) return;
    self.dirty = NO;

    [self refreshWithHost:host];
}

#pragma mark - 主流程

- (void)refreshWithHost:(UIView *)host {
    if ([KGKeyboardInstaller isCircuitOpen]) return;
    @try {
        [self kg_refresh:host];
    } @catch (NSException *e) {
        [KGKeyboardInstaller noteHandledException:e where:@"refresh"];
    }
}

- (void)kg_refresh:(UIView *)host {
    KGMaterial material = [KGPrefs material];
    if (material == KGMaterialOff) { [self teardown]; return; }

    // 换宿主: 恢复旧层 + 清缓存
    if (self.hostView != host) {
        KGLog(@"锁定宿主 %@ frame=%@",
              NSStringFromClass(host.class), NSStringFromCGRect(host.frame));
        [self.glassView removeFromSuperview];
        [self restoreAll];
        self.hostView = host;
        self.didDumpTree = NO;
        self.lastSignature = nil;
        self.probeCount = 0;
        [self dumpTreeForHost:host];
    }

    [self placeGlass:host];
    self.glassView.hidden = NO;
    [self applyStyle:material];

    // ---- 四个动作, 每个都只作用在 uie=0 的层上 ----
    [self applyVeilLayersInHost:host];
    [self applyAssistantBar:host];
    [self applyKeyBottomDim:host];
    [self applyFullscreenWhite:host];

    [self writeProbe:host material:material];
}

#pragma mark - 1. 玻璃层(uie=0)

- (void)placeGlass:(UIView *)host {
    if (!self.glassView) {
        self.glassView = [[KGGlassView alloc] initWithFrame:host.bounds];
        self.hasAppliedStyle = NO;
    }
    if (!CGRectEqualToRect(self.glassView.frame, host.bounds)) {
        self.glassView.frame = host.bounds;
    }

    // 锚点: 按键层的祖先。玻璃必须在按键**之下**, 这是十一版唯一没翻车的做法。
    UIView *key = KGKeyLayerIn(host);
    if (!key) {
        // 找不到按键层就不插。宁可没玻璃, 也不能盖住按键。
        if (self.glassView.superview) [self.glassView removeFromSuperview];
        self.glassView.hidden = YES;
        return;
    }
    UIView *anchor = key;
    UIView *cur = key;
    NSUInteger guard = 0;
    while (cur && cur.superview && cur.superview != host && guard++ < 40) {
        cur = cur.superview;
    }
    anchor = (cur && cur.superview == host) ? cur : key;

    if (self.glassView.superview != host) {
        if ([anchor isDescendantOfView:host] && anchor != host) {
            [host insertSubview:self.glassView belowSubview:anchor];
            KGLog(@"玻璃视图入位: anchor=%@", NSStringFromClass(anchor.class));
        } else {
            [host insertSubview:self.glassView atIndex:0];
            KGLog(@"玻璃视图入位: 兜底置底 anchor=%@", NSStringFromClass(anchor.class));
        }
    }
}

- (void)applyStyle:(KGMaterial)material {
    KGStyle st = [KGPrefs styleForCurrentMaterialDark:YES];
    if (self.hasAppliedStyle
        && KGStyleEqual(st, self.appliedStyle)) {
        return;
    }
    self.appliedStyle = st;
    self.hasAppliedStyle = YES;
    [self.glassView applyStyle:st dark:YES];
}

#pragma mark - 2. 系统浓白veil (d5/d4, uie=0) —— 键盘「实心浅灰」的真凶

- (void)applyVeilLayersInHost:(UIView *)host {
    UIView *key = KGKeyLayerIn(host);
    if (!self.veilLayers) {
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:host];
        NSUInteger guard = 0;
        while (q.count > 0 && guard++ < 4000) {
            UIView *cur = q.firstObject;
            [q removeObjectAtIndex:0];
            NSString *n = NSStringFromClass(cur.class);
            // 【判据修正 —— v0.7.0 的错在这里】
            // v0.7.0 要求「自身 backgroundColor 的 alpha > 0.25」, 于是从没命中过,
            // 因为 _UIVisualEffectBackdropView 是 UIVisualEffect 的渲染层,
            // 颜色由 effect 生成, **backgroundColor 取不到**。
            // 正确判据是类名 + uie=0 + 面积够大。
            if ([n containsString:@"VisualEffectBackdrop"] && cur != host) {
                CGFloat a = cur.frame.size.width * cur.frame.size.height;
                CGFloat ha = host.frame.size.width * host.frame.size.height;
                if (ha > 0 && a >= ha * 0.15) {
                    if (KGPickable(cur, key)) {
                        [found addObject:cur];
                        continue;   // 命中即止, 不往里钻
                    }
                }
            }
            [q addObjectsFromArray:cur.subviews];
        }
        self.veilLayers = found;
        KGLog(@"锁定系统浓白 veil %lu 层: %@", (unsigned long)found.count,
              [[found valueForKey:@"class"] componentsJoinedByString:@","]);
    }

    CGFloat dim = 1.0 - [KGPrefs glassTransparency];
    if (dim < 0.08) dim = 0.08;          // 永远别归零, 见文件头注释
    [self applyAlphaToLayers:self.veilLayers factor:dim tag:@"veil"];
}

#pragma mark - 3. 顶部45pt 助手条(内外两层都调)

- (void)applyAssistantBar:(UIView *)host {
    if (!self.barLayers) {
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        UIView *key = KGKeyLayerIn(host);
        CGFloat hostArea = host.frame.size.width * host.frame.size.height;
        if (hostArea > 0) {
            NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:host];
            NSUInteger guard = 0;
            while (q.count > 0 && guard++ < 4000) {
                UIView *cur = q.firstObject;
                [q removeObjectAtIndex:0];
                if (cur != host
                    && fabs(cur.frame.origin.y) < 1.0
                    && cur.frame.size.height > 8.0
                    && cur.frame.size.height < host.frame.size.height * 0.25
                    && cur.frame.size.width * cur.frame.size.height >= hostArea * 0.6) {
                    // 【整组】把这层和它子树里所有 VisualEffect 一起收。
                    // 「藏外层连带藏内层」这个假设已经被实测否掉三次:
                    //   v0.7.0 藏外层 UIKBBackdropView -> 内层继续画
                    //   v0.7.3 外层已 h=1 -> 内层 h=0 继续画
                    // 外层和内层各有独立 alpha, 改父不改子。
                    NSMutableArray<UIView *> *sub = [NSMutableArray arrayWithObject:cur];
                    NSUInteger g2 = 0;
                    while (sub.count > 0 && g2++ < 200) {
                        UIView *c = sub.firstObject;
                        [sub removeObjectAtIndex:0];
                        NSString *n = NSStringFromClass(c.class);
                        if ([n containsString:@"VisualEffect"] || [n containsString:@"Backdrop"]) {
                            if (KGPickable(c, key)) [found addObject:c];
                            continue;
                        }
                        [sub addObjectsFromArray:c.subviews];
                    }
                    continue;
                }
                [q addObjectsFromArray:cur.subviews];
            }
        }
        self.barLayers = found;
        KGLog(@"锁定顶部助手条 %lu 层: %@", (unsigned long)found.count,
              [[found valueForKey:@"class"] componentsJoinedByString:@","]);
    }
    // 助手条是纯装饰, 直接归零(它的 uie=0 层不参与触摸, 归零也安全)
    [self applyAlphaToLayers:self.barLayers factor:0.0 tag:@"bar"];
}

#pragma mark - 4. 按键区底板(uie=0 纯视觉, v1.0.0 重新启用)

- (void)applyKeyBottomDim:(UIView *)host {
    UIView *key = KGKeyLayerIn(host);
    if (!key) { self.keyBottomLayers = nil; return; }

    if (!self.keyBottomLayers) {
        NSMutableArray<UIView *> *found = [NSMutableArray array];
        CGFloat keyArea = key.frame.size.width * key.frame.size.height;
        if (keyArea > 0) {
            NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:key];
            NSUInteger guard = 0;
            while (q.count > 0 && guard++ < 400) {
                UIView *cur = q.firstObject;
                [q removeObjectAtIndex:0];
                NSString *n = NSStringFromClass(cur.class);
                // 只挑「底板类」: 宽度铺满按键区、且不是按键本身。
                // UIKBSplitImageView / UIImageView 都是 uie=0 的纯视觉层。
                if (cur != key
                    && cur.frame.size.width >= key.frame.size.width * 0.9
                    && cur.frame.size.height >= key.frame.size.height * 0.9
                    && ![n containsString:@"KeyView"]
                    && KGPickable(cur, key)) {
                    [found addObject:cur];
                    continue;   // 命中即止
                }
                [q addObjectsFromArray:cur.subviews];
            }
        }
        self.keyBottomLayers = found;
        KGLog(@"锁定按键区底板 %lu 层(uie=0 纯视觉): %@",
              (unsigned long)found.count,
              [[found valueForKey:@"class"] componentsJoinedByString:@","]);
    }

    // 【v1.0.0 关键】这里**不再有任何「触摸安全下限」**。
    // v0.7.3 那个 0.55 下限是基于「它是触摸层」的误判—— 实测该层 uie=0,
    // 本来就与触摸派发无关, 加下限只是自己吓自己。
    // 现在可以放心调淡, 观感自由度回来了。
    CGFloat dim = [KGPrefs keyplaneDim];
    [self applyAlphaToLayers:self.keyBottomLayers factor:(1.0 - MIN(0.9, MAX(0.0, dim))) tag:@"key"];
}

#pragma mark - 5. 全屏白底 _UIRemoteView (uie=0, 在手势覆盖层内部)

- (void)applyFullscreenWhite:(UIView *)host {
    UIView *container = host.superview;
    if (!container) return;
    CGFloat screenArea = UIScreen.mainScreen.bounds.size.width
                       * UIScreen.mainScreen.bounds.size.height;
    if (screenArea <= 0) return;

    if (!self.fullscreenWhiteView || !self.fullscreenWhiteView.superview) {
        self.fullscreenWhiteView = nil;
        // 探针实锤的层级: UIEditingOverlayGestureView (d0, uie=1)
        //   └ _UIRemoteView (d8, 430x932, uie=0)  ← 纯视觉的全屏白底
        // 我们只关内层, 外层的手势能力保留。
        NSMutableArray<UIView *> *q = [NSMutableArray arrayWithObject:container];
        NSUInteger guard = 0;
        while (q.count > 0 && guard++ < 300) {
            UIView *cur = q.firstObject;
            [q removeObjectAtIndex:0];
            for (UIView *v in cur.subviews) {
                NSString *n = NSStringFromClass(v.class);
                CGFloat a = v.frame.size.width * v.frame.size.height;
                // 类名 + 铺满全屏 + **uie=0**(纯视觉) 三个条件同时满足
                if ([n containsString:@"RemoteView"] && !v.userInteractionEnabled
                    && a >= screenArea * 0.85) {
                    self.fullscreenWhiteView = v;
                    break;
                }
            }
            if (self.fullscreenWhiteView) break;
            [q addObjectsFromArray:cur.subviews];
        }
        KGLog(@"锁定全屏白底层 %@",
              self.fullscreenWhiteView ? NSStringFromClass(self.fullscreenWhiteView.class) : @"none");
    }
    // 只要键盘在屏幕上, 这个全屏白底就该关掉 —— 它就是「整屏发白」的真身。
    [self setFullscreenWhiteHidden:YES];
}

- (void)setFullscreenWhiteHidden:(BOOL)hidden {
    UIView *v = self.fullscreenWhiteView;
    if (!v) return;
    if (v.hidden != hidden) {
        v.hidden = hidden;
        KGLog(@"全屏白底 %@ hidden=%d", NSStringFromClass(v.class), hidden ? 1 : 0);
    }
}

#pragma mark - alpha 应用(统一入口, 全部只作用在已筛过的 uie=0 层)

- (void)applyAlphaToLayers:(NSArray<UIView *> *)layers
                   factor:(CGFloat)factor
                      tag:(NSString *)tag {
    if (!layers.count) return;
    if (!self.touchedLayers) {
        self.touchedLayers = [NSMapTable weakToStrongObjectsMapTable];
    }
    for (UIView *v in layers) {
        if (!v.superview) continue;
        // 【保险丝】KGPickable 已经筛过 uie=0, 这里再查一次。
        // 任何 uie=1 的层直接跳过 —— 十一版的教训不值得再冒一次险。
        if (v.userInteractionEnabled) continue;

        NSNumber *orig = [self.touchedLayers objectForKey:v];
        if (!orig) {
            [self.touchedLayers setObject:@(v.alpha) forKey:v];
            orig = @(v.alpha);
        }
        CGFloat target = orig.doubleValue * factor;
        if (fabs(v.alpha - target) > 0.002) {
            v.alpha = target;
        }
    }
}

- (void)restoreAll {
    if (!self.touchedLayers) return;
    for (UIView *v in [[self.touchedLayers keyEnumerator] allObjects]) {
        if (!v) continue;
        NSNumber *orig = [self.touchedLayers objectForKey:v];
        if (orig) v.alpha = orig.doubleValue;
    }
    [self.touchedLayers removeAllObjects];
    self.veilLayers = nil;
    self.barLayers = nil;
    self.keyBottomLayers = nil;
}

- (void)teardown {
    if (self.glassView) {
        [self.glassView removeFromSuperview];
        self.glassView.hidden = YES;
    }
    [self restoreAll];
    [self setFullscreenWhiteHidden:NO];
    self.hostView = nil;
    self.hasAppliedStyle = NO;
}

#pragma mark - 探针

- (void)dumpTreeForHost:(UIView *)host {
    if (self.didDumpTree) return;
    self.didDumpTree = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        if (!host.superview) return;
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"==== [%@] 稳定态全树 (含uie 标注) ====\n", [NSDate date]];
        // budget 用一个真正活在块里的变量。写成 &(NSInteger){400} 的话
        // 那个临时量的地址只在完整表达式内有效, 一旦跨到 dispatch_after
        // 的异步块里就是野指针 —— v1.0.0 重写时顺手修掉, 不留这个坑。
        NSInteger budget = 400;
        [self dumpTree:host.superview depth:0 into:out budget:&budget];
        KGWriteProbe(out);
    });
}

- (void)dumpTree:(UIView *)v depth:(NSInteger)d into:(NSMutableString *)out
         budget:(NSInteger *)budget {
    if (!v || *budget <= 0 || d > 14) return;
    (*budget)--;
    for (NSInteger i = 0; i < d; i++) [out appendString:@"  "];
    UIColor *bg = v.backgroundColor;
    NSString *bgd = @"-";
    if (bg) {
        CGFloat r,g,b,a;
        if ([bg getRed:&r green:&g blue:&b alpha:&a]) {
            bgd = [NSString stringWithFormat:@"%.2f/%.2f/%.2f/%.2f", r,g,b,a];
        }
    }
    // uie 是这一版最重要的字段: 它决定了哪些层可以碰。
    [out appendFormat:@"%@ | %@ a=%.2f h=%d uie=%d %@ bg=%@\n",
        NSStringFromClass(v.class), NSStringFromCGRect(v.frame),
        v.alpha, v.hidden, v.userInteractionEnabled,
        v.userInteractionEnabled ? @"[UI层·不可碰]" : @"[视觉层·可碰]",
        bgd];
    for (UIView *sub in v.subviews) {
        [self dumpTree:sub depth:d+1 into:out budget:budget];
    }
}

- (void)writeProbe:(UIView *)host material:(KGMaterial)material {
    UIView *key = KGKeyLayerIn(host);
    NSString *veil = [self descLayers:self.veilLayers];
    NSString *bar  = [self descLayers:self.barLayers];
    NSString *kb   = [self descLayers:self.keyBottomLayers];
    UIView *fw = self.fullscreenWhiteView;
    NSString *fwDesc = fw
        ? [NSString stringWithFormat:@"%@(%@,h=%d)", NSStringFromClass(fw.class),
           NSStringFromCGRect(fw.frame), fw.hidden ? 1 : 0]
        : @"none";

    NSString *sig = [NSString stringWithFormat:@"%@|%@|%@|%@|%@|%@|%.3f",
        NSStringFromCGRect(host.frame), veil, bar, kb, fwDesc,
        [self.glassView isDescendantOfView:host] ? @"in" : @"out",
        (double)[KGPrefs glassTransparency]];
    if ([sig isEqualToString:self.lastSignature]) return;
    self.lastSignature = sig;
    if (self.probeCount++ > 200) return;

    KGWriteProbe([NSString stringWithFormat:
        @"[v1 %@] host=%@ frame=%@ key=%@\n"
        @"   veil=%@\n   bar=%@\n   keyBottom=%@\n   fullscreenWhite=%@\n"
        @"   glass=%@ veil滑块=%.2f keyDim=%.2f material=%ld\n",
        [NSDate date], NSStringFromClass(host.class), NSStringFromCGRect(host.frame),
        key ? NSStringFromClass(key.class) : @"none",
        veil, bar, kb, fwDesc,
        [self.glassView isDescendantOfView:host] ? @"in" : @"out",
        (double)[KGPrefs glassTransparency], (double)[KGPrefs keyplaneDim], (long)material]);
}

- (NSString *)descLayers:(NSArray<UIView *> *)layers {
    if (!layers.count) return @"none";
    NSMutableString *s = [NSMutableString string];
    for (UIView *v in layers) {
        NSNumber *o = [self.touchedLayers objectForKey:v];
        [s appendFormat:@"%@(origin=%.2f,now=%.2f) ",
            NSStringFromClass(v.class), o ? o.doubleValue : -1.0, v.alpha];
    }
    return s;
}

@end