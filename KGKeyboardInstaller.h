#import <UIKit/UIKit.h>

// 键盘玻璃安装器。
//
// ======================================================================
// 【v0.7.2 职责边界 —— 布局回调只观测, 定时器才动手】
// ======================================================================
// v0.7.1 的死因: 一切都在 UIInputSetHostView.layoutSubviews 里改视图树,
// 于是「改 frame -> 触发重排 -> 回调又进来」形成不收敛的乒乓, 键盘被卡死
// 在展开动画里反复重排, 用户实测「又打不了字了」(探针里同一秒内宿主 frame
// 在 {{0,932},{430,243}} 与 {{0,857},{430,75}} 之间来回跳了 25 次)。
//
// 所以职责切成两半:
//   noteHostLayout: / noteContainerLayout:  —— 由 %hook 在布局回调里调用。
//        **只记一个弱引用 + 置脏标记, 一个字节的视图树都不碰。**
//        必须无 @try、无递归、无 setNeedsLayout, 越轻越好。
//
//   startWorker (ctor 里调一次) —— 起一个 0.4s 的 NSTimer。
//        定时器里检查: 宿主 frame 连续两次采样**完全相同**(键盘已稳定)
//        才真正执行装玻璃/调淡底色。动画期间一律不碰。
//
// v0.3.0 起**只处理系统键盘**。第三方输入法 (微信输入法等) 是独立的
// Keyboard Extension 进程, 视图全部自绘, 我们对系统键盘那套锚点假设在那里
// 不成立 —— 用户实测在微信输入法上也「打不了字」, 所以那条路径整个删掉,
// filter 里也不再挂任何输入法 bundle。
@interface KGKeyboardInstaller : NSObject

+ (instancetype)shared;

// ctor 里调一次: 启动唯一那个「真正干活」的定时器。
- (void)startWorker;

// ---- 布局回调专用: **只观测, 绝不改视图树** ----
- (void)noteHostLayout:(UIView *)host;
- (void)noteContainerLayout:(UIView *)root;

// v0.4.2: 崩溃熔断器。
//
// 背景: v0.4.1 的默认档 (Probe) 每次布局必崩 —— 探针代码拿 NSNotFound 当下标用,
// `if (gi > 0)` 挡不住 (NSNotFound 是 NSUIntegerMax, 转 NSInteger 后 > 0),
// 数组越界抛 NSRangeException, 而它发生在键盘 layoutSubviews 调用链里,
// 键盘一起来就崩 → 反复重启 → **安全模式**。
//
// Objective-C 的 @try 只能抓 NSException, 抓不到野指针 / 栈溢出 / EXC_BAD_ACCESS。
// 所以再加一层: 连续崩溃计数超阈值就把插件整个关掉, 宁可没玻璃也不能再进安全模式。
// 崩溃计数跨进程持久化 (NSUserDefaults), 因为崩溃时内存里的东西全丢。
+ (void)noteHandledException:(NSException *)exception where:(NSString *)where;
+ (BOOL)isCircuitOpen;
+ (void)resetCircuit;

@end
