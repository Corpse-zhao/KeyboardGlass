#import <UIKit/UIKit.h>
#import "KGPrefs.h"

// 键盘玻璃层。
// 自下而上四层:
//   1) 本体   CABackdropLayer + gaussianBlur —— 采样键盘下方的内容做模糊
//   2) 底色   veilLayer  —— 往黑/白方向压, 决定玻璃的「浓度」
//   3) 折射   refractLayer —— 同样采样下方内容, 整体放大后只留边缘一圈,
//              制造内容在边缘被拉伸的折射观感 (scale 模拟, 非真折射)
//   4) 高光   rimLayer —— 边缘环形 CAGradientLayer, 上亮下暗的玻璃轮廓线
@interface KGGlassView : UIView

@property (nonatomic, assign) KGStyle style;

// 调试: 画一圈青色边框 + 半透明品红填充。
// 用来一眼确认「层装上没有、位置尺寸对不对」, 比反复调参数猜快得多。
@property (nonatomic, assign) BOOL showOutline;

- (void)applyStyle:(KGStyle)style;

@end
