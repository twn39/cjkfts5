// cjkfts5.swift
// cjkfts5
//
// 模块入口 — 通用 CJK FTS5 分词库
//
// 核心类型：
//   - CJKTokenizer / CJKTokenizerOptions / StopwordPresets / StopwordSet
//   - TokenNormalizer（内部：发射与停用词共用规范化）
//   - CJKUnicode / CJKIntegration（.cjk(options:) / addCJKTokenizer()）
//
// 快速开始：
//   import cjkfts5
//   config.addCJKTokenizer()
//   t.tokenizer = .cjk(options: .recommended)  // 折叠 + 中英文停用词
//   // 或 .cjk()  — 仅折叠，默认无停用词

// 公共 API 已在各子文件中用 `public` 修饰符声明。
