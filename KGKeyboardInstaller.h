#import <UIKit/UIKit.h>

// 键盘玻璃安装器。
// 每次键盘布局时被调用: 在键盘视图树里找出背板视图, 让出位置给玻璃层。
// 找不到背板时静默返回, 绝不影响键盘本身的功能。
@interface KGKeyboardInstaller : NSObject

+ (instancetype)shared;

// root 传 UIInputWindowController.view
- (void)handleLayout:(UIView *)root;

@end
