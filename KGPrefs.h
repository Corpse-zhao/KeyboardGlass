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

// 工作模式 —— 二分隔离用的, 一次安装就能连测几档, 不用反复重装。
//
// 【重要】默认必须是 KGWorkModeProbe —— 唯一一档被用户实测过「能打字」的。
// 其余各档都在验证中: v0.3.0~0.4.0 期间, 我曾因为「玻璃层是纯 CALayer,
// hitTest 只遍历 view, 所以不可能挡触摸」而把默认设成 Full。这个推理是错的:
// 那句话从没被验证过 —— 用户当时能打字用的是 Probe/Hide 档, 而那两档
// 根本不插玻璃层。v0.4.0 开了 Full 之后用户立刻反馈「又不能点击了」。
// **「机制上不可能」不等于「实测不会」, 别拿推理当实测。**
//
//   Probe: 只 hook、只写探针, 一个节点都不碰 —— 唯一验证过安全的基准档
//   Hide : 额外只做一件事: 把某**一**层原生背景 alpha 归零
//   Glass: 插玻璃层, 但**完全不碰原生背景** ← 隔离「玻璃层本身是否挡触摸」
//   Full : 玻璃层 + 藏背景 (Hide 与 Glass 的组合)
typedef NS_ENUM(NSInteger, KGWorkMode) {
    KGWorkModeProbe = 0,   // 纯探针: 完全不碰视图树
    KGWorkModeHide  = 1,   // 只隐藏一层原生背景
    KGWorkModeGlass = 2,   // 只插玻璃层, 不动原生背景
    KGWorkModeFull  = 3,   // 完整: 玻璃层 + 藏背景
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

// v0.4.2: 玻璃层插在按键之上还是之下。
//
// 玻璃层插在按键**之下**时, 只有键与键之间的缝隙透出玻璃, 按键区自带的那层
// 不透明底色仍然压在玻璃上方 —— 用户反馈原话是「背景透明了, 就是按键没透明」。
// 改成插在按键**之上**, 整块键盘(含按键区)才都变成玻璃, 就是 iOS 26 的观感。
//
// 代价: 玻璃会盖住按键。**能不能打字必须实测**, 所以默认 NO, 由用户主动开。
// 又一次「机制上推断 ≠ 实测」—— 上次就是信了推断才翻的车。
+ (BOOL)glassOverKeys;

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
