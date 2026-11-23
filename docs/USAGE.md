# 使用指南

## 命令行读取现有文件

```sh
node scripts/moondlt.mjs inspect input.dlt --filter 'apid == "APP" && level <= 4' --limit 20
node scripts/moondlt.mjs extract input.dlt selected.dlt --filter 'ecu == "ECU1"'
```

Node.js 22+ 负责范围文件 I/O，MoonBit 负责协议与查询。当前文件入口只接受 Storage 封装，每次扫描最多一百万条记录。摘要上限不改变扫描和匹配总数；提取保留完整原记录，输出文件必须尚不存在。`inspect` 不解释参数载荷，类型参数可通过下面的库接口按需读取。

以下片段用于自己的 MoonBit 函数体；含编解码的函数需要声明 `raise DltError`，同时调用 JSON 文本解析时还需处理 `@json.ParseError`。导入模块为 `"local/moondlt" @dlt`；读取 JSON 文本还需 `"moonbitlang/core/json"`。`local` 是当前本地命名空间，发布前按维护者账户调整。

## 先分清三个封装和两个时钟

`Storage` 是每条前有 `DLT\x01` 与接收时间的 `.dlt` 文件；`Network` 从标准头开始；`Serial` 从 `DLS\x01` 开始。调用者指定封装，不让库在损坏字节中随意猜测。

```moonbit
let first = @dlt.decode(file_bytes[:], framing=Storage)
let exactly_one = @dlt.decode_exact(one_record[:], framing=Storage)
let messages = @dlt.decode_all(file_bytes[:], max_messages=10000)
```

`decode` 返回 `consumed`，输入可以有后续记录；`decode_exact` 拒绝多余尾部。Storage 的秒/微秒是接收端墙钟；Header 的 `timestamp` 是 ECU uptime 的 0.1 毫秒 tick，不能直接当 Unix 时间。

## 构造带类型的日志

```moonbit
let header : @dlt.Header = {
  ..@dlt.Header::new(counter=7, endian=Little),
  extended: Some({
    verbose: true, message_type: 0, subtype: 4,
    argument_count: 0, application: "PWR", context: "TEMP",
  }),
}
let storage : @dlt.StorageHeader = {
  seconds: 1700000000U, microseconds: 123456U, ecu: "ECU1",
}
let message = @dlt.Message::with_arguments(
  header, [Text(Utf8, "温度"), Signed(16, 87L)], storage~,
)
let wire = @dlt.encode(message)
let arguments = @dlt.decode_exact(wire[:]).arguments()
```

`with_arguments` 自动更新参数数目，不用调用者手算类型词和消息长度。位宽和整数范围受检。需要 VARI、FIXP 或数值数组时改用 `VerboseParameter` 和 `with_parameters`，并用 `parameters()` 解码；简单标量解码器不会猜测高级布局。

```moonbit
let array = @dlt.VerboseParameter::array(
  IntValue(16), [2, 2],
  [Signed(16, 1L), Signed(16, 2L), Signed(16, 3L), Signed(16, 4L)],
)
let bottom_row = array.section([1, 0], [1, 2])
let bottom_right = array.at([1, 1]).as_int64()
```

数组按 C 顺序平铺；区域步长为正，不转置轴，重塑必须保持元素数。`as_double()` 默认拒绝不能精确表达的整数转换，确需近似时显式指定 `allow_lossy=true`。固定点物理值也可能发生 Double 近似；原始整数仍保留。

## 分片、失败状态和恢复

```moonbit
let limits : @dlt.Limits = {
  ..@dlt.Limits::default(), buffered_bytes: 131072, resync_bytes: 4096,
}
let decoder = @dlt.StreamDecoder::new(limits~)
let first_batch = decoder.feed(chunk_a[:])
let next_batch = decoder.feed(chunk_b[:])
decoder.finish()
```

待处理字节加新块不能超过 `buffered_bytes`，宿主应按预算读块。消息只在完整后返回；`finish` 拒绝残缺尾部。任何失败都会令读取器不能继续 `feed`，需显式 `reset` 并按应用策略重新开始，不能在失败后假定输入已全部交付。

```moonbit
let recovering = @dlt.StreamDecoder::new(
  framing=Storage, limits~, recover=true,
)
let batch = recovering.feed(damaged_chunk[:])
let skipped_in_batch = batch.skipped
let total_skipped = recovering.skipped_bytes()
```

只有 Storage/Serial 有稳定魔数，允许恢复；Network 恢复被拒绝。扫描上限限制连续跳过字节。恢复成功不证明日志完整；残缺尾部仍需处理，只有调用者明确接受丢弃时才能用 `discard_tail()`。

`StreamTranscoder` 提供选择、变换、输出回调；回调可能已经写出之前记录，随后错误不能撤销外部输出。需要原子文件结果的应用应写临时文件，全部成功后再由宿主替换目标。

## 固定过滤与头字段表达式

```moonbit
let entries = @dlt.build_index(file_bytes[:])
let filter : @dlt.Filter = {
  ..@dlt.Filter::all(),
  applications: Some(["PWR"]), maximum_log_level: Some(4),
}
let selected = @dlt.query_index(entries[:], filter, limit=1000)
let subset = @dlt.copy_indexed(file_bytes[:], selected[:])
let expression = @dlt.FilterExpr::parse(
  "apid == \"PWR\" && level <= 4 && !(counter == 0)",
)
let by_expression = @dlt.query_expression(entries[:], expression, limit=1000)
```

固定 `Filter` 的空条件匹配全部，显式空列表不匹配任何值。等级过滤只匹配日志类型，等级数越小越严重。表达式支持 `!`、`&&`、`||`、括号和受类型检查的比较；输入字节、token、深度和节点数受 `ExpressionLimits` 约束。

