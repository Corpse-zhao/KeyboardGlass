#import "KGKeyboardInstaller.h"
#import "KGGlassView.h"
#import "KGPrefs.h"
#import <sys/stat.h>

// 背板类名候选。不同 iOS 版本用的是不同私有类, 这里全部收进来,
// 命中哪个用哪个 —— 避免把实现绑死在某个类名上。
//   iOS 15/16: TUIKeyboardBackdropView / UIKBInputBackdropView
//   更早:      UIKBBackdropView
static NSArray<NSString *> *KGBackdropClassHints(void) {
    static NSArray *hints = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        hints = @[ @"InputBackdrop", @"KeyboardBackdrop", @"UIKBBackdropView" ];
    });
    return hints;
}

static BOOL KGViewLooksLikeBackdrop(UIView *view) {
    if (!view || !view.window) return NO;
    NSString *name = NSStringFromClass(view.class);
    if (name.length == 0) return NO;
    for (NSString *hint in KGBackdropClassHints()) {
        if ([name containsString:hint]) return YES;
    }
    return NO;
}

// 主背板资格: 键盘高度至少要有 150pt。
// 键盘切换动画途中主背板会暂时离树, 此时面积择优会选中候选栏里的
// 小背板 (如 44x44 的 TUICandidateBackdropView) —— 玻璃层一旦搬过去
// 就再也回不来, 表现为「完全不生效」。小背板一律无视。
static BOOL KGIsMainBackdrop(UIView *view) {
    if (!view || !view.window) return NO;
    CGRect frame = view.frame;
    CGFloat screenWidth = view.window.bounds.size.width;
    if (screenWidth <= 0) return NO;
    return (frame.size.width * frame.size.height) >= screenWidth * 150.0;
}

static BOOL KGStyleEqual(KGStyle a, KGStyle b) {
    return a.blur == b.blur
        && a.refraction == b.refraction
        && a.highlight == b.highlight
        && a.veil == b.veil
        && a.cornerRadius == b.cornerRadius
        && a.dark == b.dark;
}

#pragma mark - 视图树探针

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

static void KGDumpTreeOnce(UIView *root, NSString *tag) {
    static NSMutableDictionary *dumped = nil;
    static dispatch_once_t once;
    dispatch_once(&once, ^{ dumped = [NSMutableDictionary dictionary]; });
    if (dumped[tag]) return;
    dumped[tag] = @YES;

    NSMutableString *out = [NSMutableString string];
    [out appendFormat:@"==== [%@] %@ 键盘视图树 ====\n", [NSDate date], tag];
    NSInteger budget = 300;
    KGDumpTree(root, 0, out, &budget);
    [out appendString:@"====\n"];
    KGWriteProbe(out);
    KGLog(@"已 dump %@ 视图树", tag);
}

@interface KGKeyboardInstaller ()
@property (nonatomic, strong) KGGlassView *glassView;
@property (nonatomic, weak)   UIView *nativeBackdrop;
@property (nonatomic, assign) CGFloat nativeBackdropAlpha;
@property (nonatomic, assign) BOOL nativeBackdropAlphaSaved;
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

- (void)handleLayout:(UIView *)root {
    if (!root) return;

    [KGPrefs debugLog];   // 刷新调试开关, 让设置改动无需重启即可生效

    KGMaterial material = [KGPrefs material];
    if (material == KGMaterialOff) {
        [self teardown];
        return;
    }

    // 已安装且装在合格的主背板上: 只做轻量同步, 不重复遍历视图树。
    // 注意必须校验当前背板是主背板 —— 否则玻璃层卡在小背板里就永远出不来了
    UIView *backdrop = self.nativeBackdrop;
    BOOL installedOnMain = (backdrop && KGIsMainBackdrop(backdrop));
    if (self.glassView && self.glassView.superview && installedOnMain && backdrop.superview) {
        [self syncGeometryWithBackdrop:backdrop];
        [self enforceNativeBackdropState];
        [self applyStyleForMaterial:material];
        return;
    }

    UIView *found = [self findBackdropIn:root];
    if (!found) {
        KGLog(@"未找到键盘背板 (root=%@)", NSStringFromClass(root.class));
        KGDumpTreeOnce(root, @"系统键盘");
        return;
    }

    if (!KGIsMainBackdrop(found)) {
        // 小背板 (候选栏按钮等): 不安装也不迁移, 等主背板回到树里再说
        KGLog(@"忽略小背板 %@ frame=%@", NSStringFromClass(found.class), NSStringFromCGRect(found.frame));
        return;
    }

    KGLog(@"命中背板 %@ frame=%@", NSStringFromClass(found.class), NSStringFromCGRect(found.frame));
    // dump 背板的父视图整棵树 —— 才能看到玻璃层插进去之后和兄弟节点的叠放关系
    KGDumpTreeOnce(found.superview ?: found, @"背板所在层级");
    [self installOnBackdrop:found material:material];
}

