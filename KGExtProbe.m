// ======================================================================
// 【v2.0.0 新增】第三方输入法(微信输入法)进程探针 —— 纯观测, 零改动
// ======================================================================
//
// 【为什么必须有这个文件】
// 2026-10-03 的 v1.1.0 探针回报实锤: 宿主进程(UITextEffectsWindow)里
// 只有 `_UIRemoteKeyboardPlaceholderView`(430x288) 这个**远程占位视图**,
// 一个按键都没有。按键是输入法扩展进程画的, 通过远程视图嵌进宿主。
//
// 而本插件的 dylib 现在只注入到**宿主 App 进程**。宿主进程里根本没有
// 按键的视图, 所以 v0.1.0~v1.1.0 十三版对「按键区底板/按键本体」做的
// 所有 alpha/blur 调整, 物理上不可能生效 —— 这不是调得不够, 是打错了地方。
//
// 【这个文件干什么】
// 在**输入法扩展进程**里把按键视图树 dump 出来。微信输入法的按键区
// 是自绘的, 类名大概是 WX / WeChat / Keyboard 前缀, 未知。所以策略是
// 「不认类名, 只认形状」: 在扩展进程的每个 UIWindow 布局回调里, 找出
// 宽接近屏宽、高 150~600、且在屏上的根视图, 整棵 dump 出来。
//
// 【铁律 —— 一行都不许改】
// 整个文件只有 dump 和写文件, **不改任何视图属性、不加任何 subview**。
// 微信输入法的按键区 uie=1, 碰它必然出输入故障。
// 这次只做一件事: 把真实层级看清楚。看得见之后, 第二步才知道该改哪。
//
// 【为什么先探针不上手】
// 十三版每版同时改好几个变量, 反馈全是「还是啥都没解决」。
// 根因是我从来没先看清过目标长什么样。这一版只探, 不改。
// ======================================================================

#import <UIKit/UIKit.h>

static NSString * const kKGExtProbeDir  = @"/var/mobile/Documents/KeyboardGlass";
static NSString * const kKGExtProbeFile = @"/var/mobile/Documents/KeyboardGlass/ext_probe.txt";

static NSString *KGExtProcName(void) {
    return [NSProcessInfo processInfo].processName ?: @"?";
}

static void KGExtWrite(NSString *content) {
    // 扩展进程是 App 沙盒, 写不进 /var/mobile/Documents(除非有 root 权限;
    // 输入法扩展通常没有)。所以双写: 沙盒 Documents 一定写得进去,
    // /var/mobile 那个写不进去就跳过, 不报错。
    NSData *data = [content dataUsingEncoding:NSUTF8StringEncoding];
    NSString *sandbox =
        [[NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES) firstObject]
            stringByAppendingPathComponent:@"kg_ext_probe.txt"];
    // ------------------------------------------------------------------
    // 【为什么这里不用 @try】v2.0.0 第一次构建就是挂在这一行:
    //     KGExtProbe.m:48:9: error: @try statement without a @catch and @finally
    //     KGExtProbe.m:72:11: error: call to undeclared function 'catch'
    // Logos 的预处理器把 `@catch` 当成自己的 `@c` 指令吃掉了, 吐出裸的
    // `catch (NSException *e) {` —— C++ 语法在 .m 文件里当然编译不过。
    //
    // 与其斗智斗勇绕开 Logos, 干脆**不用异常处理**: 下面每一步都用
    // 返回值判断, 任何一步失败就直接跳到下一个路径。NSFileManager 的
    // 方法在路径不可写时返回 NO + 填充 error, 不会抛异常, 所以
    // 「返回值判断」已经足够, @try 属于多余。
    // ------------------------------------------------------------------
    for (NSString *path in @[kKGExtProbeFile, sandbox]) {
        NSFileManager *fm = NSFileManager.defaultManager;
        NSString *dir = [path stringByDeletingLastPathComponent];
        if (![fm fileExistsAtPath:path] && ![fm fileExistsAtPath:dir]) {
            if (![fm createDirectoryAtPath:dir
                withIntermediateDirectories:YES
                                 attributes:nil
                                      error:NULL]) {
                continue;   // 建不了目录(沙盒受限), 试下一个路径
            }
        }
        // 写太快会让文件长到几百 MB(十三版实测 253MB, 根本没法看)。
        // 每次 dump 之前先查体积, 超过 512KB 就先清空再写。
        unsigned long long sz =
            [[fm attributesOfItemAtPath:path error:NULL] fileSize];
        if (sz > 512 * 1024) {
            if (![data writeToFile:path atomically:YES]) continue;
        } else {
            NSFileHandle *h = [NSFileHandle fileHandleForUpdatingAtPath:path];
            if (h) {
                [h seekToEndOfFile];
                [h writeData:data];
                [h closeFile];
            } else {
                if (![data writeToFile:path atomically:YES]) continue;
            }
        }
    }
}

