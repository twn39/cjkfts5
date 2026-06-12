# CJKTokenizer Complete Performance Benchmark Report

- **Corpus Details**: Mixed Chinese/English text, 5000 documents.
- **Corpus Size**: 3.24 MB (3393890 bytes).
- **Platform**: 版本26.3（版号25D125） (10 Cores).

---

## 维度 A：直接分词吞吐率 (Raw Tokenizer Throughput)
> 测量直接调用分词器进行分词的纯粹 CPU 吞吐性能（不含 SQLite 数据库写入开销）。

| 分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| CJK (Default) | 135.11 | 23.96 |
| CJK (No Unigrams) | 126.61 | 25.56 |
| CJK (With Stopwords) | 826.26 | 3.92 |
| CJK (No Folding) | 122.70 | 26.38 |

## 维度 B：FTS5 数据库表写入与索引吞吐率 (FTS5 Indexing Throughput)
> 测量在真实 SQLite 事务中，批量插入并建立 FTS5 索引的端到端吞吐性能（含数据库 I/O 与 FTS5 树更新）。

| 虚拟表分词器配置 | 耗时 (ms) | 吞吐率 (MB/s) |
| :--- | :---: | :---: |
| CJK (Default) | 295.73 | 10.94 |
| CJK (No Unigrams) | 244.32 | 13.25 |
| CJK (With Stopwords) | 997.23 | 3.25 |
| SQLite unicode61 | 180.00 | 17.98 |
| SQLite trigram | 183.09 | 17.68 |

*(测试结果在运行时自动计算生成)*
