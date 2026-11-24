# 本地验证记录

记录时间：2026-11-24T10:53:07.022001+08:00。结果：**PASS_WITH_LIMITATIONS**。

本文件由 `scripts/validate.py` 按实际执行结果生成。未进行远程推送、报名或发布。

| 检查 | 结果 |
| --- | --- |
| `format` | PASS |
| `compile_all` | PASS |
| `test_wasm` | PASS (56/56) |
| `test_wasm_gc` | PASS (56/56) |
| `test_js` | PASS (56/56) |
| `demo` | PASS |
| `interfaces` | PASS |
| `source_scale` | PASS |
| `independent_interop` | PASS |
| `seeded_interop` | PASS |
| `file_cli` | PASS |
| `test_release_wasm` | PASS (56/56) |
| `test_release_js` | PASS (56/56) |
| `test_native` | NOT_RUN: Windows MSVC C++ compiler/linker and SDK are unavailable in this environment |

核心源码：6273 物理行，去除注释和空行后 5511 行，进一步去除纯结构符号后 **4315 严格有效行**。测试、示例、生成文件和依赖均未计入核心。

复现：`python scripts/validate.py --release-tests`。机器记录见 `LOCAL_VALIDATION.json`，完整日志在忽略目录 `work/validation/`。

局限：高级 VARI/FIXP/数组未获得独立 pydlt 互操作证明；没有实车或量产日志语料；云端 CI 尚未执行。
Windows 原生运行需要 MSVC C++ 编译环境与 SDK，未运行项不能视为通过。
