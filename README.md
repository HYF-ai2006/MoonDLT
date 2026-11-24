# MoonDLT

MoonDLT 是以 MoonBit 实现的 **DLT v1 二进制日志编解码与流处理库**。它让运行在 Wasm、JavaScript 和原生环境中的工具读取 ECU 应用日志，提取带类型的参数，并将选中的记录按标准格式交给其他 DLT 工具。

核心面向已经产生的 `.dlt` 文件和 DLT 消息字节流，采用明确的长度、参数数目和缓存上限。读取器不依赖 libdlt、C/C++ FFI、车辆硬件或常驻守护进程。

当前工程在本地开发，模块名 `local/moondlt` 是开发用命名空间；尚未推送、报名或发布。完成公开仓库和 Mooncakes 命名空间配置后才能用于正式提交。参赛说明见 [PROPOSAL.md](PROPOSAL.md)，功能差异证据见 [docs/DIFFERENTIATION.md](docs/DIFFERENTIATION.md)。

最近一次本地检查修复记录见 [2026-11-24 自查](docs/LOCAL_REVIEW_20261124.md)，逐项测试与规模数据见 [本地验证记录](docs/LOCAL_VALIDATION.md)。

## 能处理什么

- DLT v1 标准头、ECU/session/timestamp 可选字段、扩展头和小端/大端载荷。
- Storage `.dlt`、Network、Serial 三种显式封装；保留原始载荷，按需解码。
- Verbose 布尔、8/16/32/64 位有符号与无符号整数、32/64 位浮点、ASCII/UTF-8 字符串、原始字节参数。
- 独立的高级参数 API 保留 VARI 名称/单位、FIXP 缩放与同类数值数组；JSON 交换把 64 位整数作为十进制字符串、浮点作为 IEEE 位模式保留。
- 任意分片输入、严格的结束检查、带上限的 Storage/Serial 损坏恢复。
- 应用、上下文、ECU、日志等级和存储时间过滤；有界头字段表达式、字节偏移索引、提取、确定性合并和重新封装。
- 应用显式注册的 nonverbose 固定布局字典；未注册载荷仍可按原样转交。
- 使用 UInt64 偏移和宿主 `read_at` 回调扫描大型记录，只读取头或所选载荷；有界窗口缓存、计数器连续性和时间分桶可按需使用。
- 可保存为 JSON 的 `SourceCatalog` 元数据侧文件；默认 `open` 重新核对全部记录头，再用于查询。
- 常用控制服务的被动编解码；函数不建立连接或向设备发送命令。

详细范围与限制以 [兼容性清单](docs/COMPATIBILITY.md) 和生成接口 `pkg.generated.mbti` 为准。项目定位是 DLT v1 常用互操作子集，不宣称通过 AUTOSAR 全协议认证，也不实现 DLT v2、完整 FIBEX XML 或车载诊断服务栈。

## 本地运行

需要 MoonBit 工具链；文件命令行工具需要 Node.js 22 或更新版本。项目核心只依赖 MoonBit 标准库。

```sh
moon check --target all --deny-warn
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon run cmd/demo --target js
moon fmt --check
```

原生测试还需要可用的 C 编译器。在本次 Windows 环境中，原生构建尝试因缺少 MSVC 工具链而未完成；这不等同于原生运行验证通过。安装相应构建工具后可执行 `moon test --target native --deny-warn`。更详细的 API 用法见 [docs/USAGE.md](docs/USAGE.md)。

示例把真实编码的 Storage 记录按每块 7 字节送入读取器，再解码类型参数并通过索引提取原始记录。

```moonbit
let decoded = @dlt.decode(file_bytes[:])
let original_payload = decoded.message.payload
let parameters = decoded.message.arguments()
let encoded = @dlt.encode(decoded.message)
```

在自己的 `moon.pkg` 中导入本地模块：

```moonbit
import {
  "local/moondlt" @dlt,
}
```

流式使用时，为读取器提供不超过缓存上限的分片，并在输入完成后调用 `finish()`：

```moonbit
let stream = @dlt.StreamDecoder::new()
let first = stream.feed(chunk_a[:])
let second = stream.feed(chunk_b[:])
stream.finish()
```

`feed` 失败会把读取器置于失败状态；再次使用前需要 `reset()`。`recover=true` 只允许 Storage/Serial，跳过字节数显式返回；不能把恢复结果当作“日志完整”。

