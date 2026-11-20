//
//  DTBuild.h —— 版本号的唯一来源
//
//  Makefile 每次解析时把 out/dt/VERSION 生成成 DTVersion.h：
//      #define DT_BUILD_VERSION "0.2.0"
//  这里用 __has_include 引进来，文件不在时退回 "0.0.0-dev"，不会编译失败。
//
//  要升版本：只改 out/dt/VERSION 一行。control、deb 包名、产物文件名全部跟着走。
//  任何 .m / .h 里都不要硬编码版本号。
//

#if __has_include("DTVersion.h")
#import "DTVersion.h"
#endif

#ifndef DT_BUILD_VERSION
#define DT_BUILD_VERSION "0.0.0-dev"
#endif

/// 字符串字面量，可以直接用在 @"..." 的位置，也可以 %@ 格式化
#define DT_DYLIB_VERSION @DT_BUILD_VERSION
