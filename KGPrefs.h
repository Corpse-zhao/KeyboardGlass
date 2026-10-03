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

// 调试: 在玻璃层四周画一圈青色边框、内部铺半透明品红。
// 用来一眼确认「层到底装上了没有、位置尺寸对不对」—— 比调参数猜要快得多。
+ (BOOL)showLayerOutline;

// v1.0.0 新增: 玻璃通透度 0-1, 滑块名字叫「玻璃通透度」。
//
// 它控制的是**系统自己那层 85% 浓白** (_UIVisualEffectBackdropView,
// uie=0) 的调淡程度。实测这层才是键盘「实心浅灰」的真正元凶 ——
// v0.7.0~0.7.4 一直在调别的层, 所以怎么调都不对。
//
// 0   = 完全保持系统原样(实心浅灰)
// 1   = 调到最透(玻璃感最强, 但按键文字可能不够清楚)
// 0.65= 推荐: 既有明显玻璃感, 又保证按键字看得清
+ (CGFloat)glassTransparency;

// 按键区底色调淡 0-1。作用在 UIKBSplitImageView (实测 uie=0 纯视觉层)。
//
// 【v1.0.0 语义已变】v0.7.3 那个 0.55「触摸安全下限」是基于
// 「它是触摸层」的误判, 实测该层 uie=0, 本来就与触摸派发无关。
// 下限已整个删除, 这个滑块重新变回纯观感控制, 拖到 0.9 也只影响外观。
+ (CGFloat)keyplaneDim;

// ======================================================================
// 【v2.0.0】架构已改: 微信输入法 vs 系统键盘, 两条完全不同的路
// ======================================================================
//
// 【v1.1.0 探针实锤, 这一版是它推出来的】
// 宿主进程(UITextEffectsWindow)里只有 `_UIRemoteKeyboardPlaceholderView`
// (430x288) 这个远程占位视图, **一个按键视图都没有**。所以:
//
//   - 系统键盘路径(本插件一直在做的): 按键在宿主进程里, 是 UIKBKeyplaneView
//     等 UIKB* 类。改它们的 alpha 理论上有效 —— 但 v1.1.0 探针也证明,
//     十三版调的那几个层(含所谓的「全屏白底 _UIRemoteView」)在 iOS 16 上
//     **根本不存在**, 所以既没效果也可能留了残改。
//   - 微信输入法路径: 按键在**输入法扩展进程**里自绘, 通过远程视图嵌进宿主。
//     宿主进程里改什么都碰不到它。必须在扩展进程里动手。
//
// 【所以现在只有两个开关, 而不是 v1.1.0 的六个】
// 六个开关是在「宿主进程里改宿主层」这个错误前提下设计的二分,
// 前提没了, 开关也就没意义了。留两个:
//   - extProbe          扩展进程探针(默认开): dump 微信输入法按键层级, 只读
//   - hostKeyboardActions 宿主旧逻辑(默认关): 保留十三版代码, 留作对照
//
// 【为什么不是直接上效果】
// 十三版每版同时改好几个变量, 反馈全是「还是啥都没解决」。
// 根因是我从来没先看清过微信输入法的按键区长什么样。
// 这一版**只探不改**, 先把目标看清楚 —— 十五版以来第一次这么做。
+ (BOOL)extProbe;
+ (BOOL)hostKeyboardActions;

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
