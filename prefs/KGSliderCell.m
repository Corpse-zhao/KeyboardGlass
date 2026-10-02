#import "KGSliderCell.h"

static NSString * const kKGPrefsDomain = @"com.banli.keyboardglass.preferences";

@implementation KGSliderCell {
    UILabel *_titleLabel;
    UILabel *_valueLabel;
    UISlider *_slider;
    PSSpecifier *_specifier;
    NSString *_key;
    NSString *_suffix;
    NSUserDefaults *_defaults;
    CGFloat _max;
}

- (id)initWithStyle:(UITableViewCellStyle)style reuseIdentifier:(NSString *)reuseIdentifier specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style reuseIdentifier:reuseIdentifier specifier:specifier];
    if (!self) return nil;

    _specifier = specifier;
    _key = [specifier propertyForKey:@"key"];
    _suffix = [specifier propertyForKey:@"valueSuffix"] ?: @"";
    CGFloat minimum = [[specifier propertyForKey:@"min"] doubleValue];
    _max = [[specifier propertyForKey:@"max"] doubleValue];
    _defaults = [[NSUserDefaults alloc] initWithSuiteName:kKGPrefsDomain];

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.clipsToBounds = YES;
    // 关键: 基类自带的 textLabel 会被 Preferences 填上同一个标题,
    // 和自己的 titleLabel 叠成重影 —— 必须藏掉
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    UIColor *text = [UIColor labelColor];

    _titleLabel = [UILabel new];
    _titleLabel.text = [specifier propertyForKey:@"label"] ?: @"";
    _titleLabel.font = [UIFont systemFontOfSize:16];
    _titleLabel.textColor = text;
    [self.contentView addSubview:_titleLabel];

    _valueLabel = [UILabel new];
    _valueLabel.font = [UIFont monospacedDigitSystemFontOfSize:14 weight:UIFontWeightRegular];
    _valueLabel.textColor = [UIColor secondaryLabelColor];
    _valueLabel.textAlignment = NSTextAlignmentRight;
    [self.contentView addSubview:_valueLabel];

    _slider = [UISlider new];
    _slider.minimumValue = minimum;
    _slider.maximumValue = _max;
    double saved = [_defaults objectForKey:_key] ? [_defaults doubleForKey:_key] : [[specifier propertyForKey:@"default"] doubleValue];
    _slider.value = saved;
    [_slider addTarget:self action:@selector(kgSliderChanged:) forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_slider];

    [self kgRefreshValueText:saved];
    return self;
}

- (void)kgRefreshValueText:(double)value {
    NSString *format = (_max > 2.0) ? @"%.1f%@" : @"%.2f%@";
    _valueLabel.text = [NSString stringWithFormat:format, value, _suffix];
}

- (void)kgSliderChanged:(UISlider *)slider {
    double value = slider.value;
    [_defaults setDouble:value forKey:_key];
    [_defaults synchronize];
    [self kgRefreshValueText:value];
}

- (void)layoutSubviews {
    [super layoutSubviews];
    // Preferences 刷新 cell 内容时可能把 textLabel 重新点亮, 这里再压一次
    self.textLabel.hidden = YES;
    self.detailTextLabel.hidden = YES;

    CGFloat width = self.contentView.bounds.size.width;
    CGFloat height = self.contentView.bounds.size.height;
    if (width <= 0) return;

    CGFloat pad = 16.0, labelWidth = 120.0, valueWidth = 78.0, gap = 10.0;
    _titleLabel.frame = CGRectMake(pad, 0, labelWidth, height);
    _valueLabel.frame = CGRectMake(width - pad - valueWidth, 0, valueWidth, height);
    _slider.frame = CGRectMake(pad + labelWidth + gap, (height - 31.0) / 2.0,
                               width - pad - labelWidth - gap - valueWidth - gap, 31.0);
}

@end