// 第三方输入法扩展入口: 视图全部自绘, 先 dump 再按同一套逻辑尝试安装
- (void)handleExtensionLayout:(UIView *)root {
    if (!root) return;
    KGDumpTreeOnce(root, @"输入法扩展");
    [self handleLayout:root];
}

#pragma mark - 探测

// 广度优先遍历, 取面积最大的那个背板 —— 键盘主背板一定是最大的一块
- (UIView *)findBackdropIn:(UIView *)root {
    UIView *best = nil;
    CGFloat bestArea = 0;

    NSMutableArray<UIView *> *queue = [NSMutableArray arrayWithObject:root];
    NSUInteger guard = 0;   // 防御性上限, 避免遇到异常视图树时卡死
    while (queue.count > 0 && guard++ < 4000) {
        UIView *current = queue.firstObject;
        [queue removeObjectAtIndex:0];

        if (KGViewLooksLikeBackdrop(current)) {
            CGRect frame = current.frame;
            CGFloat area = frame.size.width * frame.size.height;
            if (area > bestArea) {
                bestArea = area;
                best = current;
            }
        }
        [queue addObjectsFromArray:current.subviews];
    }
    return best;
}

#pragma mark - 安装与拆卸

- (void)installOnBackdrop:(UIView *)backdrop material:(KGMaterial)material {
    UIView *host = backdrop.superview;
    if (!host) return;

    [self restoreNativeBackdrop];

    if (!self.glassView) {
        self.glassView = [[KGGlassView alloc] initWithFrame:backdrop.bounds];
        self.hasAppliedStyle = NO;
    }

    self.glassView.frame = backdrop.frame;   // 与背板同一坐标系
    [host insertSubview:self.glassView aboveSubview:backdrop];

    self.nativeBackdrop = backdrop;
    self.nativeBackdropAlpha = backdrop.alpha;
    self.nativeBackdropAlphaSaved = YES;

    [self enforceNativeBackdropState];
    [self applyStyleForMaterial:material];

    // 安装结果写进探针: 下次诊断直接能看到层是否插上、插到了哪个父视图、参数是多少
    KGWriteProbe([NSString stringWithFormat:
        @"[install %@] host=%@ glassFrame=%@ hideNative=%d material=%ld blur=%.1f refraction=%.1f highlight=%.2f veil=%.2f radius=%.1f\n",
        [NSDate date], NSStringFromClass(host.class),
        NSStringFromCGRect(self.glassView.frame),
        [KGPrefs hideNativeBackdrop], (long)material,
        self.appliedStyle.blur, self.appliedStyle.refraction,
        self.appliedStyle.highlight, self.appliedStyle.veil,
        self.appliedStyle.cornerRadius]);
}

// 系统在键盘布局过程中可能会重设背板外观, 每次布局都把我们要的状态补一遍 (幂等)
- (void)enforceNativeBackdropState {
    UIView *backdrop = self.nativeBackdrop;
    if (!backdrop || !self.nativeBackdropAlphaSaved) return;
    backdrop.alpha = [KGPrefs hideNativeBackdrop] ? 0.0 : self.nativeBackdropAlpha;
}

- (void)syncGeometryWithBackdrop:(UIView *)backdrop {
    CGRect target = backdrop.frame;
    if (!CGRectEqualToRect(self.glassView.frame, target)) {
        self.glassView.frame = target;
    }
}

- (void)applyStyleForMaterial:(KGMaterial)material {
    BOOL dark = (self.glassView.traitCollection.userInterfaceStyle == UIUserInterfaceStyleDark);
    KGStyle style = [KGPrefs styleForMaterial:material dark:dark];
    if (self.hasAppliedStyle && KGStyleEqual(style, self.appliedStyle)) return;
    self.appliedStyle = style;
    self.hasAppliedStyle = YES;
    [self.glassView applyStyle:style];
}

- (void)restoreNativeBackdrop {
    UIView *backdrop = self.nativeBackdrop;
    if (backdrop && self.nativeBackdropAlphaSaved) {
        backdrop.alpha = self.nativeBackdropAlpha;
    }
    self.nativeBackdrop = nil;
    self.nativeBackdropAlphaSaved = NO;
}

- (void)teardown {
    if (self.glassView) {
        [self.glassView removeFromSuperview];
        self.glassView = nil;
        self.hasAppliedStyle = NO;
    }
    [self restoreNativeBackdrop];
}

@end
