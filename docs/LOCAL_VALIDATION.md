# 本地验证记录

记录时间：2026-11-28T13:44:37.759471+08:00。结果：**PASS_WITH_LIMITATIONS**。

本文件由 `scripts/validate.py` 按实际执行结果生成。该脚本只记录本地检查，不执行远程推送、报名或发布。

| 检查 | 结果 |
| --- | --- |
| `format` | PASS |
| `compile_all` | PASS |
| `test_wasm` | PASS (76/76) |
| `test_wasm_gc` | PASS (76/76) |
| `test_js` | PASS (76/76) |
| `demo` | PASS |
| `interfaces` | PASS |
| `source_scale` | PASS |
| `independent_interop` | PASS |
| `seeded_interop` | PASS |
| `file_cli` | PASS |
| `arxml` | PASS |
| `public_package` | PASS |
| `review_record` | PASS |
| `test_release_wasm` | PASS (76/76) |
| `test_release_js` | PASS (76/76) |
| `test_native` | NOT_RUN: Windows MSVC C++ compiler/linker and SDK are unavailable in this environment |

核心源码：9216 物理行，去除注释和空行后 8181 行，进一步去除纯结构符号后 **6437 严格有效行**。测试、示例、生成文件和依赖均未计入核心。

复现：`python scripts/validate.py --release-tests`。机器记录见 `LOCAL_VALIDATION.json`，完整日志在忽略目录 `work/validation/`。

对照工具的范围与实际用例见条款矩阵。验收使用标准合成记录和宿主重放。远程 CI 和发布状态见 `SUBMISSION_STATUS.md`。
Windows 原生运行需要 MSVC C++ 编译环境与 SDK，未运行项不能视为通过。
