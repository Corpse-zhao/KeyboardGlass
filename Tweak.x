#import <UIKit/UIKit.h>
#import "KGPrefs.h"
#import "KGGlassView.h"
#import "KGKeyboardInstaller.h"
#import "KGExtProbe.h"

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
// 【v0.7.2 架构定论 —— hook 里一行都不许改视图树】
// ======================================================================
//
// v0.7.1 用户实测「又打不了字了」。2026-10-03 03:56 的探针把死因钉死了:
// 同一秒内 25 次宿主采样, 宿主 frame 在**两个值之间来回震荡**:
//   {{0,932},{430,243}}   y=932 已在屏幕外(收起动画末帧)
//   {{0,857},{430, 75}}   屏幕上只剩 75pt(收起态 dock 条)
// 整份日志 151212 个 dump 块 / 75513 行 #0 UIKeyboardDockView —— 键盘被卡死
// 在展开动画里反复重排, 永远落不了地。用户看到的现象就是「打不了字」。
//
// 震动的成因链 (每一环都是 v0.4.x~v0.7.1 亲手接上的):
//   宿主 layoutSubviews -> 我们插玻璃 / 改玻璃 frame -> 触发宿主重排
//     -> 再次 layoutSubviews -> 玻璃 frame 又跟上一个新布局
//       -> … 两个布局解互相拉扯, 乒乓不收敛。
//
// 【为什么之前那些防护全都没挡住】
// - 静态 BOOL kgInLayout 重入闸: 只能挡**同步递归**, 挡不住「改 frame ->
//   异步触发下一次 layout -> 回调又进来」这条跨消息回路。它挡的是 A,
//   死因是 B, 两者毫不相干。
// - v0.6.0 的 lastAppliedMode: 只管恢复时机, 不管玻璃 frame 的写入。
// - v0.7.1 的 insertSubview:atIndex:0「暂驻底部」: 恰恰**加重**了它 ——
//   玻璃从此常驻宿主, 每一次重排都带着它一起重排, 两个布局解互相拉扯。
//
// 结论: **凡是会在 layoutSubviews 里改视图树的设计, 一律不要用。**
// 布局回调只做一件事 —— 记下宿主、置一个脏标记, 然后立刻返回。
// 真正干活的是一个 0.4s 的定时器, 且只在「宿主 frame 连续两次采样完全相同」
// (也就是键盘已经彻底稳定) 时才动手。这两个改动一起切断反馈链。
//
// 【这个教训的通用形式 —— 第 8 版了, 写在这里防止再犯】
//   在系统视图的布局回调里修改该视图树的任何一部分(加/删 subview、
//   改 frame、改 alpha), 都是**给自己造一个可能不收敛的反馈环**。
//   正确姿势永远是: 回调里只观测, 变更交给「稳定之后」再执行。
//
// ----------------------------------------------------------------------
%hook UIInputSetHostView

- (void)layoutSubviews {
    %orig;
    // 只观测, 不动手。见文件头那段说明。
    [[KGKeyboardInstaller shared] noteHostLayout:self];
}

%end

// 入口 2 (兜底): 系统键盘的容器控制器。
// 万一某些 iOS 版本/场景没有 UIInputSetHostView, 从这一层找也一样能装。
// 同样**只观测, 不动手**。
%hook UIInputWindowController

- (void)viewDidLayoutSubviews {
    %orig;
    [[KGKeyboardInstaller shared] noteContainerLayout:self.view];
}

%end

// ======================================================================
// 【v2.0.0】微信输入法适配 —— 启用扩展进程探针
// ======================================================================
//
// 【v0.3.0 当年的注释, 现在兑现】
// 原话: 「后续真要做第三方输入法, 必须单独立开关、且默认关闭。」
// 现在正是那个时候。开关就是「启用 - 扩展进程探针」(KGPrefs.extProbe),
// **默认开** —— 与当年「默认关」相反, 理由见下。
//
// 【为什么不默认关】
// 这一版**不改任何视图**, 只 dump。默认关的话用户会以为插件没生效,
// 白白再发一轮探针。探针的代价是零(只读视图树 + 写一个文件),
// 收益是「第一次真正看清按键区长什么样」。
//
// 【v0.3.0 当年为什么删掉 UIInputViewController 这条路】
// 当时的判断是「第三方输入法视图全部自绘, 系统键盘那套锚点假设不成立」。
// 这个判断**对了一半**: 锚点假设确实不成立, 但不是因为跨进程看不见, 而是因为
// 当时 hook 的是宿主进程里的 UIInputViewController(那是系统自己的容器),
// 而真正的第三方键盘在**另一个进程**里。
// 2026-10-03 的探针把这一点钉死了: 宿主树里只有 _UIRemoteKeyboardPlaceholderView。
//
// ----------------------------------------------------------------------
%ctor {
    @autoreleasepool {
        [KGPrefs registerDefaults];

        // 扩展进程探针。宿主进程里它是空转(扫不到键盘形状的视图),
        // 扩展进程里它负责 dump 微信输入法的按键层级。
        if ([KGPrefs extProbe]) {
            [KGExtProbe start];
        }

        // 宿主进程的旧逻辑**默认关闭**。
        // 理由: v1.1.0 探针已证明它改的那些层(全屏白底 _UIRemoteView)
        // 在 iOS 16 上根本不存在, 所谓「白屏」与插件无关。继续跑它
        // 只会让用户分不清是哪个开关在起作用, 而且改过 alpha 的层
        // 可能残留(插件被禁用时不会自动复原)。
        if ([KGPrefs hostKeyboardActions]) {
            [[KGKeyboardInstaller shared] startWorker];
        }

        KGLog(@"KeyboardGlass 已加载 (2.0.0)");
        KGLog(@"v2.0.0: 扩展进程探针=%@ 宿主旧逻辑=%@",
              [KGPrefs extProbe] ? @"开" : @"关",
              [KGPrefs hostKeyboardActions] ? @"开" : @"关");
    }
}
