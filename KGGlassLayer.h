#import <UIKit/UIKit.h>
#import "KGPrefs.h"

// 键盘玻璃层 —— 注意这是 CALayer, 不是 UIView。
//
// 为什么必须是 Layer (v0.2.3 定论):
//   v0.2.0~0.2.2 都是往键盘里塞一个 UIView, 结果用户反复反馈「玻璃那一片点不动」。
//   稳定态快照给出了实锤: 系统按键视图 UIKBKeyView 自己就是 userInteractionEnabled=0,
//   而且在键盘区域做 hitTest 全部返回 nil —— 说明这个键盘窗口的触摸根本不走
//   App 这边的 hitTest 派发。往里面加 UIView 是在赌系统触摸路由的实现细节。
//   CALayer 不参与触摸命中 (hitTest 只遍历 view), 加多少层都不可能挡触摸 ——
//   从机制上把这个风险归零。
//
// 自下而上四层:
//   1) 本体   backdropLayer (CABackdropLayer) + gaussianBlur —— 采样键盘下方内容
//   2) 底色   veilLayer  —— 往黑/白方向压, 决定玻璃的「浓度」
//   3) 折射   refractLayer —— 同款 backdrop 放大后只留边缘一圈, 模拟边缘折射
//   4) 高光   rimLayer —— 边缘环形 CAGradientLayer, 上亮下暗的玻璃轮廓线
@interface KGGlassLayer : CALayer

@property (nonatomic, assign) KGStyle kgStyle;   // 不能叫 style —— CALayer 自带 NSDictionary *style
@property (nonatomic, assign) BOOL darkMode;

// 调试: 画一圈青色边框 + 半透明品红填充, 用来确认层装上没有、位置对不对
@property (nonatomic, assign) BOOL showOutline;

- (void)applyStyle:(KGStyle)style dark:(BOOL)dark;

@end
