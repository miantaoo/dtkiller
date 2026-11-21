//
//  DTBubbleSkin.m —— 参考实现 v1.0.1（assets/review-1.0.1/reference，未加入编译）
//
//  与 v1.0.0 参考实现的差异：
//  1) 新增 schemaVersion，1.0.1 包为 2；旧包为 1。
//  2) 新增 -textColorForSide:appearance:highlighted:，读 manifest 的
//     variants[side].textColor[appearanceKey].color。
//  3) 取图时优先 manifest 的 images 表，明确拒绝 normal* 别名（旧 loader 会把它
//     当 1x 读，capInsets 缩水一半）。
//
//  关键点（沿用 v1.0.0）：
//  - 用 imageWithData:scale: 手动指定 2x/3x，避免 imageWithContentsOfFile:
//    把 @2x 图当成 1x。
//  - capInsets 来自 manifest（单位 pt），不要写死。
//

#import "DTBubbleSkin.h"

#ifndef THEOS_PACKAGE_INSTALL_PREFIX
#define THEOS_PACKAGE_INSTALL_PREFIX ""
#endif

static NSString *const kDTBubbleBundleName = @"DTKillerBubbles.bundle";

@implementation DTBubbleSkin {
    NSString *_identifier;
    NSString *_root;
    NSDictionary *_manifest;
    NSDictionary *_skin;
    NSInteger _schemaVersion;
    NSCache<NSString *, UIImage *> *_cache;
    NSCache<NSString *, UIColor *> *_colorCache;
}

@synthesize identifier = _identifier;
@synthesize schemaVersion = _schemaVersion;

+ (NSArray<NSString *> *)candidateRoots
{
    NSMutableArray<NSString *> *v = [NSMutableArray array];

    const char *env = getenv("DTKILLER_BUBBLE_BUNDLE");
    if (env && env[0]) [v addObject:[NSString stringWithUTF8String:env]];

    NSString *prefix = @THEOS_PACKAGE_INSTALL_PREFIX;
    if (prefix.length) {
        [v addObject:[prefix stringByAppendingPathComponent:
            [@"Library/Application Support/DTKiller" stringByAppendingPathComponent:kDTBubbleBundleName]]];
    }
    [v addObject:[@"/var/jb/Library/Application Support/DTKiller"
                 stringByAppendingPathComponent:kDTBubbleBundleName]];
    [v addObject:[@"/Library/Application Support/DTKiller"
                 stringByAppendingPathComponent:kDTBubbleBundleName]];

    // 用户自己丢进微信容器 Documents 的情况（Filza / 文件 App）
    NSString *docs = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    if (docs.length) {
        [v addObject:[[docs stringByAppendingPathComponent:@"DTKiller"]
                      stringByAppendingPathComponent:kDTBubbleBundleName]];
    }
    [v addObject:[@"/var/mobile/Documents/DTKiller"
                 stringByAppendingPathComponent:kDTBubbleBundleName]];
    return v;
}

+ (nullable instancetype)skinWithIdentifier:(NSString *)identifier
{
    NSString *root = nil;
    NSFileManager *fm = [NSFileManager defaultManager];
    for (NSString *p in [self candidateRoots]) {
        BOOL dir = NO;
        if ([fm fileExistsAtPath:p isDirectory:&dir] && dir) {
            NSString *manifest = [p stringByAppendingPathComponent:@"manifest.json"];
            if ([fm fileExistsAtPath:manifest]) { root = p; break; }
        }
    }
    if (!root) return nil;

    NSData *data = [NSData dataWithContentsOfFile:[root stringByAppendingPathComponent:@"manifest.json"]];
    if (!data) return nil;
    NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data options:0 error:NULL];
    NSDictionary *skin = manifest[@"skins"][identifier];
    if (![skin isKindOfClass:[NSDictionary class]]) return nil;

    DTBubbleSkin *s = [[DTBubbleSkin alloc] init];
    s->_root = [root copy];
    s->_manifest = [manifest copy];
    s->_skin = [skin copy];
    // manifest 顶层写的是 "schema"；"schemaVersion" 是早期草案的键名，兼容一下。
    id schema = manifest[@"schema"] ?: manifest[@"schemaVersion"];
    s->_schemaVersion = [schema isKindOfClass:[NSNumber class]] ? [schema integerValue] : 1;
    s->_cache = [[NSCache alloc] init];
    s->_cache.countLimit = 16;
    s->_colorCache = [[NSCache alloc] init];
    s->_colorCache.countLimit = 8;
    s->_identifier = [identifier copy];
    return s;
}

+ (DTBubbleAppearance)appearanceForTraitCollection:(nullable UITraitCollection *)tc
{
    UITraitCollection *t = tc ?: UITraitCollection.currentTraitCollection;
    if (@available(iOS 12.0, *)) {
        return t.userInterfaceStyle == UIUserInterfaceStyleDark
               ? DTBubbleAppearanceDark : DTBubbleAppearanceLight;
    }
    return DTBubbleAppearanceLight;
}