| 字段 | 含义 |
| --- | --- |
| `ecu`、`storage_ecu` | 优先采用消息 ECU 的有效 ID；仅 Storage 头 ECU |
| `apid`、`ctid` | 应用和上下文 ID |
| `type`、`level` | 消息类型和日志等级，使用整数值 |
| `counter`、`session` | 消息计数和可选 session |
| `timestamp`、`time_us` | uptime tick；Storage Unix 微秒 |
| `verbose` | 布尔模式标志 |

不存在的字段使比较为 false，包括 `!=`；`!` 再否定比较结果。标识符只允许 `==`/`!=`，数值支持顺序比较。表达式不执行载荷脚本或任意正则。

## 大文件：只读头，再取所需记录

文件、HTTP Range、Blob 或宿主缓存可实现精确读取回调：

```moonbit
let source = @dlt.Source::new(file_size, (offset, length) => {
  read_exact_at(offset, length)
})
let window = @dlt.WindowSource::new(source, window_bytes=65536)
let cursor = @dlt.SourceCursor::new(
  window.as_source(), max_entries=1000000UL,
)
while cursor.next_entry() is Some(entry) {
  if entry.header.counter == 7 {
    let message = source.read_entry(entry)
    consume(message)
  }
}
```

`file_size` 为 UInt64；`read_exact_at` 和 `consume` 是宿主提供的函数。回调必须精确返回所求长度，输入在遍历/查询期间保持稳定。游标只读取封装和头，跳过无关载荷；它不保证这些载荷语义有效。窗口不是整个文件的副本，大请求会绕过窗口。仅有内存数据时可直接用 `Source::from_bytes(bytes)`。

## 保存侧目录，并默认重新核验

```moonbit
let catalog = @dlt.SourceCatalog::build(source, max_entries=100000)
let sidecar_json = catalog.to_json().stringify()
// 宿主把 sidecar_json 保存为文件；再次打开时先限制 JSON 文本大小。
let json = @json.parse(
  sidecar_text[:], max_nesting_depth=64, reject_duplicate_keys=true,
)
let restored = @dlt.SourceCatalog::from_json(json, max_entries=100000)
let indexed = restored.open(source)
let results = indexed.select(filter, maximum=1000, payload_budget=1048576)
```

`from_json` 检查字段、范围、连续覆盖和条目预算，但结构正确的 JSON 仍可能来自不可信来源。默认 `open` 会核对采样源标识，并逐条扫描源记录头与目录元数据比较；通过后才能依赖 `indexed.query/select` 做选择。选中记录读取时再次检查记录与索引是否相符。

源标识只对头尾样本做非密码学散列，用于发现意外复用过期目录，不是数字签名或全文件完整性证明；未采样载荷变化可能不被发现。`open_trusted(source)` 跳过逐头复核，只能用于调用者自己验证并控制的侧目录。对不可信目录使用此快速路径，篡改的头信息可能让查询遗漏记录。即使逐头复核成功，宿主也必须保持源不变；需要载荷语义验证时使用 `source.verify(check=...)`。

`restored.query(filter)` 只对目录本身查询，不说明其已与源核对；面向外部侧文件的应用应先 `open`，然后通过返回的 `IndexedSource` 查询。`select` 的 `payload_budget` 是累计载荷预算，仍有消息对象和头元数据开销。

## nonverbose：显式字典，不从字节猜结构

```moonbit
let key : @dlt.SchemaKey = {
  application: "PWR", context: "TEMP", message_id: 100U,
}
let dictionary = @dlt.Dictionary::new(capacity=32)
dictionary.register({
  key,
  fields: [{ name: "temperature", kind: SignedInteger(16), unit: Some("degC") }],
})
let values : Array[@dlt.NamedValue] = [
  { name: "temperature", unit: Some("degC"), value: Signed(16, 87L) },
]
let payload = dictionary.encode(key, values[:], Little)
let header : @dlt.Header = {
  ..@dlt.Header::new(),
  extended: Some({
    verbose: false, message_type: 0, subtype: 4,
    argument_count: 0, application: "PWR", context: "TEMP",
  }),
}
let message = @dlt.Message::new(header, payload)
let decoded_values = dictionary.decode(message)
```

匹配键、顺序、名称、单位和位宽必须与注册结构一致；载荷含四字节消息 ID。字典可通过 `to_json/from_json` 保存，但没有完整 FIBEX XML 导入；未知消息仍可保留原字节交给其他工具。

## 控制消息只是字节

```moonbit
let request = @dlt.ControlRequest::GetSoftwareVersion
let message = @dlt.control_request_message(request, @dlt.Header::new())
let network_bytes = @dlt.encode(message, framing=Network)
let decoded_request = @dlt.decode_exact(network_bytes[:], framing=Network).control_request()
```

上述代码不会连接设备或执行操作。发送、授权、响应关联、超时和重试由应用负责。控制请求不应当作普通 verbose 参数解释。

## 保留原消息与解释参数的两种 JSON

`message.to_json()` 产生 `moondlt.message.v1` 信封，保留原始 `payload_hex`；`Message::from_json` 验证结构并恢复字节，不强行解码未知载荷。参数的 `to_json()` 则保留位宽、整数十进制字符串、浮点位表示、文本编码和高级元数据，适合消费已支持类型。

如果要保持未知类型或 signaling NaN 原始载荷位，使用原消息信封或直接复制消息字节。f32 到 Double 的解释可能改变 signaling NaN 表示，不能再由参数 JSON 反推原始位型。完整限制见 [COMPATIBILITY.md](COMPATIBILITY.md)。
