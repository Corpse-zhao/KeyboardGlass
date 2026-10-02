#import <UIKit/UIKit.h>
#import "KGPrefs.h"
#import "KGGlassView.h"
#import "KGKeyboardInstaller.h"

// Logos 只会给 %hook 的目标生成前向声明 (@class), 那样编译器不知道它是
// UIViewController 子类, 取 self.view 会报 "property 'view' cannot be found
// in forward class object"。这里显式补上继承关系。
@interface UIInputWindowController : UIViewController
@end

@interface UIInputViewController : UIViewController
@end

// 入口 1: 系统键盘 —— 住在宿主 App 进程里, 由 UIInputWindowController 管理。
// 每次布局 (弹出 / 收起 / 旋转 / 切换键盘) 都会走到这里, 借这个时机装玻璃层。
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

// 入口 2: 第三方输入法 (微信输入法等) —— 键盘在它们自己的 Keyboard Extension
// 进程里, 由 UIInputViewController 子类管理。视图全是自绘, 背板类名未知,
// 第一次布局时先把视图树 dump 进探针文件, 拿到结构后再对准 hook。
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
        KGLog(@"KeyboardGlass 已加载");
    }
}
