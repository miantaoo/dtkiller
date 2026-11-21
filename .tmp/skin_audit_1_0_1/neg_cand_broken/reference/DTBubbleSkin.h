//
//  DTBubbleSkin.h —— 参考实现 v1.0.1（仅存放于 assets/review-1.0.1/reference，
//  未加入任何 Makefile / DTBatch2.m，不参与编译，不随 deb 分发）
//
//  读取 DTKillerBubbles.bundle/manifest.json，按 self/other、明/暗、按压态、
//  1x/2x/3x 返回已经切好九宫格的 UIImage，并从 manifest 的 colorContract
//  取出该外观对应的文字颜色。
//

#import <UIKit/UIKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, DTBubbleSide) {
    DTBubbleSideOther = 0,
    DTBubbleSideSelf  = 1,
};

typedef NS_ENUM(NSInteger, DTBubbleAppearance) {
    DTBubbleAppearanceLight = 0,
    DTBubbleAppearanceDark  = 1,
};

@interface DTBubbleSkin : NSObject

@property (nonatomic, copy, readonly) NSString *identifier;

/// manifest 的 schema（1.0.1 = 2）；1.0.0 旧包为 1（无颜色契约、含 normal* 别名）。
@property (nonatomic, assign, readonly) NSInteger schemaVersion;

/// 找不到 bundle / manifest / 皮肤时返回 nil。
+ (nullable instancetype)skinWithIdentifier:(NSString *)identifier;

/// 当前 trait 对应的明暗；iOS 15+ 直接用 userInterfaceStyle。
+ (DTBubbleAppearance)appearanceForTraitCollection:(nullable UITraitCollection *)tc;

/// 返回已应用 cap insets 的图；文件缺失时返回 nil（调用方回退内置绘制）。
- (nullable UIImage *)imageForSide:(DTBubbleSide)side
                        appearance:(DTBubbleAppearance)appearance
                       highlighted:(BOOL)highlighted;

/// 该外观/侧/按压态下的文字颜色（manifest colorContract）。
/// schemaVersion < 2 或缺少契约时返回 nil —— 调用方必须保留自己的默认取色，
/// 不要用白色兜底，否则亮色皮肤会出现白字压浅底不可读。
- (nullable UIColor *)textColorForSide:(DTBubbleSide)side
                            appearance:(DTBubbleAppearance)appearance
                           highlighted:(BOOL)highlighted;

/// "#RRGGBB" / "#RRGGBBAA" / "RRGGBB" 解析；非法返回 nil。
+ (nullable UIColor *)colorWithHexString:(nullable NSString *)hex;

@end

NS_ASSUME_NONNULL_END
