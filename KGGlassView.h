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
// 【v0.6.0 修正上面那段「关于触摸」的结论】
// v0.5.2 以为「显式 uie=NO 就绝对安全」, 结果实测**照样打不了字**。
// 加上 v0.2.0 那次,「玻璃盖在按键之上」已经翻车两次(架构完全不同, 结论一致):
//   v0.2.0 (纯 CALayer):       打开就「打不了字」
//   v0.5.2 (UIView + uie=NO): 打开仍然「打不了字」
// 所以 v0.6.0 把 GlassOverKeys 开关整个删掉, **玻璃永远在按键之下**, 没有例外。
// 「机制上不可能」不等于「实测不会」—— 这已经是第三次栽在这句话上, 别再写回去。
//
// 【v3.0.0 这块的重做 —— 由 v1.1.0 探针 253MB 全量数据驱动】
// 十三版把这块玻璃插在**宿主视图**里, 探针实测到的那一行是:
//     2 KGGlassView {0,0},{430,932} a=1.00 uie=0
// 而宿主 UIInputSetHostView 是 {{0,576},{430,356}} —— 玻璃是**全屏 932 高**,
// 比键盘大 5 倍多, z 序又在按键之上, 于是它糊住了整个屏幕底部。
// 观感上就是「键盘更白了」, 而不是「更透了」, 用户当然说没效果。
//
// v3.0.0 改法: 玻璃插到 `UIKBInputBackdropView` 里、与系统底板 `UIKBBackdropView`
// 平级, **尺寸严格等于底板**。z 序 = 底板之上、按键层之下, 严守v0.6.0 的教训。
//
// 【另: 键盘「实心浅灰」的元凶不是这块玻璃】
// 探针实测 `UIKBBackdropView` 的 backgroundColor = 白/alpha 0.10, 铺满键盘区。
// v0.7.x~v1.1.0 一直在调 _UIVisualEffectBackdropView(效果图层) 的 alpha,
// 调错了对象。v3.0.0 改由 KGEngine 直接调 UIKBBackdropView 的白(只写
// backgroundColor 这一个属性, 不动它的 subview / frame / alpha)。
//
// z 序由 KGEngine 负责: **永远插在按键层之下** = 背景之上、按键之下。

@interface KGGlassView : UIView

@property (nonatomic, assign) KGStyle kgStyle;
@property (nonatomic, assign) BOOL darkMode;
@property (nonatomic, assign) BOOL showOutline;

// 当前生效的 UIBlurEffect 档位。模糊本体建起来没有、用的第几档, 看这一个数字。
@property (nonatomic, readonly) NSInteger activeEffectStyle;

- (void)applyStyle:(KGStyle)style dark:(BOOL)dark;

@end
