# MoonDLT 项目申报书 · 十一月黑客松复审

- **维护者** [HYF-ai2006](https://github.com/HYF-ai2006)

**1、项目名称**　MoonDLT · 面向 Wasm 与原生工具的 AUTOSAR R19-11 DLT v1 日志交换库

**2、项目简介**　以纯 MoonBit 实现车辆与嵌入式 DLT 日志交换。最终交付目标是完整实现 AUTOSAR FO R19-11 定义的 DLT v1 报文、标准载荷语义和适用的可观察协议行为。库为 Wasm、JS 和原生工具提供统一编解码、分片处理及原始记录导出接口。 [规范基准](https://www.autosar.org/fileadmin/standards/R19-11/FO/AUTOSAR_PRS_LogAndTraceProtocol.pdf)

**3、方向与通用性**　可嵌入二进制协议库。调用方配置 ECU/APID/CTID、筛选和 non-verbose 外部描述，宿主提供读取、时钟和配置。CAN/DBC 处理总线信号，日志框架产生事件，MCAP 提供通用容器。MoonDLT 实现 DLT 自身的头部、类型词、有序参数及控制语义，并适用于离线诊断、测试交换与嵌入分析。 [生态差异说明](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/DIFFERENTIATION.md)

**4、三个完整使用场景**
- **故障诊断与交接。** 工程师输入 Storage 日志，用 ECU、应用和等级筛选并原样导出故障记录。解码快照结构中的 trace-info 和 128 位计数，修改一个成员后重新编码成可交接的 DLT 文件。验收比较筛选片段、修改字段和完整记录字节。
- **Wasm 工具逐块分析。** 工具接收宿主分片送入的 DLT 字节，按记录边界取出嵌套参数，输出 JSON 给分析界面。验收逐字节输入与一次读取结果一致，保留宽整数及 IEEE 浮点位型，截断位置可定位。
- **非 verbose 日志还原与联测。** 测试工程师提供 Classic ARXML 描述和无扩展头的 DLT 文件，从 Message ID 恢复应用上下文、源码位置、静态文字及动态测量值。验收大小端还原一致，缺少描述或匹配歧义明确报错，并用合成报文验证控制通知的解析结果。

**5、核心功能与阶段验收**
- **第一阶段已实现。** 在已发布 0.1.0 的三种封装、分片与筛选能力上，增加嵌套 STRU、ASCII/UTF-8 TRAI、有符号及无符号 128 位、binary16/binary128、宽 FIXP、标准数值数组与可编辑 JSON。核心有效 MoonBit 代码为 6,437 行。大小端 Storage 样例解码出 `boot` 与精确的 `2⁹⁶＋1`，将文本改为 `ready` 后，载荷由 37 变 38 字节，计数原值保留。220 例按规范独立构造的组合覆盖双端序，`dlt_parse 0.10.1` 双向核对双方支持的小端高级类型。
- **第二阶段已有实现与用例。** Classic ARXML 可从无扩展头记录恢复定宽字段、静态文本和可精确表示的线性定点，并按描述重新编码。标准控制入口覆盖保留位、NOAR、GetLogInfo 条件列表、通道状态、同步时间和溢出通知，已用字节向量核验。离线宿主已验证配置、应用通知、通道过滤、计数回绕、定时同步、溢出节流以及有限重试。
- **最终验收。** 按 R19-11 第 5 章 161 个条款编号记录适用条件和证据。用现有跨目标 CI、离线宿主事件重放与独立包消费验证可复现性。复杂 ARXML 布局、GetLogInfo 状态 7 的额外外部对照与部署相关应用行为继续逐条验收。 [条款与验收矩阵](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/R19_11_REQUIREMENTS.md)

**6、项目性质**　参考协议标准与现有开源实现的原创项目。MoonBit 核心自行编写，AI 辅助及数据来源已披露。项目采用 Apache-2.0。 [来源说明](https://github.com/HYF-ai2006/MoonDLT/blob/main/THIRD_PARTY.md)

**7、参考项目与许可证**　协议和能力对照采用 COVESA dlt-daemon（MPL-2.0，按文件声明）、esrlabs/dlt-core（Apache-2.0）。验证依赖为 pydlt 0.3.5（MIT）和 dlt_parse 0.10.1（MIT OR Apache-2.0）。没有移植上游源码。 [来源、链接与使用范围](https://github.com/HYF-ai2006/MoonDLT/blob/main/THIRD_PARTY.md)

**8、仓库与提交**　公开仓库默认分支为 `main`。已有 10 次实质提交逐条列证，复审新增实现与回归测试可从后续提交和 CI 核查。 [GitHub 仓库](https://github.com/HYF-ai2006/MoonDLT) · [有效提交](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/SUBMISSION_REQUIREMENTS_CHECK.md) · [验收复现](https://github.com/HYF-ai2006/MoonDLT/blob/main/docs/ACCEPTANCE.md) · [GitHub CI](https://github.com/HYF-ai2006/MoonDLT/actions/workflows/check.yml) · [Mooncakes 0.2.0](https://mooncakes.io/docs/HYF-ai2006/moondlt)
