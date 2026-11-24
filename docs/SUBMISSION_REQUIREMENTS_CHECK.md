# MoonDLT 八项申报要求核对与有效提交证据

核对日期：2026-11-24。核对口径为申报人本次提供的八项要求；本报告不替代主办方审核。材料修订前的核验基线为 `a2245b1f7d627dadababf29376aa49b10836d2ef`，已核对 GitHub 默认分支 `main` 与本地一致、公开可访问。

## 八项申报内容核对

| 要求 | 发现与处理 | 修订后证据 |
| --- | --- | --- |
| 1. 项目名称 | 原有名称保留，增加与要求一致的编号 | `PROPOSAL.md` 第 1 项 |
| 2. 项目简介 | 说明处理对象、交付 API 及 MoonBit/Wasm 集成价值 | 第 2 项 |
| 3. 项目方向、通用性 | 单独列出协议库方向、宿主 I/O、可配置字段和布局、四目标验证及相邻项目差异 | 第 3 项与 `DIFFERENTIATION.md` |
| 4. 至少 3 个完整预期场景 | **旧稿缺少独立列出的 3 个完整场景**；已补齐使用者、输入、处理、输出和验收，并区分库能力与宿主界面 | 第 4 项：日志筛选交接、分片分析、仿真数据交换 |
| 5. 拟实现核心功能 | 区分已完成 0.1.0 与后续工作，保留技术路线、验证证据和未覆盖范围 | 第 5 项与 `COMPATIBILITY.md` |
| 6. 原创/移植/参考分类 | 明确为参考标准及开源实现的原创工程，新写 MoonBit 核心，并披露 AI 辅助 | 第 6 项与 `THIRD_PARTY.md` |
| 7. 移植来源和许可证 | 没有上游源码移植；仍完整列出四个参考/验证项目名称、来源链接、许可证和使用范围 | 第 7 项与 `THIRD_PARTY.md` |
| 8. GitHub 与至少 10 次有效提交 | 已核验公开仓库、默认分支和实际差异；选取下列 10 次既有实质提交，不依赖本次材料补全提交 | 第 8 项及本报告下表 |

公共申报书与私人报名终稿的技术正文一致。私人版保留申报人及联系方式，只存放于忽略目录和本地交付文件；公共材料不包含这些联系人字段。

## 有效提交核验

修订前公开 `main` 共 15 次提交，时间范围为 2026-11-23 至 2026-11-24；GitHub API 与本地提交集合一致。逐次检查实际修改文件、增加/删除内容及提交目标，而不是仅依据提交标题或总数。

为避免依赖发布状态、身份命名空间或结果记录来计算次数，下表只选 **10 次已有的功能实现、缺陷修复、互操作测试与 CI 修复提交**。后续本次申报材料修订不计入这 10 次。

