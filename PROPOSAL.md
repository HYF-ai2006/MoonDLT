# MoonDLT 项目申报书 · 十一月黑客松复审

- **维护者** [HYF-ai2006](https://github.com/HYF-ai2006)

**1、项目名称**　MoonDLT · 面向 Wasm 与原生工具的 AUTOSAR R19-11 DLT v1 日志交换库

**2、项目简介**　车辆与嵌入式设备采集的 DLT 日志常包含嵌套状态、跟踪文本和宽计数器。MoonDLT 的纯 MoonBit 核心能读写 Storage、Network、Serial 三种封装，按记录边界处理分片，并提供筛选与无损导出。最终目标是完整实现 AUTOSAR FO R19-11 所规定的 DLT v1 报文、标准载荷和适用的协议行为。 [AUTOSAR 规范](https://www.autosar.org/fileadmin/standards/R19-11/FO/AUTOSAR_PRS_LogAndTraceProtocol.pdf)

**3、项目方向与通用性**　可嵌入的二进制协议库。文件读取和时钟由宿主提供，调用者可配置 ECU、应用、上下文及外部日志描述。同一核心可用于 Wasm、JS 和原生工具。与 CAN/DBC 的总线信号、日志框架的事件产生和 MCAP 的通用容器相比，MoonDLT 负责解释 DLT 记录头、参数类型与控制服务。 [生态差异说明](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/DIFFERENTIATION.md)

**4、三个预期使用场景**

- **故障日志交接。** 诊断工程师输入 Storage 采集文件，按 ECU、应用和等级定位故障窗口，用 `inspect` 查看记录、用 `extract` 导出片段交给同事。验收以筛选结果正确、导出记录与源文件对应区间逐字节一致为准。
- **离线工具分析分片。** Wasm 工具从宿主接收分块日志，逐帧解析后输出保留结构层次、宽整数和浮点位型的类型化 JSON，供界面或脚本读取。验收比较一次读取与逐字节送入的结果，要求记录顺序和字段值一致，截断输入返回可定位的错误。
- **按模板还原台架日志。** 测试工程师输入 Classic ARXML 描述和无扩展头的 non-verbose DLT 记录，按 Message ID 恢复应用上下文、源码位置、静态文本和定宽动态值。验收要求大小端输入还原出相同字段，缺失或歧义匹配报错，修改动态值后可按原描述重新编码。

**5、核心功能与阶段验收**

- **阶段一 · 标准载荷，已实现。** 支持嵌套结构体 STRU、ASCII/UTF-8 trace-info（TRAI）、有符号与无符号 128 位整数，并覆盖 binary16/binary128、宽定点和数组。大小端 Storage 样例均实测将结构体成员 `boot` 改为 `ready`，载荷从 37 增至 38 字节，整数 `2⁹⁶＋1` 保持精确。`python scripts/test_review_record.py --rust` 可复现该流程、220 个规范用例及与 Rust `dlt_parse 0.10.1` 共有小端高级类型的双向核对。
- **阶段二 · 描述还原与控制行为，已验证基础能力。** Classic ARXML 路径支持字节对齐的定宽字段及可精确表示的单段线性定点。以字节向量核验控制请求字段和 GetLogInfo 列表响应。离线宿主用事件重放验证配置变更、应用通知、过滤、计数回绕、时间同步、溢出节流和有限重试。
- **阶段三 · 最终验收。** 继续补齐复杂 ARXML 布局、验证 GetLogInfo 状态 7 的外部互操作，并在具体部署条件下核对端点行为。按 R19-11 第 5 章的适用条款逐项归档输入、预期字节或行为及复现结果。 [复现手册](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/ACCEPTANCE.md) · [R19-11 条款矩阵](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/R19_11_REQUIREMENTS.md)

**6、项目性质**　依据公开协议标准独立实现的原创 MoonBit 项目，以 Apache-2.0 发布。AI 辅助范围和测试数据来源已公开。 [许可证](https://github.com/HYF-ai2006/MoonDLT/blob/main/LICENSE) · [来源说明](https://github.com/HYF-ai2006/MoonDLT/blob/main/THIRD_PARTY.md)

**7、参考项目与许可证**　[COVESA dlt-daemon](https://github.com/COVESA/dlt-daemon)（主要为 MPL-2.0，按文件声明）与 [esrlabs/dlt-core](https://github.com/esrlabs/dlt-core)（Apache-2.0）用于协议和能力对照。[pydlt 0.3.5](https://github.com/mikiepure/pydlt)（MIT）和 [dlt_parse 0.10.1](https://github.com/JulianSchmid/dlt-parse-rs/tree/v0.10.1)（MIT OR Apache-2.0）通过各自公开 API 提供独立互操作验证。

**8、仓库与提交证据**　公开默认分支为 `main`，已有 10 次实质提交逐条列证。核心有效 MoonBit 代码为 6,437 行，Wasm、Wasm-GC、JS、Linux Native 各通过 76 项测试。0.2.0 为复审基线，Mooncakes 已发布 0.2.1 维护版，并通过 Wasm 和 JS 独立安装测试。 [GitHub 仓库](https://github.com/HYF-ai2006/MoonDLT) · [有效提交](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/SUBMISSION_REQUIREMENTS_CHECK.md) · [验证记录](https://github.com/HYF-ai2006/MoonDLT/actions/runs/46138504062) · [Mooncakes](https://mooncakes.io/docs/HYF-ai2006/moondlt)
