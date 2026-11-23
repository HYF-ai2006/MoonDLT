# 独立黄金向量

生产者：pydlt 0.3.5，MIT，来源为 <https://github.com/mikiepure/pydlt>。

这些记录只含本工程公开合成值。JSON 保存 54 个消息/封装组合、独立预期类型值与 SHA-256；`.dlt` 文件拼接 18 个 Storage 记录，便于外部工具读取。

```sh
python -m pip install --target work/pydeps pydlt==0.3.5
python scripts/interop.py --check-fixtures
```

主动修改向量定义时，用 `--generate-fixtures` 重建并审查差异。常规测试不会自动更新预期值。完整双向互操作执行 `python scripts/interop.py`，原理和范围见 `docs/VALIDATION.md`。
