# 负向自测：证明 audit_bubbles_1_0_1.py 的检查不是空转

`neg_cand_broken/` 是 `assets/review-1.0.1/` 的**故意损坏副本**（不含 preview/REVIEW），
只用于自测，切勿当作候选包。审计脚本通过 `DT_AUDIT_CAND` 指向副本，默认行为不变。

## A. 把 wx8/self 的 capInsets bottom 从 24 改成 12
`DT_AUDIT_CAND=neg_cand_broken python assets/review-1.0.1/tools/audit_bubbles_1_0_1.py`
→ FAIL failures=15，其中：
```
manifest.stretchArea wx8/self [18, 18, 34, 14] != caps-derived [18, 18, 34, 26]
tail.inStretchBandY .../bubble_self_light.png tail ymin=36, bottom cap starts 44
tail.inStretchBandY .../bubble_self_light@2x.png tail ymin=72, bottom cap starts 88
tail.inStretchBandY .../bubble_self_light@3x.png tail ymin=108, bottom cap starts 132
（dark/highlight/highlight_dark 同）
```
即 P0-2（尾巴进拉伸带）一旦回归，会被逐倍率点名。

## B. 删掉 qq9/bubble_other_dark@3x.png（capInsets 复位）
→ FAIL failures=5：
```
bundle.count disk has 47 PNG, expect 48
bundle.missing qq9/bubble_other_dark@3x.png
png.missing .../qq9/bubble_other_dark@3x.png
zip.mismatch ...（副本里 *.md 被忽略，故额外报 README/manifest）
zip.coverage zip entry set != bundle files
```

结论：真候选包（默认路径）为 PASS failures=0；同一脚本对人为破坏能立刻失败。
