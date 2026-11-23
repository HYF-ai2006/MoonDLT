# 验证方式与已取得的证据

## 本地命令

完整记录入口：`python scripts/validate.py`，生成 `docs/LOCAL_VALIDATION.json`，每项命令的完整日志保存在忽略的 `work/validation/`。记录会区分实际通过、失败和环境缺失导致的未运行。

```sh
moon check --target all --deny-warn
moon test --target wasm --deny-warn
moon test --target wasm-gc --deny-warn
moon test --target js --deny-warn
moon fmt --check
moon info
moon run cmd/demo --target js
python scripts/count_loc.py
python scripts/interop.py
python scripts/test_file_cli.py
```

这些命令是复现入口。测试总数、核心有效代码行数和各目标最终通过状态应以实际运行记录为准，不从计划功能推导通过结论。最终本地汇总记录位于 `docs/LOCAL_VALIDATION.json`（由最后一轮验证生成）。

2026-11-23 的全目标静态检查已通过，Wasm、Wasm-GC、JavaScript 测试已有通过记录；测试数仍会随最后的边界用例增加。Windows 原生测试已经尝试，但本机缺少 MSVC 原生构建工具，因而未完成原生链接与运行验证。具备原生 C 工具链后可执行 `moon test --target native --deny-warn`。CI 的 Ubuntu `--target all` 仍保留原生构建和运行要求；其云端结果尚未执行。

## 已运行的独立互操作

2026-11-23 在本地使用 `pydlt==0.3.5` 和 MoonBit JS 执行 `python scripts/interop.py`，54 个向量的两个方向均通过，完整字节一致。机器可读记录写入忽略目录 `work/validation/interop.json`。

1. Python 使用独立 pydlt API 编码公开值，得到二进制记录。
2. MoonBit CLI 解码这些字节，输出规范化头、位宽、整数十进制字符串、浮点、文本和 raw 参数。
3. MoonBit 使用自己的 API 对同组值编码；脚本逐字节与 pydlt 输出对比。
4. pydlt 再解析 MoonBit 输出，比较字段与类型值。

整数在 JSON 桥接中表示为十进制字符串，避免 JavaScript JSON 数字丢失 `uint64` 精度。浮点向量选用可精确表示的有限值，非有限数值及各类 NaN 位型不属于此脚本证明范围。

覆盖项目：小端/大端、三种封装、16 种可选头字段组合、全部常用标量参数、signed64 最小值、unsigned64 最大值、计数器 255、中文与补充平面字符、空字符串、空 raw、raw 中包含魔数字节。

## 黄金文件与复现

- `fixtures/pydlt-0.3.5-golden.json`：54 个独立向量、预期值、SHA-256。
- `fixtures/pydlt-0.3.5-storage.dlt`：18 个 Storage 记录拼接，可交给独立 DLT 工具读取。
- `python scripts/interop.py --check-fixtures`：只检查固定版本重新产生的黄金文件。
- `python scripts/interop.py --generate-fixtures`：显式更新黄金文件。修改后必须审查差异，不能用更新预期结果掩盖回归。

黄金样本是公开的合成值，没有车辆、用户或企业日志；独立 serializer 来自 pydlt，不是本工程自写的第二个 codec。pydlt 的实现也可能有错误，故交叉验证只是证据之一，不能替代标准字段审查、畸形输入测试和真实集成。

## 错误与资源验证原则

核心测试应覆盖声明长度小于头长、EOF 截断、非法版本、错误 magic、未知类型词、参数数目不符、字符串长度和编码错误、每个分片边界、完整消息后的截断尾部、恢复魔数跨块、扫描与缓存上限、失败状态复用和索引越界。只比较 encode/decode 自身往返不能证明符合外部协议。

目录测试还需区分“不合法 JSON”“结构合法但篡改了头元数据”“源实际头变化”与“未采样载荷变化”：默认打开逐头比较可拒绝前几类元数据不匹配，但非密码学采样签名不提供载荷完整性证明。表达式测试检查优先级、字段类型、缺失值、超长平面组合与深层括号，避免把只通过小例子当作资源边界已验证。

CI 保存标准检查入口，并执行独立互操作。当前为本地工程，云端 workflow 文件尚未在远程执行，不能把“已配置 CI”写为“云端 CI 已通过”。

## 真实文件入口验证

`scripts/test_file_cli.py` 把提交的独立 `.dlt` 黄金文件交给真实 Node 文件适配器。头扫描应得到 18 条记录，限制返回 2 条摘要时仍统计全部匹配；读取使用文件范围回调，头扫描单次最大请求仅 22 字节。按 APID 选择后，输出逐字节与独立黄金 JSON 指定的原始记录拼接一致。还验证非法表达式、截断输入、无效上限、相同输入输出路径和已有输出文件保护。

本机已尝试运行全目标测试；Windows 原生链接因缺少 MSVC C++ 编译器与 SDK 无法启动，不能作为通过项。全目标静态检查与 Wasm/Wasm-GC/JS 的运行结果分别记录。CI 的 Linux 原生检查尚待未来推送后实际执行。
