TARGET := iphone:clang:latest:15.0
ARCHS := arm64 arm64e

include $(THEOS)/makefiles/common.mk

TWEAK_NAME := DTKiller

DTKiller_FILES := $(wildcard *.m)
DTKiller_CFLAGS := -fobjc-arc -O2 -fvisibility=hidden \
                   -Wno-unused-function -Wno-unused-variable -Wno-deprecated-declarations \
                   -Wno-nullability-completeness -Wno-objc-multiple-method-names
DTKiller_FRAMEWORKS := UIKit Foundation AVFoundation CoreMedia CoreGraphics QuartzCore \
                       CallKit UserNotifications AudioToolbox
DTKiller_PRIVATE_FRAMEWORKS :=
DTKiller_LDFLAGS := -undefined dynamic_lookup

# 不依赖 CydiaSubstrate / ElleKit：所有 hook 走 ObjC runtime（见 DTHook.m）
DTKiller_LIBRARIES :=

# ---------------------------------------------------------------------------
# 可选：SILK 编码器（音乐 / 视频 → 语音 需要它）
#
#   git clone https://github.com/kn007/silk-v3-decoder
#   cp -R silk-v3-decoder/silk vendor/silk
#   rm -rf vendor/silk/src/*.S          # 32 位 ARM 汇编，arm64 不能编
#
# 只保留 interface/ 与 src/。SRC 是 BSD 式许可（Skype SILK 1.0.9），
# 注意它不授予专利许可，自用没问题，别商用分发。
# ---------------------------------------------------------------------------
SILK_DIR := vendor/silk
ifneq ($(wildcard $(SILK_DIR)/src/SKP_Silk_SDK_API.c),)
DTKiller_CFLAGS += -I$(SILK_DIR)/interface -I$(SILK_DIR)/src -DNO_ASM \
                   -Wno-implicit-function-declaration -Wno-shorten-64-to-32
DTKiller_FILES += $(wildcard $(SILK_DIR)/src/*.c)
else
$(info [DTKiller] vendor/silk 不存在 —— SILK 编码功能将编译为空实现)
endif

include $(THEOS_MAKE_PATH)/tweak.mk

after-install::
	install.exec "killall -9 WeChat || true"
