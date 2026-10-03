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

// KGStyle 是 struct, 不能用 isEqual: 比。
// 之前这个函数住在已删掉的 KGKeyboardInstaller.h 里, 引擎合并成 KGEngine.m 后
// 漏了搬过来 —— CI 报 "call to undeclared function 'KGStyleEqual'"。
// 凡是跨文件比较 KGStyle, 一律用这个, 别自己写 memcmp。
static inline BOOL KGStyleEqual(KGStyle a, KGStyle b) {
    return a.blur == b.blur
        && a.refraction == b.refraction
        && a.highlight == b.highlight
        && a.veil == b.veil
        && a.cornerRadius == b.cornerRadius
        && a.dark == b.dark;
}

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
// 【v3.0.0】推翻重做 —— 架构从「多动作二分」改成「两处定点」
// ======================================================================
//
// 【v1.1.0 探针 253MB 全量数据(157 棵全树)定案】
// 微信输入法态(顶层窗口 UIRemoteKeyboardWindow, 含 SquidExtender.* / TUI*)下实测:
//
//   0UIRemoteKeyboardWindow        430x932 uie=1
//    1 UIInputSetContainerView     430x932 uie=1
//     2 UIInputSetHostView         {0,576},{430,356} uie=1   ← 宿主, 键盘区
//      3 UIKBInputBackdropView     430x311 uie=0
//       4 UIKBBackdropView         430x311 uie=1 bg=白/0.10  ← 键盘底板
//        5 _UIVisualEffectBackdropView 430x311 uie=0
//      3 UIKBInputBackdropView     430x45  uie=0
//       4 UIKBBackdropView         430x45  uie=1 bg=白/0.10   ← 工具条底板
//        5 _UIVisualEffectBackdropView 430x45  uie=0
//      3 UIKeyboardAutomatic → UIKeyboardLayoutStar → UIKBKeyplaneView
//          UIKBSplitImageView x3 (uie=0) / UIKBKeyView x5 (uie=0)
//
// 【三个被数据推翻的旧结论】
// 1. v2.0.0「按键在输入法扩展进程」**错**。按键层在宿主进程里, 层级完整。
//    (我上一轮只看 tail 截断片段就下的跨进程结论, 全量统计已纠正)
// 2. 十三版「玻璃层插在宿主里」导致看不见**有确切物证**: 探针里那行
//    `2 KGGlassView {0,0},{430,932}` —— 全屏大小, 而键盘只有 356pt 高。
//    玻璃比键盘大 5 倍且z序在按键之上, 观感是「更浑浊」不是「更透」。
// 3.键盘「实心浅灰」的元凶是 **UIKBBackdropView 上那层 bg=白/0.10**,
//    不是 _UIVisualEffectBackdropView。十三版一直在调后者, 所以永远差一口。
//
// ======================================================================
// 【v3.0.1 —— `+backdropWhiteness` 已删除, 且**不要**再加回来】
// ======================================================================
// v3.0.0 有这个访问器, 它会去写 `UIKBBackdropView`(uie=1 系统视图)的
// backgroundColor。用户装 v3.0.0 后反馈疑似系统异常(自己描述「注销」),
// 已卸载。**不确定是不是它造成的** —— 但「不确定」本身就是撤回的理由。
//
// 我当时给破例找的理由是「只改 backgroundColor 不改变 hitTest 参与性」。
// 这个论证有个**从未验证的前提**: 假定这个属性无人竞争、只有我们在写。
// 只要系统在别处也写它(深浅色/材质/键盘形态切换都会重配底板), 就构成
// 一个看不见的反馈环。**我没有任何证据说它安全, 却已经交付了。**
//
// v1.0.0 立的铁律是「只允许改 uie=0 的层」, 十三版有两次安全模式
// (v0.4.1 / v0.4.2)都来自「改系统视图」。**没有证据就破铁律,
// 这正是十三版栽了十三次的地方。**
//
// 那层白怎么压? **用玻璃盖住它** —— 玻璃自带veil 底色 + 模糊, 插在
// uie=0 的 `UIKBInputBackdropView` 里就等效于把白压下去, 而这个动作
// 全程不碰任何 uie=1 的层。**v3.0.0 想要的效果, 不需要碰系统底板。**
//
// 参数版本已升到 12, 迁移时会把存档里的 `BackdropWhiteness` 清掉。
// ======================================================================
//
// v2.0.0 的 ExtProbe / HostKeyboardActions 已随探针文件一起删除。
// 纯探针期结束, 回到「装了就有效果」。

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
