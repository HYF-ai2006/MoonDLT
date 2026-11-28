# 申报材料状态

维护者为 [HYF-ai2006](https://github.com/HYF-ai2006)。当前送验版本为 `HYF-ai2006/moondlt@0.2.0`，2026-11-28 19:01（北京时间）发布，注册表构建成功。全新消费者从公共注册表分别在 Wasm 与 JS 编译运行，验证结构体中 trace-info 的编辑和 128 位值的精确重编码。 [Mooncakes 0.2.0](https://mooncakes.io/docs/HYF-ai2006/moondlt)

发布归档 SHA-256 为 `421c2de0b552e60b832115329e2dd9e4eb38b07da540c696092bf02adc61a995`，对应[通过 CI 的源代码提交](https://github.com/HYF-ai2006/MoonDLT/tree/1f03754b49923e95af9045d2b6b0e683c521c8c8)。GitHub 后续文档更新记录发布结果和安装方式。 [代码验收 CI](https://github.com/HYF-ai2006/MoonDLT/actions/runs/46113529267)

复现可运行 `moon update` 和 `python scripts/test_public_package.py --registry`。参赛材料链接为 [申报书](../PROPOSAL.md)、[验收复现](ACCEPTANCE.md) 和 [R19-11 条款矩阵](R19_11_REQUIREMENTS.md)。

基础版发布记录：

- Mooncakes：2026-11-24 13:21（北京时间）已发布 `HYF-ai2006/moondlt@0.1.0`，注册表可查询。
- 独立消费者：在忽略的 `work/registry-smoke` 新模块中从注册表下载并安装 0.1.0，Wasm 与 JS 均运行成功；没有使用本地源码覆盖依赖。
- GitHub：完整代码与 CI 配置已成功推送至 `HYF-ai2006/MoonDLT`，远程默认分支为 `main`，作者和提交者均使用 HYF-ai2006 的隐私邮箱。
- 远程 CI：[完整检查已通过](https://github.com/HYF-ai2006/MoonDLT/actions/runs/45334151970)，包含 Ubuntu 上 Wasm、Wasm-GC、JS、Native 的测试、Release 测试、54 个固定互操作向量、192 条固定随机种子记录及文件消费者测试。结果元数据保存在 `CI_VALIDATION.json`。
- 工具链：首次云端运行揭示新版格式器差异；已固定编译器和 core 为 `0.10.17+093cb8f9c`，保留并通过全部检查。本机 Windows 原生环境仍缺 MSVC，不能把 Ubuntu Native 结果等同于 Windows Native 已验证。

已有：项目代码与运行示例、经逐项核对的申报终稿、生态差异证据、技术设计、兼容性边界、独立互操作与黄金样本、代码规模统计脚本、开源许可证及来源说明。公共 `PROPOSAL.md` 与私人提交版的技术正文一致；姓名和联系方式仅保留在忽略的 `out/submission/` 提交版。

已按申报人提供的八项要求重排申报书，补齐三个含输入、处理、输出和验收方式的使用场景；既有十次实质提交及来源许可证核对见 [SUBMISSION_REQUIREMENTS_CHECK.md](SUBMISSION_REQUIREMENTS_CHECK.md)。

## 当前报名入口

- [当前官方报名表](https://bxup9uklfcb.feishu.cn/share/base/form/shrcnWUMlgpbwHaXgzV7HmNhNhg)
- [当前正式章程链接](https://bxup9uklfcb.feishu.cn/wiki/Dx4Bwd6D1i3GfHkajQCcF7SznEd)
- 入口已同时核对[赛事官网源码](https://github.com/moonbitlang/Hackathon2026/blob/main/src/App.tsx)与当前官网实际部署脚本，日期为 2026-11-24。当前为十一月赛，不能沿用旧八月表单或八月截止时间。
- 官网要求公开仓库、约一页项目说明、队伍最多 3 人，并按要求加入赛事群、将群昵称改为 GitHub ID。具体截止日期以官方通知为准。
- 飞书登录后表单的实际字段和章程正文未由本次工具读取；未代填或提交报名表。

正式提交前仍需：

- 公开仓库、默认分支、注册表包和远程 CI 已核验。后续代码变更仍需重新检查，不以旧结果替代新提交的验证。
- 核实最新比赛通知中的报名/验收日期。当前官网为十一月赛，未给出可据此确定的具体截止时刻，不能沿用旧八月说明推断。
- 按官方要求完成表单与赛事群事项；这些操作未由本地开发自动完成。
- 在正式报名入口提交前，核对功能边界、代码规模、原生运行限制及高级类型互操作范围。

是否通过初审由主办方判断。差异文档的用途是提供可检查的边界与证据，不能保证审核结果，也不能把未发现公开重复解释为不存在相邻申报。