// 形状判定: 这是一个「键盘大小的视图」吗
// 不看类名, 因为微信输入法的类名我不知道, 而且版本升级就变。
static BOOL KGExtLooksLikeKeyboard(UIView *v) {
    if (!v) return NO;
    CGRect b = v.bounds;
    CGFloat screenW = UIScreen.mainScreen.bounds.size.width;
    if (screenW <= 0) return NO;
    // 宽度: 至少 85% 屏宽(排除状态栏/小挂件)
    if (b.size.width < screenW * 0.85) return NO;
    // 高度: 键盘量级。太大(>800)可能是全屏视图, 太小(<120)可能是工具条
    if (b.size.height < 120 || b.size.height > 800) return NO;
    return YES;
}

static void KGExtDumpTree(UIView *v, NSInteger depth, NSMutableString *out, NSInteger *budget) {
    if (!v || !budget || *budget <= 0 || depth > 24) return;
    (*budget)--;
    CGFloat r, g, b, a;
    NSString *bg = @"-";
    if (v.backgroundColor && [v.backgroundColor getRed:&r green:&g blue:&b alpha:&a]) {
        bg = [NSString stringWithFormat:@"%.2f/%.2f/%.2f/%.2f", r, g, b, a];
    }
    for (NSInteger i = 0; i < depth; i++) [out appendString:@"  "];
    [out appendFormat:@"%@ | %@ a=%.2f h=%d uie=%d %@ bg=%@\n",
        NSStringFromClass(v.class), NSStringFromCGRect(v.frame),
        v.alpha, v.hidden, v.userInteractionEnabled,
        v.userInteractionEnabled ? @"[UI层·不可碰]" : @"[视觉层·可碰]",
        bg];
    for (UIView *sub in v.subviews) {
        KGExtDumpTree(sub, depth + 1, out, budget);
    }
}

@interface KGExtProbe : NSObject
@end

@implementation KGExtProbe

+ (void)start {
    // 0.9s 后开始观测: 等扩展把自己的窗口建好
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.9 * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
        KGExtWrite([NSString stringWithFormat:
            @"\n==== [扩展进程] %@ 已注入 v2.0.0 屏宽=%.0f ====\n",
            KGExtProcName(), UIScreen.mainScreen.bounds.size.width]);
    });
    // 每 1.2s 扫一次窗口, 找到键盘大小的就 dump
    [NSTimer scheduledTimerWithTimeInterval:1.2
                                     repeats:YES
                                       block:^(NSTimer *t) {
        [self scan];
    }];
}

+ (void)scan {
    if (!NSThread.isMainThread) return;
    for (UIScene *sc in UIApplication.sharedApplication.connectedScenes) {
        if (![sc isKindOfClass:UIWindowScene.class]) continue;
        for (UIWindow *w in ((UIWindowScene *)sc).windows) {
            [self dumpWindowIfKeyboardShaped:w];
        }
    }
}

+ (void)dumpWindowIfKeyboardShaped:(UIWindow *)w {
    if (w.hidden || w.alpha < 0.01) return;
    for (UIView *v in w.subviews) {
        if (!KGExtLooksLikeKeyboard(v)) continue;
        // 命中一个键盘形状的根视图 -> 整棵 dump
        NSMutableString *out = [NSMutableString string];
        [out appendFormat:@"==== [%@] 进程=%@ 键盘根视图 ====\n",
            [NSDate date], KGExtProcName()];
        NSInteger budget = 300;
        KGExtDumpTree(v, 0, out, &budget);
        [out appendFormat:@"\n[层数预算剩余 %ld, 若为 0 说明还有更深的层没dump到]\n", (long)budget];
        KGExtWrite(out);
    }
}

@end
