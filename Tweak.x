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

// 入口 1 (主): 键盘宿主视图自己的 layoutSubviews。
// 它的 frame 就是键盘矩形, 且一定存在 —— 不用猜任何私有背板类名,
// 时机也最准 (键盘弹出 / 收起 / 改尺寸 / 换键盘都会走到)。
%hook UIInputSetHostView

- (void)layoutSubviews {
    %orig;

    // 我们在里面会往宿主上加东西, 可能又触发一次布局 —— 加个重入闸,
    // 避免无限递归。
    static BOOL kgInLayout = NO;
    if (kgInLayout) return;
    kgInLayout = YES;
    @try {
        [[KGKeyboardInstaller shared] handleHostView:self];
    } @catch (NSException *exception) {
        // v0.4.2: 异常要走熔断计数, 不能只打日志。连续崩到阈值就整个停手,
        // 宁可没玻璃也不能再把用户送进安全模式。
        KGLog(@"宿主布局处理异常: %@", exception);
        [KGKeyboardInstaller noteHandledException:exception where:@"layoutSubviews"];
    }
    kgInLayout = NO;
}

%end

// 入口 2 (兜底): 系统键盘的容器控制器。
// 万一某些 iOS 版本/场景没有 UIInputSetHostView, 从这一层找也一样能装。
%hook UIInputWindowController

- (void)viewDidLayoutSubviews {
    %orig;
    @try {
        [[KGKeyboardInstaller shared] handleLayout:self.view];
    } @catch (NSException *exception) {
        KGLog(@"布局处理异常: %@", exception);
        [KGKeyboardInstaller noteHandledException:exception where:@"viewDidLayoutSubviews"];
    }
}

%end

// v0.3.0 起**不再 hook UIInputViewController**。
// 那是第三方输入法 (微信输入法等) 的入口 —— 它们的键盘跑在独立的
// Keyboard Extension 进程、视图全部自绘, 我们对系统键盘那套锚点假设在那里
// 完全不成立。用户实测在微信输入法上同样「打不了字」, 所以这条路径整个删掉。
// 后续真要做第三方输入法, 必须单独立开关、且默认关闭。

%ctor {
    @autoreleasepool {
        [KGPrefs registerDefaults];
        KGLog(@"KeyboardGlass 已加载 (0.4.3)");
    }
}
