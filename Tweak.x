#import <UIKit/UIKit.h>
#import "KGPrefs.h"
#import "KGEngine.h"

// Logos 只会给 %hook 的目标生成前向声明 (@class), 那样编译器不知道它是
// UIViewController 子类, 取 self.view 会报 "property 'view' cannot be found
// in forward class object"。这里显式补上继承关系。
@interface UIInputWindowController : UIViewController
@end

// 键盘宿主视图。私有类, 只需要补继承关系 —— Logos 的 %hook 走
// objc_getClass("UIInputSetHostView"), 类不存在时自动跳过, 不会崩。
@interface UIInputSetHostView : UIView
@end

// ======================================================================
// 【v3.0.0】推翻重做 —— 入口只观测, 定时器才动手
// ======================================================================
//
// 【v0.7.2 架构定论 —— hook 里一行都不许改视图树, 这条到 v3.0.0 依然有效】
//
// v0.7.1 用户实测「又打不了字了」。当时的死因是: 宿主 layoutSubviews ->
// 我们插玻璃 / 改玻璃 frame -> 触发宿主重排 -> 再次 layoutSubviews ->
// 玻璃 frame 又跟上一个新布局 …… 两个布局解互相拉扯, 乒乓不收敛。
//
// 结论: **凡是会在 layoutSubviews 里改视图树的设计, 一律不要用。**
// 布局回调只做一件事 —— 记下宿主, 然后立刻返回。真正干活的是 KGEngine
// 里的 0.4s 定时器, 且只在宿主 frame 连续两次采样完全相同时才动手。
//
// 【这个教训的通用形式 —— 第 14 版了, 写在这里防止再犯】
//   在系统视图的布局回调里修改该视图树的任何一部分(加/删 subview、
//   改 frame、改 alpha), 都是**给自己造一个可能不收敛的反馈环**。
//   正确姿势永远是: 回调里只观测, 变更交给「稳定之后」再执行。
//
// ----------------------------------------------------------------------
%hook UIInputSetHostView

- (void)layoutSubviews {
    %orig;
    // 只观测, 不动手。见文件头那段说明。
    [[KGEngine shared] noteHostLayout:self];
}

%end

// 入口 2 (兜底): 系统键盘的容器控制器。
// 万一某些 iOS 版本/场景没有 UIInputSetHostView, 从这一层找也一样能装。
// 同样**只观测, 不动手**。
%hook UIInputWindowController

- (void)viewDidLayoutSubviews {
    %orig;
    [[KGEngine shared] noteContainerLayout:self.view];
}

%end

// ======================================================================
// %ctor —— 启动
// ======================================================================
%ctor {
    @autoreleasepool {
        [KGPrefs registerDefaults];

        // v3.0.0: 回到「装了就有效果」。v2.0.0 是纯探针(一行都不改视图),
        // 用户反馈「完完全全一点都不生效」—— 那是设计如此, 但一个零效果的
        // 版本不该被当成交付。这一版动真格: 调低系统底板的白 + 插玻璃层。
        [[KGEngine shared] startWorker];

        KGLog(@"KeyboardGlass 已加载 (3.0.0)");
        KGLog(@"v3.0.0 推翻重做: 底板白度=%.2f 材质=%ld",
              [KGPrefs backdropWhiteness], (long)[KGPrefs material]);
    }
}
