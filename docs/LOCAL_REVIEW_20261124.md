# MoonDLT 本地检查与修复记录

检查日期：2026-11-24。本记录描述发布前的本地检查阶段；当前公开状态见 `SUBMISSION_STATUS.md`。项目位于 `D:\CodexProjects\MoonDLT`，检查基线为本地提交 `62a43f9`。此次仅修改、测试和保存本地工程，未创建远程仓库、推送、报名或发布。

## 总体判断

发现并修复了协议参数、可选字段状态、资源边界和跨目标文本处理中的实际问题。新增 12 项回归测试；现有及新增共 56 项测试在 Wasm、Wasm-GC、JavaScript 上通过，Wasm 和 JS 的 Release 测试也通过。全目标严格静态检查、格式检查、生成接口检查、示例与实际文件提取均通过。

核心仍以 MoonBit 实现，严格有效源码为 4,315 行；不计测试、示例、生成文件、脚本、依赖或注释。项目不是模板工程，但本地验证结果不等同于主办方审核结论或 AUTOSAR 全协议认证。

## 已修复的问题

| 问题与触发条件 | 修改后的行为 | 回归证据 |
| --- | --- | --- |
| `SetDefaultLogLevel`、`SetDefaultTraceStatus` 接受 `-1/0xff`，使“默认值”继续引用默认值 | 这两项仅接受具体等级/状态；按上下文设置仍可使用默认值标记 | `utilities_regression_wbtest.mbt` |
| 记录省略 WSID、WTMS 或接收时间时，连续性状态丢失已有基线，误报会话切换或漏报时间回绕 | 保存最后已知值；只有两个已知会话 ID 不同时才确认切换 | `utilities_regression_wbtest.mbt` |
| JSON 参数能绕过自定义 `message_bytes`，或整数文本在解析前没有长度约束 | 按实际编码长度执行预算，过长整数表示提前拒绝 | `payload_regression_wbtest.mbt`、既有 JSON 测试 |
| verbose 构造器只检查载荷，可能返回带非法头字段或总长度超限的消息 | 返回前核对完整头加载荷预算和 Storage 元数据 | `payload_regression_wbtest.mbt` |
| `logical_values()` 接受非法位宽、越界整数、错误数组形状或不允许的固定点组合；f32 值未按实际存储精度归一 | 数值分析前统一校验类型和形状，f32 按 binary32 转换 | `payload_regression_wbtest.mbt` |
| 不完整 UTF-16 代理项在 Wasm 上可触发 panic，在 JS 上被替换，结果不一致 | UTF-8 编码前检查代理项及字节预算，统一返回 `DltError`，覆盖参数、标识符、表达式、字典和软件版本文本 | `payload_regression_wbtest.mbt`、`unicode_regression_wbtest.mbt` |
| `copy_selected` 在筛选和读取之间遇到源变化，可能导出另一组头字段的记录 | 输出前重新核对头与 Storage 信息，不匹配即报错 | `transport_regression_wbtest.mbt` |
| 空查询、空区间绕过资源配置校验 | 即使没有结果，也先验证配置 | `transport_regression_wbtest.mbt` |
| 文件 CLI 在区分大小写的平台上，也把仅大小写不同的路径判成同一文件 | 只在 Windows 上按忽略大小写方式比较；既有输出继续由独占创建保护 | `scripts/test_file_cli.py` |

还补充了提取中途遇到截断时清理本次新输出的测试。文件适配器只负责 I/O，筛选与协议校验仍由 MoonBit 完成；没有改为在 JavaScript 中实现协议。

控制服务边界对照 [COVESA dlt-daemon v2.18.10 的控制请求处理](https://github.com/COVESA/dlt-daemon/blob/v2.18.10/src/daemon/dlt_daemon_client.c)；文本问题同时核对本机工具链的 `encoding/utf8/encode_nonjs.mbt` 与 `encode_js.mbt`，通过不同目标的运行测试确认，而非仅依据示例结果推断。

## 独立互操作补强

原有 54 个固定黄金向量继续逐字节通过。新增固定随机种子 `20261124` 的 192 条独立记录：由 `pydlt==0.3.5` 编码，MoonBit 解码并用类型值重新构造，再与原报文比较完整字节，并交回 pydlt 检查语义。

新增覆盖包括空 verbose 参数、随机可选头、两种载荷字节序、三种封装、有限 IEEE 正常/次正规浮点、整型、ASCII 控制字符、Unicode/BOM 和 raw。没有自行编写第二套协议编码器作为参考。脚本同时修正了 Python 将大数 JSON 字面量读成精确整数而导致的浮点比较误报；只归一带 `kind=float` 的数值，64 位整数仍以字符串比较，报文字节仍严格比较。

复现：`python scripts/test_interop_random.py`。该验证仍只覆盖双方支持的常用标量子集，不能用于证明高级 VARI/FIXP/数组与外部工具互通。

## 仍需保留的边界

- Windows 缺少 MSVC C++ 编译器与 SDK，原生运行测试未完成；没有把静态检查当作原生运行通过。
- 高级参数有标准字段和单元测试，尚无独立外部库互操作证明；f32 signaling NaN 载荷位的限制继续保留。
- 未采用真实车辆或量产日志语料，未运行云端 CI，未完成比赛正式提交。
- 源回调仍须对应稳定输入。重读头校验不能认证载荷，目录采样散列也不是密码学完整性校验。
- 不支持项继续包括 DLT v2、完整 FIBEX XML、结构体/trace-info/128 位参数和车辆通信管理；不通过描述扩大功能承诺。

## 申报材料与生态差异

根目录许可证为 Apache-2.0，来源与 AI 辅助范围在 `THIRD_PARTY.md` 列明，申报书、技术设计和兼容性边界均已提供。本地已有可追踪的实质开发提交，构建、缓存和开发依赖均在忽略目录中。

2026-11-24 再次执行 `moon search dlt --limit 8` 和 `moon search automotive --limit 8`，仍未看到直接的 DLT 协议库匹配；CAN/DBC 相邻项目与本项目的格式、协议层及输出已经在 `DIFFERENTIATION.md` 区分。这不是对全部公开或未公开申报项目的穷尽证明。

`local/moondlt`、公开仓库链接和 Mooncakes 发布目前按用户要求留待正式公开时处理；它们属于提交准备事项，不是本次要求本地开发时的错误。不沿用旧八月章程推断当前十一月赛期或截止时刻。

## 已检查的证据

统一执行：`python scripts/validate.py --release-tests`。逐项退出码、测试数量、工具链版本和源码规模记录在 `LOCAL_VALIDATION.json`；完整命令输出在 `work/validation/`。当前编译器为 MoonBit 0.10.17，无需为本次修复升级。

本机未安装 `moonbitlang/skills`；可作为后续开发辅助选项，不影响当前测试结果，也没有因此停止项目工作或修改全局环境。
