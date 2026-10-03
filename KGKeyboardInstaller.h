#import <UIKit/UIKit.h>

// 键盘玻璃安装器。
// 每次键盘布局时被调用: 找出键盘宿主视图, 按「工作模式」决定做多少事。
//
// v0.3.0 起**只处理系统键盘**。第三方输入法 (微信输入法等) 是独立的
// Keyboard Extension 进程, 视图全部自绘, 我们对系统键盘那套锚点假设在那里
// 不成立 —— 用户实测在微信输入法上也「打不了字」, 所以那条路径整个删掉,
// filter 里也不再挂任何输入法 bundle。
@interface KGKeyboardInstaller : NSObject

+ (instancetype)shared;

// root 传 UIInputWindowController.view (系统键盘)
- (void)handleLayout:(UIView *)root;

// 最准的入口: 直接把 UIInputSetHostView 递进来 (在它的 layoutSubviews 里调)。
// 宿主视图的 frame 就是键盘矩形, 不依赖任何私有背板类名。
- (void)handleHostView:(UIView *)host;

@end
