# DTBubbles 1.0.1 候选包审计报告

生成器：`tools/audit_bubbles_1_0_1.py`（仅标准库：PNG 解码 + CRC + zlib，无 numpy / 无 Pillow）

运行环境：CPython 3.10.11

## 结论

- 自动检查：**FAIL**（失败 5 项）
- PNG：47 张，被 manifest 引用 48 张；bundle 84464 字节；zip 87672 字节 / 52 项
- alpha 镜像：23/23 组逐位一致
- 文字契约：16 组，最低实测对比度 6.79:1

## 失败项

- `bundle.count` disk has 47 PNG, expect 48
- `bundle.missing` qq9/bubble_other_dark@3x.png
- `png.missing` DTKillerBubbles.bundle/qq9/bubble_other_dark@3x.png
- `zip.mismatch` DTKillerBubbles.bundle/README.md (not on disk), DTKillerBubbles.bundle/manifest.json size, DTKillerBubbles.bundle/qq9/bubble_other_dark@3x.png (not on disk)
- `zip.coverage` zip entry set != bundle files

## 逐图检查

| 文件 | 尺寸 | bytes | CRC | 尾 y 范围 | 尾尖留白 px | 拉伸带 |
| --- | --- | --- | --- | --- | --- | --- |
| `DTKillerBubbles.bundle/qq9/bubble_other_dark.png` | 80x56 | 574 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_dark@2x.png` | 160x112 | 1519 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_highlight.png` | 80x56 | 636 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_highlight@2x.png` | 160x112 | 1610 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_highlight@3x.png` | 240x168 | 2567 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_highlight_dark.png` | 80x56 | 569 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_highlight_dark@2x.png` | 160x112 | 1492 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_highlight_dark@3x.png` | 240x168 | 2300 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_light.png` | 80x56 | 639 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_light@2x.png` | 160x112 | 1573 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_other_light@3x.png` | 240x168 | 2523 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_dark.png` | 80x56 | 828 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_dark@2x.png` | 160x112 | 1873 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_dark@3x.png` | 240x168 | 2935 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_highlight.png` | 80x56 | 829 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_highlight@2x.png` | 160x112 | 1923 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_highlight@3x.png` | 240x168 | 3015 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_highlight_dark.png` | 80x56 | 807 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_highlight_dark@2x.png` | 160x112 | 1819 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_highlight_dark@3x.png` | 240x168 | 2815 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_light.png` | 80x56 | 825 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_light@2x.png` | 160x112 | 1914 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/qq9/bubble_self_light@3x.png` | 240x168 | 2981 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_dark.png` | 80x56 | 525 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_dark@2x.png` | 160x112 | 1419 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_dark@3x.png` | 240x168 | 2160 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_highlight.png` | 80x56 | 540 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_highlight@2x.png` | 160x112 | 1491 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_highlight@3x.png` | 240x168 | 2365 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_highlight_dark.png` | 80x56 | 521 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_highlight_dark@2x.png` | 160x112 | 1388 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_highlight_dark@3x.png` | 240x168 | 2146 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_light.png` | 80x56 | 555 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_light@2x.png` | 160x112 | 1465 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_other_light@3x.png` | 240x168 | 2342 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_dark.png` | 80x56 | 553 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_dark@2x.png` | 160x112 | 1506 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_dark@3x.png` | 240x168 | 2401 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_highlight.png` | 80x56 | 569 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_highlight@2x.png` | 160x112 | 1529 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_highlight@3x.png` | 240x168 | 2419 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_highlight_dark.png` | 80x56 | 566 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_highlight_dark@2x.png` | 160x112 | 1500 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_highlight_dark@3x.png` | 240x168 | 2414 | ok | 108..159 | 4 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_light.png` | 80x56 | 578 | ok | 36..53 | 1 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_light@2x.png` | 160x112 | 1529 | ok | 72..106 | 2 | ok |
| `DTKillerBubbles.bundle/wx8/bubble_self_light@3x.png` | 240x168 | 2411 | ok | 108..159 | 4 | ok |

## textColor 契约

| skin | side | appearance | color | 实测 | 声明 |
| --- | --- | --- | --- | --- | --- |
| wx8 | self | light | `#191919` | 12.03 | 12.03 |
| wx8 | self | dark | `#F2F2F7` | 6.79 | 6.79 |
| wx8 | self | highlight | `#191919` | 10.22 | 10.22 |
| wx8 | self | highlight_dark | `#F2F2F7` | 8.28 | 8.28 |
| wx8 | other | light | `#191919` | 17.43 | 17.43 |
| wx8 | other | dark | `#F2F2F7` | 12.49 | 12.49 |
| wx8 | other | highlight | `#191919` | 15.57 | 15.57 |
| wx8 | other | highlight_dark | `#F2F2F7` | 13.71 | 13.71 |
| qq9 | self | light | `#191919` | 12.84 | 12.84 |
| qq9 | self | dark | `#F2F2F7` | 10.82 | 10.82 |
| qq9 | self | highlight | `#191919` | 11.41 | 11.41 |
| qq9 | self | highlight_dark | `#F2F2F7` | 12.09 | 12.09 |
| qq9 | other | light | `#191919` | 17.43 | 17.43 |
| qq9 | other | dark | `#F2F2F7` | 12.49 | 12.49 |
| qq9 | other | highlight | `#191919` | 15.57 | 15.57 |
| qq9 | other | highlight_dark | `#F2F2F7` | 13.71 | 13.71 |