| 序号 | 公开提交 | 实际改动与独立目的 |
| --- | --- | --- |
| 1 | [c3fb7c1](https://github.com/HYF-ai2006/MoonDLT/commit/c3fb7c1694ead1a565cc98681c2c7e0e4274805c) | 建立 MoonBit 模块、DLT 公共类型、资源上限及有边界检查的字节/端序基础操作。 |
| 2 | [cbee048](https://github.com/HYF-ai2006/MoonDLT/commit/cbee048211f1f6089ec362b0d99564a0b64661c3) | 新增封装编解码、增量读取器、64 位随机访问源及 codec/source 测试。 |
| 3 | [9c08bf7](https://github.com/HYF-ai2006/MoonDLT/commit/9c08bf73ba39c016c2bdaecd3417f1553154813f) | 实现 verbose 类型参数、变量元数据、数组、类型选择与保留数值精度的 JSON，并新增载荷测试。 |
| 4 | [40c1e2e](https://github.com/HYF-ai2006/MoonDLT/commit/40c1e2e85f94ecbfb64fa30cadf9d60af388135c) | 新增源目录、消息 JSON、连续性与时间分析，强化 source/stream/codec 边界并补齐测试。 |
| 5 | [40ffd9f](https://github.com/HYF-ai2006/MoonDLT/commit/40ffd9fe8a960147b3f5f870900f8e684c621da5) | 实现头字段查询表达式、nonverbose 字典、被动控制载荷编解码及表达式/工具测试。 |
| 6 | [274ed0d](https://github.com/HYF-ai2006/MoonDLT/commit/274ed0d462b089c5bf962c454ba60b2367bac03e) | 交付 Node 文件宿主和 MoonBit 文件适配入口，验证实际文件检查、原样提取及目录安全边界。 |
| 7 | [62a43f9](https://github.com/HYF-ai2006/MoonDLT/commit/62a43f95125f39ed752f205c87a57d213f0d671c) | 引入独立 pydlt 互操作脚本、合成黄金向量、MoonBit 互操作桥接、可复现验证脚本和 CI；同时补充许可证、设计与用法。计入依据是可执行验证交付。 |
| 8 | [d74ffec](https://github.com/HYF-ai2006/MoonDLT/commit/d74ffec52ac51733d085883341310cfd87cb15a7) | 修复控制默认值、缺省字段的连续性、UTF-8 与预算检查、目录和文件处理问题，添加对应回归用例。 |
| 9 | [4fade09](https://github.com/HYF-ai2006/MoonDLT/commit/4fade0989cc2cb19aa46707f46150d8dc6f6c202) | 增加 192 条固定种子独立记录、从类型值重构而非直接复制载荷的互操作验证，并接入 Release/文件验证。 |
| 10 | [aad9135](https://github.com/HYF-ai2006/MoonDLT/commit/aad913513736007fa93bb1a8c42036c00423af35) | 固定编译器和 core 到实际验证版本并记录工具链，解决云端工具链漂移引起的检查失败，保留全部 CI 检查。 |

辅助机械检查：

- 使用 `git diff-tree --root --numstat -r` 检查全部 15 次提交，没有空改动。
- 使用 `git show --binary` 与 `git patch-id --stable` 比较全部提交，没有相同补丁 ID；该结果仅作为辅助，不单独证明所有提交都有效。
- 上述 10 次按协议层、数据模型、查询工具、独立验证与已发生缺陷组织，均有对应的源码、测试或 CI 变更；未发现仅为了次数而拆出的单行格式提交。
- 命名空间准备、注册表状态、待授权状态、CI 结果记录及此前材料措辞共 5 次提交没有用于本表的 10 次下限，不将其混称为 15 次核心开发提交。
- 本次不重写、复制或补造既有历史；只新增实际需要的申报材料修订。有效性的最终认定仍由主办方作出。

## 参考来源与许可证核对

已通过上游 GitHub 内容及 license API 核对公开声明：

| 项目 | 许可证证据 | 本工程使用范围 |
| --- | --- | --- |
| COVESA dlt-daemon | [LICENSE](https://github.com/COVESA/dlt-daemon/blob/master/LICENSE)：MPL-2.0；文件级声明以各文件为准 | 协议结构与能力对照，未复制实现源码或 daemon |
| esrlabs/dlt-core | [LICENSE.txt](https://github.com/esrlabs/dlt-core/blob/master/LICENSE.txt)：Apache-2.0 | 设计和能力范围对照，未复制源码 |
| JulianSchmid/dlt-parse-rs | [Cargo.toml](https://github.com/JulianSchmid/dlt-parse-rs/blob/main/Cargo.toml)：MIT OR Apache-2.0；附有两份许可证 | 可嵌入解析库的职责与部署范围对照，未复制源码 |
| pydlt | [LICENSE](https://github.com/mikiepure/pydlt/blob/master/LICENSE)：MIT | 0.3.5 仅作独立开发验证依赖，通过公共 API 生成合成向量 |

AUTOSAR R19-11 是协议标准来源，不按开源项目移植处理；工程仅链接引用，不分发标准 PDF。项目根目录 `LICENSE` 为 Apache-2.0，具体来源关系保持在 `THIRD_PARTY.md`。

## 检查边界

本次按新增申报要求补正文档并核验历史，不改动运行源码。四目标、Release、独立互操作和文件入口的验证证据可从 [CI](https://github.com/HYF-ai2006/MoonDLT/actions/workflows/check.yml)、`LOCAL_VALIDATION.json` 与前次终检报告查看。本报告不声称已提交报名或已获初审通过。
