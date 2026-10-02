#import <UIKit/UIKit.h>

// Preferences 私有类的最小声明 (bundle 内符号运行时解析)
@interface PSSpecifier : NSObject
- (id)propertyForKey:(NSString *)key;
@end

@interface PSTableCell : UITableViewCell
- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier;
@end

// 带标题和数值的滑块行: [标题 | ——●—— | 数值]
// 原生 PSSliderCell 不渲染 label 文本, 所以照 GlassSuiteX 的 GAXSliderCell 思路自己写。
// 单行布局 (44pt), 不需要动表格行高, 风险最低。
@interface KGSliderCell : PSTableCell
@end
