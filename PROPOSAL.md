# MoonDLT 项目申报书

- **维护者：** [HYF-ai2006](https://github.com/HYF-ai2006)

**1、项目名称：** MoonDLT：面向 Wasm 与原生工具的 DLT v1 日志交换库。

**2、项目简介：** 面向车辆和嵌入式系统已产生的 DLT 二进制日志，以纯 MoonBit 提供受检编解码、有界分片读取、筛选及原始记录导出。项目补充 MoonBit/Wasm 无需 libdlt 或 C/C++ FFI 的集成路径，输出的标准记录可继续交给现有 DLT 工具，核心仅依赖 MoonBit 标准库。

**3、项目方向、通用性说明：** 方向为可嵌入协议库与二进制日志处理工具。API 面向标准记录及字节流，由宿主提供文件或传输 I/O；ECU/APID/CTID、筛选条件及 nonverbose 固定布局字典均由调用方配置，不绑定特定车型、业务表结构或定时任务。同一核心已在 Wasm、Wasm-GC、JS、Linux Native 验证。相邻 CAN/DBC 库解释总线帧和信号，日志框架产生事件，MCAP 管理另一种消息容器；本项目独立实现 DLT 头部、类型词、载荷边界与互操作输出，差异见[生态对照](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/DIFFERENTIATION.md)。

**4、至少 3 个完整的预期使用场景**

- **场景一：故障日志筛选与原样交接。** 嵌入式工程师取得采集端导出的 Storage `.dlt` 文件，通过已交付的 `inspect/extract` 工具扫描头字段，按 ECU、应用、上下文、等级或存储时间选取记录，输出摘要和选中记录组成的 `.dlt` 文件，供后续分析或问题复现；验收检查筛选结果正确，导出记录与输入的对应字节完全一致。
- **场景二：Wasm/JS 工具分片分析离线日志。** 工具开发者由宿主文件 API 分片读取 `.dlt`，将片段送入有缓存预算的读取器，逐条取得完整记录、头字段和类型化参数，并以 JSON 输出给宿主界面或分析模块。结果无需整份文件驻留内存，64 位整数通过十进制字符串交换；验收比较不同分片方式的记录与参数，截断尾部必须报错。此处交付协议库及示例，界面由集成方实现。
- **场景三：仿真测试数据与现有 DLT 工具交换。** 测试平台开发者输入合成 ECU/APID/CTID、时间戳和类型化参数，通过编码 API 构造 Storage 文件或 Network/Serial 报文，交给已有 DLT 消费流程。输出保留类型与字节序，便于同一测试数据跨工具使用；验收由独立工具解析输出并核对字段与参数，目前独立互操作证据覆盖常用标量子集，不代替实车验证。

**5、拟实现的核心功能：** 已完成并发布 0.1.0：Storage/Network/Serial 三种封装、全部可选头组合、双字节序载荷；verbose 标量、文本、raw、数值数组、变量信息与固定点参数；应用显式注册的 nonverbose 固定布局字典；常用控制载荷的被动编解码；有界分片、截断检查与限额恢复；头字段查询、UInt64 偏移按需读取、默认 `open()` 逐头核验的持久化目录及原字节提取工具。

技术路线与验收：区分标准头网络字节序、Storage 时间小端序与 MSBF 载荷字节序，先校验长度与边界，再解释参数；对消息、缓存、参数和恢复扫描设置上限，仅在有魔数的封装中恢复。核心严格有效 MoonBit 代码为 4,315 行，四目标各 56 项测试、Wasm/JS Release、54 个固定向量与 192 条固定种子记录通过。后续补充授权清楚的真实日志、高级参数外部互操作和 Windows 原生验证。范围限定 DLT v1 常用子集，不含 DLT v2、完整 FIBEX XML、结构体/trace-info/128 位参数或设备连接管理；高级参数目前只有标准字段与单元测试证据，不声明 AUTOSAR 一致性认证。

**6、项目性质与原创性：** 原创项目，参考协议标准与已有开源实现。本工程的 MoonBit 核心为新写代码，未复制参考库源码；独立贡献为协议模型、受检编解码、流状态机及可复用查询/提取 API。AI 辅助了设计、编码、测试与文档，来源与使用范围已在 [THIRD_PARTY.md](https://github.com/HYF-ai2006/MoonDLT/blob/main/THIRD_PARTY.md) 披露。项目采用 Apache-2.0。

**7、移植/参考项目及许可证：** 本项目不是上游源码移植。协议依据 AUTOSAR R19-11；能力与设计对照来源为 [COVESA dlt-daemon](https://github.com/COVESA/dlt-daemon)（主要为 MPL-2.0，各文件声明为准）、[esrlabs/dlt-core](https://github.com/esrlabs/dlt-core)（Apache-2.0）、[JulianSchmid/dlt-parse-rs](https://github.com/JulianSchmid/dlt-parse-rs)（MIT OR Apache-2.0）；独立开发验证使用 [pydlt 0.3.5](https://github.com/mikiepure/pydlt)（MIT），仅作开发依赖，不将其编解码器复制到 MoonBit。具体参考范围及合成测试数据来源见上述来源说明。

**8、GitHub 仓库及有效 commits：** [HYF-ai2006/MoonDLT](https://github.com/HYF-ai2006/MoonDLT)，公开默认分支为 `main`；[有效提交核验](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/SUBMISSION_REQUIREMENTS_CHECK.md)逐项列出 10 次既有功能、测试或 CI 修复提交及实际改动，未以空提交、重复补丁或仅发布状态记录满足次数下限。运行证据见 [GitHub CI](https://github.com/HYF-ai2006/MoonDLT/actions/workflows/check.yml)，已发布模块为 [HYF-ai2006/moondlt@0.1.0](https://mooncakes.io/docs/HYF-ai2006/moondlt)。
