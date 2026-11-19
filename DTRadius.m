//
//  DTRadius.m —— P0-1 全局头像圆角
//
//  两种模式：
//    A. 画图替换（默认）—— 离屏裁出带圆角的新图再 setImage:，和 Misaka 的做法一致
//    B. layer 模式 —— 只改 layer.cornerRadius，省内存，但会被别的代码重置
//
//  开关：DTIconRadiusEnable / DTIconRadiusRatio（0.22）/ DTIconfRadiusLayerMode / DTIconfRadiusAll
//

#import <UIKit/UIKit.h>
#import <QuartzCore/QuartzCore.h>
#import "DTHook.h"
#import "DTConfig.h"
#import "DTLog.h"
#import "DTModules.h"

#define kEnable @"DTIconRadiusEnable"
#define kRatio  @"DTIconRadiusRatio"
#define kLayer  @"DTIconRadiusLayerMode"
#define kAll    @"DTIconRadiusAll"

static NSCache<NSString *, UIImage *> *gCache;
static BOOL gLayerMode = NO;
static BOOL gAllViews  = NO;
static double gRatio   = 0.22;
static void (*gOrigSetImage)(id, SEL, UIImage *);

#pragma mark - 判定

static BOOL DTRadiusIsAvatar(id view)
{
    if (gAllViews) return YES;

    NSString *cn = NSStringFromClass([view class]);
    if ([cn rangeOfString:@"Head"].location != NSNotFound)   return YES;
    if ([cn rangeOfString:@"Avatar"].location != NSNotFound) return YES;

    // 微信里头像多半是 MMImageView 之类，靠父视图的类名兜一层
    UIView *sup = [(UIView *)view superview];
    for (int i = 0; i < 3 && sup; i++) {
        NSString *sn = NSStringFromClass([sup class]);
        if ([sn rangeOfString:@"Head"].location != NSNotFound)    return YES;
        if ([sn rangeOfString:@"Avatar"].location != NSNotFound)  return YES;
        if ([sn rangeOfString:@"Contact"].location != NSNotFound) return YES;
        if ([sn rangeOfString:@"Profile"].location != NSNotFound) return YES;
        if ([sn rangeOfString:@"Member"].location != NSNotFound)  return YES;
        sup = [sup superview];
    }
    return NO;
}

#pragma mark - 画图

static UIImage *DTRadiusMakeImage(UIImage *src, CGFloat radius, CGFloat scale)
{
    CGSize px = CGSizeMake(src.size.width * scale, src.size.height * scale);
    if (px.width < 2 || px.height < 2) return src;

    UIGraphicsImageRendererFormat *fmt = [UIGraphicsImageRendererFormat defaultFormat];
    fmt.scale  = scale;
    fmt.opaque = NO;
    UIGraphicsImageRenderer *r = [[UIGraphicsImageRenderer alloc] initWithSize:src.size format:fmt];

    return [r imageWithActions:^(UIGraphicsImageRendererContext *ctx) {
        UIBezierPath *path = [UIBezierPath bezierPathWithRoundedRect:(CGRect){CGPointZero, src.size}
                                                       cornerRadius:radius];
        [path addClip];
        [src drawInRect:(CGRect){CGPointZero, src.size}];
    }];
}

static NSString *DTRadiusCacheKey(UIImage *img, CGFloat radius, CGFloat scale)
{
    // 只按「图片对象 + 半径 + scale」缓存。同一张图在不同尺寸控件里
    // 半径已经不同，所以三者一起构成键，够用了。
    return [NSString stringWithFormat:@"%p|%.1f|%.2f", img, radius, scale];
}

static void DTRadiusSetImage(id self, SEL _cmd, UIImage *img)
{
    if (!img || gRatio <= 0.0) { gOrigSetImage(self, _cmd, img); return; }
    if (!DTRadiusIsAvatar(self)) { gOrigSetImage(self, _cmd, img); return; }

    UIView *v = (UIView *)self;
    CGSize bounds = v.bounds.size;
    if (bounds.width < 24.0 || bounds.height < 24.0) {
        // 太小（图标、表情）就不动，避免糊成一团
        gOrigSetImage(self, _cmd, img);
        return;
    }

    CGFloat shortSide = MIN(bounds.width, bounds.height);
    CGFloat radius = shortSide * gRatio;

    if (gLayerMode) {
        v.layer.cornerRadius = radius;
        v.layer.masksToBounds = YES;
        v.layer.shouldRasterize = YES;
        v.layer.rasterizationScale = [UIScreen mainScreen].scale;
        gOrigSetImage(self, _cmd, img);
        return;
    }

    CGFloat scale = img.scale > 0 ? img.scale : [UIScreen mainScreen].scale;
    NSString *key = DTRadiusCacheKey(img, radius, scale);
    UIImage *hit = [gCache objectForKey:key];
    if (!hit) {
        hit = DTRadiusMakeImage(img, radius, scale);
        if (hit) [gCache setObject:hit forKey:key];
    }
    gOrigSetImage(self, _cmd, hit ?: img);
}

#pragma mark - 安装

void DTModuleRadiusInstall(void)
{
    if (!DTBool(kEnable, NO)) {
        DTLog(@"radius: off");
        return;
    }

    gRatio     = DTDouble(kRatio, 0.22);
    gLayerMode = DTBool(kLayer, NO);
    gAllViews  = DTBool(kAll, NO);

    if (gRatio < 0.0) gRatio = 0.0;
    if (gRatio > 0.5) gRatio = 0.5;

    if (!gCache) {
        gCache = [[NSCache alloc] init];
        gCache.countLimit = 200;
    }

    Class iv = NSClassFromString(@"UIImageView");
    if (!iv) { DTLog(@"radius: 找不到 UIImageView"); return; }

    gOrigSetImage = (void (*)(id, SEL, UIImage *))DTHookMsg(iv, @selector(setImage:), (IMP)DTRadiusSetImage);
    if (!gOrigSetImage) {
        DTLog(@"radius: hook setImage: 失败");
        return;
    }

    DTLog(@"radius: on ratio=%.2f layer=%d all=%d", gRatio, (int)gLayerMode, (int)gAllViews);
}