+ (nullable UIColor *)colorWithHexString:(nullable NSString *)hex
{
    if (![hex isKindOfClass:[NSString class]]) return nil;
    NSString *s = [hex stringByTrimmingCharactersInSet:
                   [NSCharacterSet whitespaceAndNewlineCharacterSet]];
    if ([s hasPrefix:@"#"]) s = [s substringFromIndex:1];
    if (s.length != 6 && s.length != 8) return nil;
    unsigned long long v = 0;
    NSScanner *sc = [NSScanner scannerWithString:s];
    if (![sc scanHexLongLong:&v] || !sc.isAtEnd) return nil;
    CGFloat r, g, b, a = 1.0;
    if (s.length == 8) {
        r = ((v >> 24) & 0xFF) / 255.0;
        g = ((v >> 16) & 0xFF) / 255.0;
        b = ((v >> 8)  & 0xFF) / 255.0;
        a = ( v        & 0xFF) / 255.0;
    } else {
        r = ((v >> 16) & 0xFF) / 255.0;
        g = ((v >> 8)  & 0xFF) / 255.0;
        b = ( v        & 0xFF) / 255.0;
    }
    return [UIColor colorWithRed:r green:g blue:b alpha:a];
}

- (NSString *)appearanceKeyFor:(DTBubbleAppearance)appearance highlighted:(BOOL)highlighted
{
    if (highlighted) {
        return appearance == DTBubbleAppearanceDark ? @"highlight_dark" : @"highlight";
    }
    return appearance == DTBubbleAppearanceDark ? @"dark" : @"light";
}

- (nullable UIImage *)imageForSide:(DTBubbleSide)side
                        appearance:(DTBubbleAppearance)appearance
                       highlighted:(BOOL)highlighted
{
    NSString *sideKey = (side == DTBubbleSideSelf) ? @"self" : @"other";
    NSDictionary *variant = _skin[@"variants"][sideKey];
    if (![variant isKindOfClass:[NSDictionary class]]) return nil;

    NSString *appearanceKey = [self appearanceKeyFor:appearance highlighted:highlighted];

    NSString *cacheKey = [NSString stringWithFormat:@"%@/%@/%@", _identifier, sideKey, appearanceKey];
    UIImage *cached = [_cache objectForKey:cacheKey];
    if (cached) return cached;

    NSDictionary *images = variant[@"images"][appearanceKey];
    if (![images isKindOfClass:[NSDictionary class]]) return nil;

    CGFloat screenScale = UIScreen.mainScreen.scale;
    NSString *scaleKey = screenScale >= 2.9 ? @"3x" : (screenScale >= 1.9 ? @"2x" : @"1x");
    NSString *file = images[scaleKey] ?: images[@"2x"] ?: images[@"1x"];
    if (![file isKindOfClass:[NSString class]]) return nil;
    // 1.0.1 起不再生成 normal*/normal*@2x 之类的别名；若命中说明包是旧的或被改坏。
    if ([file.pathExtension.lowercaseString isEqualToString:@"png"] == NO ||
        [file containsString:@"normal"]) {
        return nil;
    }

    NSString *path = [[_root stringByAppendingPathComponent:_identifier]
                      stringByAppendingPathComponent:file];
    NSData *data = [NSData dataWithContentsOfFile:path options:0 error:NULL];
    if (!data) return nil;

    CGFloat scale = [file hasSuffix:@"@3x.png"] ? 3.0
                  : ([file hasSuffix:@"@2x.png"] ? 2.0 : 1.0);
    UIImage *img = [UIImage imageWithData:data scale:scale];
    if (!img) return nil;

    NSArray *insets = variant[@"capInsets"];
    UIEdgeInsets caps = UIEdgeInsetsMake(18, 20, 18, 26);
    if (insets.count == 4) {
        caps = UIEdgeInsetsMake([insets[0] doubleValue], [insets[1] doubleValue],
                               [insets[2] doubleValue], [insets[3] doubleValue]);
    }

    img = [img imageWithRenderingMode:UIImageRenderingModeAlwaysOriginal];
    img = [img resizableImageWithCapInsets:caps resizingMode:UIImageResizingModeStretch];
    [_cache setObject:img forKey:cacheKey];
    return img;
}

- (nullable UIColor *)textColorForSide:(DTBubbleSide)side
                            appearance:(DTBubbleAppearance)appearance
                           highlighted:(BOOL)highlighted
{
    if (_schemaVersion < 2) return nil;   // 旧包没有颜色契约，交给调用方默认值

    NSString *sideKey = (side == DTBubbleSideSelf) ? @"self" : @"other";
    NSString *appearanceKey = [self appearanceKeyFor:appearance highlighted:highlighted];
    NSString *cacheKey = [NSString stringWithFormat:@"color/%@/%@/%@",
                          _identifier, sideKey, appearanceKey];
    UIColor *cached = [_colorCache objectForKey:cacheKey];
    if (cached) return cached;

    NSDictionary *contract = _skin[@"variants"][sideKey][@"textColor"];
    if (![contract isKindOfClass:[NSDictionary class]]) return nil;
    NSDictionary *entry = contract[appearanceKey];
    if (![entry isKindOfClass:[NSDictionary class]]) return nil;

    UIColor *color = [DTBubbleSkin colorWithHexString:entry[@"color"]];
    if (color) [_colorCache setObject:color forKey:cacheKey];
    return color;
}

@end
