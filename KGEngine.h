#import <UIKit/UIKit.h>
#import "KGPrefs.h"

extern NSString * const KGProbeFilePath;
void KGProbeWrite(NSString *content);

@interface KGEngine : NSObject

+ (instancetype)shared;

// Tweak.x 里唯一的观测入口: 只记下宿主, 一个视图都不碰。
- (void)noteHostLayout:(UIView *)host;
- (void)noteContainerLayout:(UIView *)root;

// 0.4s 定时器。连续两次 frame 完全相同才动手。
- (void)startWorker;
- (void)stopWorker;

@end