## 直接处理文件

Node 宿主只提供文件 I/O，协议解析、查询和选取都由 MoonBit 完成。命令自动构建 JS 适配器，使用 UInt64/BigInt 偏移按需读取，不把整份文件装入内存。

```sh
node scripts/moondlt.mjs inspect fixtures/pydlt-0.3.5-storage.dlt --filter 'apid == "APP"' --limit 2
node scripts/moondlt.mjs extract input.dlt selected.dlt --filter 'level <= 3'
python scripts/test_file_cli.py
```

`inspect` 只读取消息头；`extract` 原样复制匹配记录，拒绝覆盖已有输出。文件命令当前限定 Storage 封装和最多一百万条扫描记录，摘要最多一万条；完整的库接口仍支持另外两种封装。输入文件必须在操作期间保持稳定。

一次运行所有本地检查并保存证据：`python scripts/validate.py`。Windows 缺少 MSVC 时原生运行测试会明确记录为未运行；其他目标仍逐一测试。实际结果见 [docs/LOCAL_VALIDATION.json](docs/LOCAL_VALIDATION.json)。

## 独立互操作验证

验证脚本使用独立 Python 包 [pydlt 0.3.5](https://github.com/mikiepure/pydlt)，而不是另写一个相同逻辑的参考解析器。该包仅用于开发验证，不是运行时依赖。

```sh
python -m pip install --target work/pydeps pydlt==0.3.5
python scripts/interop.py
python scripts/test_interop_random.py
```

脚本先检查提交的确定性黄金文件，再构建 MoonBit JS 可执行文件，比较两个方向的类型值和完整字节：pydlt 编码 → MoonDLT 解码；MoonDLT 编码 → pydlt 解码。覆盖 54 个向量，包括三种封装、所有头部可选字段组合、两种字节序、64 位边界、中文与补充平面字符、空字符串和空原始字节。结果与局限见 [docs/VALIDATION.md](docs/VALIDATION.md)。

固定随机种子脚本另检查 192 条独立记录，包含空参数、随机整数、有限正常/次正规浮点及 Unicode/BOM。MoonBit 从解码后的类型值重新构造记录，比较原始字节；这不会扩大高级类型的互操作承诺。

## 代码规模

```sh
python scripts/count_loc.py
python scripts/count_loc.py --json
```

脚本分别报告核心、测试、示例工具，排除构建目录、工作目录和自动生成接口；严格有效行另排除注释、空行及只含结构符号的行。比赛组织方可能采用不同的统计口径。当前数字应以脚本实际运行输出为准。

## 工程结构

| 文件 | 职责 |
| --- | --- |
| `types.mbt`、`bytes.mbt` | 公共类型、资源上限、边界检查与字节基础操作 |
| `codec.mbt`、`stream.mbt` | v1 封装编解码、分片处理、显式恢复、重新封装 |
| `verbose.mbt` | 带类型的常用 verbose 参数 |
| `verbose_parameters.mbt`、`verbose_json.mbt` | 名称/单位、固定点、数值数组和保留整数精度的 JSON 交换 |
| `verbose_selection.mbt` | 数组坐标、区域提取、重塑及受检类型访问 |
| `message_json.mbt` | 保留原始载荷的消息 JSON 信封、严格头字段解析 |
| `dictionary.mbt` | 应用注册的 nonverbose 固定布局 |
| `query.mbt` | 过滤与有界表达式、索引、无损提取和合并 |
| `source.mbt`、`timeline.mbt` | 大偏移随机访问与窗口缓存、连续性事件与时间分桶 |
| `catalog.mbt` | 可持久化源目录、默认逐头核验和按需载荷读取 |
| `control.mbt` | 常用控制请求/响应的被动编解码 |
| `cmd/demo`、`cmd/interop`、`cmd/node` | 使用示例、外部互操作桥接和真实文件消费者 |
| `fixtures`、`scripts` | 独立黄金样本、验证与规模统计 |

## 来源与维护

代码使用公开协议结构独立实现。成熟 DLT 实现用于设计对照与互操作验证；未把 COVESA 或其他库的源码复制进工程。AI 辅助生成和修改已披露，维护者仍需理解协议边界、审核实现并承担发布责任。授权和具体来源见 [THIRD_PARTY.md](THIRD_PARTY.md)。

项目采用 Apache License 2.0，详见 [LICENSE](LICENSE)。
