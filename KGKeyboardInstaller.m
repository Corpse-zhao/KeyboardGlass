#import "KGKeyboardInstaller.h"
#import "KGGlassView.h"
#import "KGPrefs.h"

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

static BOOL KGStyleEqual(KGStyle a, KGStyle b) {
    return a.blur == b.blur
        && a.refraction == b.refraction
        && a.highlight == b.highlight
        && a.veil == b.veil
        && a.cornerRadius == b.cornerRadius
        && a.dark == b.dark;
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

    // 已安装且背板还活着: 只做轻量同步, 不重复遍历视图树
    UIView *backdrop = self.nativeBackdrop;
    if (self.glassView && self.glassView.superview && backdrop && backdrop.superview) {
        [self syncGeometryWithBackdrop:backdrop];
        [self applyStyleForMaterial:material];
        return;
    }

    UIView *found = [self findBackdropIn:root];
    if (!found) {
        KGLog(@"未找到键盘背板 (root=%@)", NSStringFromClass(root.class));
        return;
    }

    KGLog(@"命中背板 %@ frame=%@", NSStringFromClass(found.class), NSStringFromCGRect(found.frame));
    [self installOnBackdrop:found material:material];
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

    if ([KGPrefs hideNativeBackdrop]) {
        // 原生背板是不透明的一层, 不隐藏的话玻璃层采不到下面的 App 内容
        backdrop.alpha = 0.0;
    }

    [self applyStyleForMaterial:material];
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
