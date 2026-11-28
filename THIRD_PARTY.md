# 来源、授权与 AI 辅助说明

MoonDLT 的 MoonBit 核心代码为此工程新写，采用 Apache-2.0。协议知识、测试工具和参考项目关系如下。

| 来源 | 授权/性质 | 使用方式 |
| --- | --- | --- |
| [AUTOSAR Log and Trace Protocol R19-11](https://www.autosar.org/fileadmin/standards/R19-11/FO/AUTOSAR_PRS_LogAndTraceProtocol.pdf) | AUTOSAR 标准文档，保留原权利 | 阅读与链接引用，不随工程分发标准 PDF，不复制大段文档。 |
| [COVESA dlt-daemon](https://github.com/COVESA/dlt-daemon) | 上游主要采用 MPL-2.0；各文件以实际声明为准 | 查看协议结构与 v1/v2 差别；未复制实现源码、测试库或 daemon。 |
| [esrlabs/dlt-core](https://github.com/esrlabs/dlt-core) | Apache-2.0 | 设计与成熟能力范围对照，未全量移植或复制源码。 |
| [JulianSchmid/dlt-parse-rs](https://github.com/JulianSchmid/dlt-parse-rs) | MIT/Apache-2.0 | 用于了解可嵌入 DLT 库的职责与部署限制，未复制源码。 |
| [pydlt 0.3.5](https://github.com/mikiepure/pydlt) | MIT，Copyright (c) 2018 Miki, Hiromitsu | 独立开发验证依赖，安装于忽略的 `work/pydeps`；通过公共 API 生成测试向量，不复制其编解码器到 MoonBit。 |
| [dlt_parse 0.10.1](https://github.com/JulianSchmid/dlt-parse-rs/tree/v0.10.1) | MIT OR Apache-2.0 | Rust 独立开发对照依赖，使用公开读写 API 核验小端共同用例。Rust 工具依赖 [arrayvec 0.7.6](https://github.com/bluss/arrayvec)（MIT OR Apache-2.0），核心 MoonBit 无此运行依赖。 |
| MoonBit 标准库 | Apache-2.0 | 核心依赖工具链随附的 buffer、debug、UTF-8 等包，以 `moon.pkg` 实际导入为准。 |

`fixtures/` 内的记录均为合成输入。`pydlt-0.3.5-*` 由 pydlt 0.3.5 的公开 API 生成，可通过 `scripts/interop.py --generate-fixtures` 复现，SHA-256 位于黄金 JSON。`fixtures/review/` 是本项目按 R19-11 构造的 Storage 记录和 Classic ARXML 描述，用于复审场景。样例中使用的是合成设备、参数及源码位置。项目自有的向量定义、预期描述及脚本采用 Apache-2.0。

AI 协助了选题检索、接口设计、代码生成、测试与文档。AI 输出不是协议权威来源；可核验事实来自标准、公开实现与本地命令。当前实现应由维护者逐项理解、审核和测试。未声明为成熟库的逐行移植，不把工具自动生成接口、测试数据或文档计入手写核心有效行。

如果后续引入上游源码、FIBEX 文件、真实日志或第三方测试语料，必须在这里补充具体文件、版本、许可证、版权和移植修改范围，然后再分发。当前没有将这些潜在来源默认为已授权。
