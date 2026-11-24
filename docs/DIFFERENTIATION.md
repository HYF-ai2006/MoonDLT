# 生态差异与检索证据

检索日期：2026-11-24；首次选题检索为 2026-11-23。本次复查排除已发布的 MoonDLT 自身，本文不能证明所有报名项目或未公开仓库都不存在类似能力。

## 独立贡献如何界定

MoonDLT 的输入输出是已有的 DLT v1 二进制记录。主要成果是可嵌入的协议模型、受检编解码、流状态管理和有界字节处理。它不从 README、目录或配置推导“工程分数”，不把内部单次日志导出操作包装成通用框架。

可独立验证的交付：同一条 pydlt 产生的记录能在 MoonBit 中恢复头字段与参数；MoonBit 写出的记录能被 pydlt 读取；应用可在分片输入中取得完整记录，并按真实字节区间无损提取。外部标准和独立工具提供判断基准。

## 最接近的 MoonBit 项目

| 现有项目 | 已有职责 | MoonDLT 的必要差别 |
| --- | --- | --- |
| [fuyun-2026/moonbit-canbus](https://mooncakes.io/docs/fuyun-2026/moonbit-canbus) | CAN/CAN-FD 帧、总线建模、信号打包与回放 | DLT 是 ECU 应用日志的独立二进制交换协议。MoonDLT 不重做 CAN 总线模拟或物理帧解码。 |
| [curry3point/dbc-toolkit](https://mooncakes.io/docs/curry3point/dbc-toolkit) | DBC 描述和 CAN 信号编解码 | DLT 的标准头、上下文和 verbose 参数不等同于 DBC 的 CAN 信号位域。 |
| [brickfrog/moontrace](https://mooncakes.io/docs/brickfrog/moontrace) | 结构化跟踪及 console/JSON/logfmt/OTLP 等输出 | MoonDLT 负责已有 DLT 记录的交换语义，可作为日志框架实现 DLT 适配器的底层协议库；当前未声明交付 moontrace 专用适配器。 |
| [moonbitstack/moontel](https://mooncakes.io/docs/moonbitstack/moontel) | OpenTelemetry 追踪、指标、日志和 OTLP | DLT v1 与 OTLP 不是同一格式；MoonDLT 不实现新遥测平台。 |
| [btlqql/moon_tracelens](https://mooncakes.io/docs/btlqql/moon_tracelens) | JSONL/五列 pipe 日志摄取与离线调查 | MoonDLT 的关键工作是 DLT 二进制编解码和有界流处理，过滤是建立在协议语义上的配套能力。 |
| [LilaLola67/moonmcap](https://github.com/LilaLola67/moonmcap) | MCAP 0 通用消息容器及 ROS/Protobuf/XCDR 载荷处理 | DLT 头部、类型词、参数数目、字节序及控制载荷属于另一标准；MCAP 容器不能直接完成这些解释。 |
| [myc1234567/moonbit-canbus](https://github.com/myc1234567/moonbit-canbus) | CAN/CAN-FD、ISO-TP/UDS 等总线和诊断能力 | UDS 诊断与 DLT 日志交换属于不同协议。未见其公开声明支持 DLT 标准头与 verbose 类型词。 |

共同含有“日志”“过滤”“索引”不代表核心相同。判断时应比较输入输出格式、协议语义、可复用 API、部署限制和实现代码；如果发现已有 MoonBit DLT 项目，应重新比较后决定贡献给现有库还是保留当前工程。

## 已进行的检索

本机使用当前 `moon search` 搜索模块和包描述。搜索可能返回模糊匹配，故逐一看了实际职责，而非把“有结果”直接认定为重复。

```sh
moon search dlt --limit 8
moon search automotive --limit 10
moon search diagnostic --limit 10
moon search autosar --limit 10
moon search covesa --limit 5
moon search dltparse --limit 5
moon search "log trace" --limit 10
```

- `dlt` 返回本项目 `HYF-ai2006/moondlt` 与几何中的 Direct Linear Transform；排除自身后未见另一直接匹配。
- `automotive` 返回 CAN/DBC 等项目；已在上表明确区分。
- `diagnostic` 多为编译器诊断、报告和工具库；`covesa` 模糊匹配覆盖率库。
- GitHub 公共仓库 API 查询 `dlt language:MoonBit` 返回 `total_count=1`，结果仅本项目；排除自身后未发现另一直接匹配。这修正了尚未发布时 `total_count=0` 的历史记录。
- 本次逐读 8 个相邻仓库的公开 README，并进行 DLT 关键词代码检索，未发现直接支持 DLT/AUTOSAR Diagnostic Log/FIBEX 的公开声明或命中；索引、名称与公开范围有限，不能据此穷尽全部实现。
- [当前赛事官网](https://moonbitlang.github.io/Hackathon2026/)及其 [App.tsx](https://github.com/moonbitlang/Hackathon2026/blob/main/src/App.tsx)显示十一月赛季和项目公开、实质贡献、可运行与开源合规要求。官网未提供可穷尽的所有报名项目名单，因此没有宣称“已排除全部参赛项目”。

## 主动排除过的重复选题

前期检索排除了 FITS、miniSEED、PCAPNG、VCD、WARC、BSON、Roaring、NetCDF、EDF、NIfTI 和 cpio。特别是 [MoonAstroFITS](https://github.com/cosettese/MoonAstroFITS) 已有 FITS 头、HDU、图像、BINTABLE 及 P/Q 变长列；不能仅凭名称不同再申报相同范围。

## 与成熟其他语言实现的关系

| 参考项目 | 参考价值 | 当前关系 |
| --- | --- | --- |
| [esrlabs/dlt-core](https://github.com/esrlabs/dlt-core) | Rust 解析/写入、nonverbose/FIBEX 处理，Apache-2.0 | 用于确认生态成熟边界；未全量移植，未复制源码。 |
| [JulianSchmid/dlt-parse-rs](https://github.com/JulianSchmid/dlt-parse-rs) | 无分配与 no_std 的数据交换思路，MIT/Apache-2.0 | 用于对照部署约束和 API 职责；MoonDLT 当前拥有自己的分片状态和资源配置。 |
| [COVESA dlt-daemon](https://github.com/COVESA/dlt-daemon) | 实际生产生态和协议结构文档 | 仅阅读公开资料，不复制其源码；不宣称实现 daemon。 |
| [mikiepure/pydlt](https://github.com/mikiepure/pydlt) | 独立纯 Python 编解码，MIT | 固定 0.3.5 生成黄金向量并做双向互操作，不是产品依赖。 |

迁移价值来自部署：MoonBit/Wasm/JS 使用同一纯语言库直接处理 DLT 字节，免除消费者编译和绑定 libdlt 的工作。它不要求已经使用成熟桌面 DLT 工具的用户迁移，也不声称优于那些工具的全部功能或性能。
