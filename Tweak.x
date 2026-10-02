#import <UIKit/UIKit.h>
#import "KGPrefs.h"
#import "KGGlassLayer.h"
#import "KGKeyboardInstaller.h"

// Logos 只会给 %hook 的目标生成前向声明 (@class), 那样编译器不知道它是
// UIViewController 子类, 取 self.view 会报 "property 'view' cannot be found
// in forward class object"。这里显式补上继承关系。
@interface UIInputWindowController : UIViewController
@end

// 键盘宿主视图。私有类, 只需要补继承关系 —— Logos 的 %hook 走
// objc_getClass("UIInputSetHostView"), 类不存在时自动跳过, 不会崩。
@interface UIInputSetHostView : UIView
@end

// UIInputViewController 是 iOS 8+ 的公开类, 不需要再声明。

// 入口 1 (主): 键盘宿主视图自己的 layoutSubviews。
// 它的 frame 就是键盘矩形, 且一定存在 —— 不用猜任何私有背板类名,
// 时机也最准 (键盘弹出 / 收起 / 改尺寸 / 切键盘都会走到)。
%hook UIInputSetHostView

- (void)layoutSubviews {
    %orig;

    // 我们在里面会往宿主上加子视图, 可能又触发一次布局 —— 加个重入闸,
    // 避免无限递归。
    static BOOL kgInLayout = NO;
    if (kgInLayout) return;
    kgInLayout = YES;
    @try {
        [[KGKeyboardInstaller shared] handleHostView:self];
    } @catch (NSException *exception) {
        KGLog(@"宿主布局处理异常: %@", exception);
    }
    kgInLayout = NO;
}

%end

// 入口 2 (兜底): 系统键盘的容器控制器。
// 万一某些 iOS 版本/场景没有 UIInputSetHostView, 从这一层全树找也一样能装。
%hook UIInputWindowController

- (void)viewDidLayoutSubviews {
    %orig;
    @try {
        [[KGKeyboardInstaller shared] handleLayout:self.view];
    } @catch (NSException *exception) {
        KGLog(@"布局处理异常: %@", exception);
    }
}

%end

// 入口 3: 第三方输入法 (微信输入法等) —— 键盘在它们自己的 Keyboard Extension
// 进程里, 由 UIInputViewController 子类管理。视图全是自绘, 结构未知,
// 先把视图树 dump 进探针文件, 拿到结构后再对准 hook。
%hook UIInputViewController

- (void)viewDidLayoutSubviews {
    %orig;
    @try {
        [[KGKeyboardInstaller shared] handleExtensionLayout:self.view];
    } @catch (NSException *exception) {
        KGLog(@"扩展布局处理异常: %@", exception);
    }
}

%end

%ctor {
    @autoreleasepool {
        [KGPrefs registerDefaults];
        KGLog(@"KeyboardGlass 已加载 (0.2.3)");
    }
}
