# MoonDLT 验收复现

验收对象为 HYF-ai2006/MoonDLT 的 0.2.0 源码。标准基准为 AUTOSAR FO R19-11 DLT v1。每项已验收的能力均注明复现方式及证据来源。正式验收资料以组委会的十一月赛通知为准。

| 验收项目 | 如何验证 | 预期观察结果 |
| --- | --- | --- |
| MoonBit 工程与跨目标 CI | 在仓库根目录运行 `moon check --target all --deny-warn` 和 `moon test --target all --deny-warn` | 四个目标编译成功并通过测试。Windows 本地原生测试需要 C 工具链，可核对 Linux CI 的 Native 运行。 |
| 审核指出的三项载荷 | 运行 `python scripts/test_review_record.py --rust` | 大小端均能对 Storage 日志中的 STRU、TRAI 和 U128 做修改后重编码。37 字节载荷变为 38 字节，数值 2⁹⁶＋1 保持精确。220 个规范类型用例与 Rust 小端共同用例分别留下证据。 |
| 非 verbose 文件还原 | 运行 `python scripts/test_arxml.py`，查看 `arxml_wbtest.mbt` | 由 Classic ARXML 恢复无扩展头记录的字段。保留静态文字、定宽动态值、精确定点、源码和上下文。修改一个字段能按原描述重新打包。 |
| 控制服务与宿主行为 | 运行 `moon test --target wasm --filter '*R19 host*'`，查看 `control_details_wbtest.mbt` | 用合成事件复现配置修改、过滤、通道及阈值、应用通知、计数回绕、定时同步、溢出报告及失败重试。用请求和响应字节核验控制字段。 |
| 文件工具与回归 | 运行 `python scripts/test_file_cli.py`、`python scripts/interop.py`、`python scripts/test_interop_random.py` | 真实文件筛选和提取与选中原字节一致，旧的 pydlt 固定样本和随机样本保持互通。 |
| 分发包与独立消费 | 运行 `python scripts/test_public_package.py` | 从 Mooncakes 打包格式的 ZIP 建立独立消费者，校对归档文件及哈希，在 Wasm 和 JS 都能编辑结构体的成员。刷新 `moon update` 后带 `--registry` 可从公共注册表安装 `moon.mod` 声明的版本。 |
| 发布和贡献关系 | 查看仓库默认分支、`moon.mod`、[有效提交证据](SUBMISSION_REQUIREMENTS_CHECK.md)、[来源授权](../THIRD_PARTY.md) | 仓库和 Mooncakes 使用 HYF-ai2006 命名。仓库包含 10 次以上实质提交和 Apache-2.0 标识。 |

首次复现请使用 README 中的固定 MoonBit 工具链及命令。按用户实际常用流程验收时，可先 `inspect` 和 `extract` 找到故障记录，再 `decode` 成 JSON，编辑成员后 `encode` 为新文件。

一次执行本地全量回归可用 `python scripts/validate.py --release-tests`。安装 Rust 后同一命令会补跑 Rust 对照。分发测试中 ZIP 依赖与注册表安装是两项不同的验证，发布状态见 [SUBMISSION_STATUS.md](SUBMISSION_STATUS.md)。

## 待验证条件

- Classic ARXML 支持当前列出的定宽字节对齐字段和可精确表示的单段线性定点描述。复杂网络表示、条件变体与更多供应方样本继续按矩阵核对。
- GetLogInfo 状态 7 按规范标志和列表说明实现并通过构造向量。扩展外部样本有助于确认不同工具的线格式差异。
- 端点效果由可重放的内存宿主验证，真实硬件和专用应用回调需要部署方提供对应环境。附带的条款矩阵保留适用角色、证据和条件。 [R19-11 条款矩阵](R19_11_REQUIREMENTS.md)
