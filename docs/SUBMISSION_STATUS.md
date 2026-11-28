# 申报材料状态

2026-11-24：用户已授权将 `D:\CodexProjects\MoonDLT` 发布至 GitHub 与 Mooncakes。目标仓库为 [HYF-ai2006/MoonDLT](https://github.com/HYF-ai2006/MoonDLT)，包名为 `HYF-ai2006/moondlt`。

2026-11-28 复审：GitHub 源码 0.2.0 增加三项评审指出的标准载荷和实际文件复现。参赛评审以 GitHub main、[申报书](../PROPOSAL.md)、[条款矩阵](R19_11_REQUIREMENTS.md)及[当前 CI](https://github.com/HYF-ai2006/MoonDLT/actions/workflows/check.yml)为依据。Mooncakes 的已发布基础版为 0.1.0。

本轮验收复现入口见 [ACCEPTANCE.md](ACCEPTANCE.md)。源码可构建 Mooncakes 0.2.0 ZIP，并支持从归档安装后的独立运行核对。实际注册表版本以 Mooncakes 为准。

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
