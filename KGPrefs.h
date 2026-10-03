#import <UIKit/UIKit.h>

// 材质分档, 与设置面板的「玻璃材质」分段一一对应
typedef NS_ENUM(NSInteger, KGMaterial) {
    KGMaterialOff    = -1,  // 关闭: 完全还原系统原样
    KGMaterialUltra  = 0,   // 超薄
    KGMaterialThin   = 1,   // 薄
    KGMaterialStd    = 2,   // 标准
    KGMaterialLiquid = 3,   // 液态玻璃: 使用用户自定义的四个参数
};

// 一套完整的外观参数
typedef struct KGStyle {
    CGFloat blur;          // 模糊强度 pt
    CGFloat refraction;    // 边缘折射 pt
    CGFloat highlight;     // 高光强度 0-1
    CGFloat veil;          // 底色浓度 0-1
    CGFloat cornerRadius;  // 顶部圆角 pt
    BOOL    dark;          // 是否深色模式
} KGStyle;

// 工作模式 —— 二分隔离用的, 一次安装就能连测三档, 不用反复重装。
// 用户反馈「键盘打不了字」, 但始终无法确定是「我们改视图树」还是「hook 本身 /
// 与其它键盘插件冲突」造成的。所以把「我们到底做多少事」做成可调开关:
//   Probe: 只 hook、只写探针, 一个节点都不碰 —— 最干净的比对基准
//   Hide : 额外只做一件事: 把原生背景层 alpha 归零
//   Full : 完整效果 (插玻璃层 + 隐藏背景)
typedef NS_ENUM(NSInteger, KGWorkMode) {
    KGWorkModeProbe = 0,   // 纯探针: 完全不碰视图树
    KGWorkModeHide  = 1,   // 只隐藏原生背景层
    KGWorkModeFull  = 2,   // 完整: 插入玻璃层
};

extern NSString * const KGPrefsSuiteName;

@interface KGPrefs : NSObject

+ (void)registerDefaults;
+ (NSUserDefaults *)defaults;

+ (KGMaterial)material;
+ (KGStyle)styleForMaterial:(KGMaterial)material dark:(BOOL)dark;
+ (KGStyle)styleForCurrentMaterialDark:(BOOL)dark;

// 调试: 键盘尺寸百分比 (70-100), 与玻璃无关, 独立开关
+ (CGFloat)keyboardScale;
+ (BOOL)scaleEnabled;

+ (BOOL)hideNativeBackdrop;
+ (BOOL)debugLog;

// 工作模式 (二分隔离用, 见 KGWorkMode 注释)
+ (KGWorkMode)workMode;

// 调试: 在玻璃层四周画一圈青色边框、内部铺半透明品红。
// 用来一眼确认「层到底装上了没有、位置尺寸对不对」—— 比调参数猜要快得多。
+ (BOOL)showLayerOutline;

// 一次性参数迁移: 早期版本的默认值 (blur 5 / veil 0) 几乎完全不可见,
// 用户点不出效果就会以为插件没生效。这里只迁移一次, 迁移后用户自己的
// 调整不会再被覆盖。
+ (BOOL)needsParamsMigration;
+ (void)runParamsMigrationIfNeeded;

// 推荐参数: 在键盘上肉眼可辨的一组值
+ (void)writeRecommendedParams;

@end

// 统一的日志出口: 调试开关打开时走 NSLog, 否则静默
void KGLog(NSString *format, ...);
