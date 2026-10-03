#import <UIKit/UIKit.h>
#import "KGPrefs.h"

// 玻璃视图 —— 整块键盘的玻璃材质。
//
// 【v0.5.0 架构变更：从纯 CALayer 改成 UIView + UIVisualEffectView】
//
// v0.4.x 用的是 CABackdropLayer + CAFilter(gaussianBlur)。机制上没问题，
// 但**它采不到 App 窗口的内容** —— backdrop 层只采样同一 layer 树里已经绘制
// 的内容，而键盘在独立的 overlay 窗口里。于是 backdrop 采到的样本是空的，
// 玻璃层等于全透明：底下 App 的文字清晰可辨，一点磨砂感都没有。
// （用户反馈原话：「没达到我预期的玻璃效果」，截图正是如此。）
//
// 系统键盘自己用的就是 UIVisualEffectView(_UIVisualEffectBackdropView 内核)，
// 跨窗口模糊对它有效。所以直接换成同一套机制，不再自己拼 backdrop。
//
// 【关于触摸】用 UIView 曾经两次翻车，这里把话说清楚：
//   v0.2.0 失败是因为插到了按键**上面**，且用 alpha=0 藏视图连带整棵子树
//   退出 hitTest；v0.4.3 查明的真凶是 z 序错位。
//   本类**显式 setUserInteractionEnabled:NO** —— hitTest 遇到它必定跳过，
//   这是 UIKit 层面有明确保证的行为，不依赖任何推断。
//
// z 序由安装器负责（插在按键容器之下 = 背景之上、按键之下）。

@interface KGGlassView : UIView

@property (nonatomic, assign) KGStyle kgStyle;
@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, assign) BOOL showOutline;

- (void)applyStyle:(KGStyle)style dark:(BOOL)dark;

@end
