# 知识库 Unix Socket 接入规范

## 1. 目的

本文档定义 LLM Wiki 知识库辅助通道的接入方式、协议规范、字段约束、注意事项和错误处理约定。

这条通道的定位是：

- 本地桌面应用辅助通道
- 标准 HTTP/REST 语义
- 传输使用 Unix Domain Socket
- 不对外开放 TCP/http 端口

## 2. 协议模型

### 2.1 分层

- 传输层：Unix Domain Socket
- 协议层：HTTP/1.1
- 负载：`application/json; charset=utf-8`

这意味着：

- 仍然使用 `GET /status`、`POST /vector_stores/search` 这类 HTTP 路径和方法
- 但请求不是发到 `127.0.0.1:19827`
- 而是通过本机 socket 文件发给服务端

### 2.2 主 socket 与 heartbeat socket

主知识库 socket：

- 默认路径：`$HOME/.llm-wiki/run/knowledge-base-api.sock`
- 用途：搜索、文档读取、项目状态、服务状态

heartbeat socket：

- 默认路径：`$HOME/.llm-wiki/run/knowledge-base-heartbeat.sock`
- 用途：探活与 readiness 检查

metadata 文件：

- 默认路径：`$HOME/.llm-wiki/run/knowledge-base-api.json`
- 用途：发现 socket 路径、endpoint、transport、health 信息

### 2.3 安全边界

- 知识库接口在 Unix 平台不绑定 TCP 端口
- TCP `127.0.0.1:19827` 上访问知识库路径会返回 `403`
- 权限控制依赖文件系统权限：
  - runtime dir: `0700`
  - socket file: `0600`
  - metadata file: `0600`

## 3. 服务发现

推荐接入顺序：

1. 读取 `knowledge-base-api.json`
2. 获取 `socketPath`、`heartbeatSocketPath`、`healthEndpoint`
3. 调用 heartbeat `GET /health`
4. `ready=true` 后再调用主接口

metadata 实际结构：

```json
{
  "transport": "http+unix",
  "socketPath": "/Users/name/.llm-wiki/run/knowledge-base-api.sock",
  "statusEndpoint": "/status",
  "projectEndpoint": "/project",
  "searchEndpoint": "/vector_stores/search",
  "searchAliases": ["/knowledge-base/query"],
  "ingestEndpoint": "/knowledge-base/ingest",
  "documentEndpoint": "/knowledge-base/document",
  "heartbeatSocketPath": "/Users/name/.llm-wiki/run/knowledge-base-heartbeat.sock",
  "healthEndpoint": "/health",
  "ready": true,
  "status": "ready",
  "reason": "knowledge base socket is ready"
}
```

## 4. Endpoint 规范

### 4.1 主 socket canonical endpoint

- `POST /vector_stores/search`
- `POST /knowledge-base/ingest`
- `POST /knowledge-base/document`
- `GET /status`
- `GET /project`
- `POST /project`

### 4.2 主 socket alias endpoint

- `POST /knowledge-base/query`

说明：

- `POST /knowledge-base/query` 与 `POST /vector_stores/search` 等价
- 建议新接入统一使用 canonical 路径

### 4.3 heartbeat endpoint

- `GET /health`

## 5. 通用接入规范

### 5.1 请求格式

- 编码：UTF-8
- JSON body：仅 `POST` 使用
- `Content-Type`：建议显式传 `application/json`
- `GET` 请求不应携带 body

### 5.2 路径规范

- `projectPath` 必须是绝对路径
- 建议每次请求都显式传 `projectPath`
- 不建议强依赖 `POST /project` 的进程级共享状态

### 5.3 超时建议

建议调用方设置：

- `/health`：1s ~ 2s
- `/status`：1s ~ 2s
- `/knowledge-base/ingest`：1s ~ 5s
- `/vector_stores/search`：5s ~ 20s
- `/knowledge-base/document`：5s ~ 20s
- 语义检索开启时，如果 embedding endpoint 在远端，建议 15s 以上

### 5.4 响应处理规范

- 先看 HTTP status code
- 再看 JSON body
- 错误 body 统一读取 `error`

## 6. 搜索接口规范

### 6.1 请求

Endpoint：

- `POST /vector_stores/search`
- `POST /knowledge-base/query` `alias`

请求体：

```json
{
  "projectPath": "/absolute/path/to/project",
  "query": "知识库安全",
  "filters": {
    "type": "and",
    "filters": [
      { "key": "source", "type": "eq", "value": "wiki" },
      { "key": "type", "type": "in", "value": ["concept", "entity"] }
    ]
  },
  "max_num_results": 10,
  "ranking_options": {
    "ranker": "auto",
    "score_threshold": 0.2
  },
  "rewrite_query": false,
  "extensions": {
    "retrieval_mode": "hybrid",
    "embedding_config": {
      "enabled": true,
      "endpoint": "https://your-endpoint/v1/embeddings",
      "apiKey": "your-token",
      "model": "text-embedding-3-large"
    }
  }
}
```

### 6.2 字段约束

| 字段 | 类型 | 必填 | 说明 |
|---|---|---:|---|
| `projectPath` | `string` | 是 | 知识库项目根目录 |
| `query` | `string \| string[]` | 是 | 查询词 |
| `filters` | `object` | 否 | 过滤表达式 |
| `max_num_results` | `number` | 否 | 默认 `10`，范围 `1..50` |
| `ranking_options.score_threshold` | `number` | 否 | 结果最小分数阈值 |
| `ranking_options.ranker` | `string` | 否 | 保留字段，当前忽略 |
| `rewrite_query` | `boolean` | 否 | 保留字段，当前忽略 |
| `extensions.retrieval_mode` | `keyword \| vector \| hybrid` | 否 | 检索模式 |
| `extensions.embedding_config` | `object` | 否 | 语义检索配置 |

### 6.3 检索模式规范

默认行为：

- 未传 `extensions.embedding_config`：`keyword`
- 已传可用 `extensions.embedding_config` 且未显式指定 `retrieval_mode`：`hybrid`

强约束：

- `retrieval_mode = "vector"` 或 `"hybrid"` 时，必须传可用的 `embedding_config`
- 否则返回 `400`

### 6.4 过滤规则

支持比较过滤：

- `eq`
- `ne`
- `gt`
- `gte`
- `lt`
- `lte`
- `in`
- `nin`

支持复合过滤：

- `and`
- `or`

常见可过滤字段：

- `path`
- `filename`
- `title`
- `source`
- `directory`
- `type`
- `tags`
- `sources`
- `related`

### 6.5 响应

```json
{
  "object": "vector_store.search_results.page",
  "search_query": ["知识库安全"],
  "data": [
    {
      "file_id": "wiki/concepts/知识库安全.md",
      "filename": "知识库安全.md",
      "score": 1.0,
      "attributes": {
        "path": "wiki/concepts/知识库安全.md",
        "title": "知识库安全",
        "source": "wiki",
        "directory": "wiki/concepts",
        "type": "concept",
        "title_match": true,
        "retrieval_mode": "keyword"
      },
      "content": [
        {
          "type": "text",
          "text": "..."
        }
      ],
      "summary": "...",
      "rag_related_info": ["..."]
    }
  ],
  "has_more": true,
  "next_page": null,
  "summary": "...",
  "rag_related_info": ["..."]
}
```

### 6.6 响应语义

- `object`：固定为 `vector_store.search_results.page`
- `search_query`：服务端规范化后的查询数组
- `data[]`：命中文档列表
- `has_more`：是否还有未返回结果
- `next_page`：当前固定为 `null`，未实现分页 token
- `summary`：结果摘要，不是全文
- `rag_related_info`：RAG 高亮摘要，不是全文
- `attributes.retrieval_mode`：最终命中模式，可能是 `keyword`、`vector`、`hybrid`

### 6.7 增量触发与自动更新

知识库支持两类“增量更新”入口：

1. 主动触发：`POST /knowledge-base/ingest`
2. 被动检测：前端 watcher 周期扫描 `raw/sources/**`

行为约定：

- `POST /knowledge-base/ingest` 只负责登记“某些源文件需要重新抽取”
- 真正的入队和执行仍由应用内 ingest 队列完成
- 同一路径的重复触发会合并，最后一次 `debounceMs` 和 `reason` 会覆盖前一次
- 前端 watcher 也会检测文件创建和修改，并在防抖后自动重新入队
- 只有“当前打开项目”对应的 watcher 会消费这些触发请求
- 默认防抖窗口是 `2500ms`
- `debounceMs` 取值会被服务端钳制到 `200..30000ms`

适用场景：

- 外部工具写入新文档后，希望立即触发知识抽取
- 同一文档在短时间内被连续保存，希望只做一次重建
- 通过软链挂载到 `raw/sources/` 的真实文件被外部编辑器修改

### 6.8 `POST /knowledge-base/ingest`

用途：

- 主动请求知识库对指定 source 文件做增量更新

请求体：

```json
{
  "projectPath": "/absolute/path/to/project",
  "sourcePath": "/absolute/path/to/project/raw/sources/shrimps/copilot_agent/note.md",
  "debounceMs": 1500,
  "reason": "save_note_to_kb"
}
```

也支持批量：

```json
{
  "projectPath": "/absolute/path/to/project",
  "sourcePaths": [
    "/absolute/path/to/project/raw/sources/a.md",
    "/absolute/path/to/project/raw/sources/b.md"
  ],
  "debounceMs": 2500,
  "reason": "bulk_sync"
}
```

字段约束：

| 字段 | 类型 | 必填 | 说明 |
|---|---|---:|---|
| `projectPath` | `string` | 是 | 知识库项目根目录 |
| `sourcePath` | `string` | 条件必填 | 单文件绝对路径 |
| `sourcePaths` | `string[]` | 条件必填 | 多文件绝对路径 |
| `debounceMs` | `number` | 否 | 默认 `2500`，最终范围 `200..30000` |
| `reason` | `string` | 否 | 触发原因，供调试和日志使用 |

请求约束：

- `sourcePath` 和 `sourcePaths` 至少传一个
- 每个 source 必须是文件，不可传目录
- 每个 source 必须位于当前项目的 `raw/sources/` 之内
- 允许传软链映射后的真实路径，也允许传项目视图路径；服务端会统一归一化

成功响应：

```json
{
  "ok": true,
  "queued": 1,
  "projectPath": "/absolute/path/to/project",
  "debounceMs": 1500,
  "requests": [
    {
      "projectPath": "/absolute/path/to/project",
      "sourcePath": "/absolute/path/to/project/raw/sources/shrimps/copilot_agent/note.md",
      "debounceMs": 1500,
      "reason": "save_note_to_kb"
    }
  ]
}
```

响应语义：

- `queued` 表示这次接受了多少条触发请求
- 它不表示抽取已经完成，只表示请求已登记
- 后续真正执行由 ingest 队列异步完成
- 如果同一路径此前已有待处理触发，请求会被更新而不是重复堆积

## 7. 文档接口规范

### 7.1 请求

Endpoint：

- `POST /knowledge-base/document`

请求体：

```json
{
  "projectPath": "/absolute/path/to/project",
  "fileId": "wiki/concepts/知识库安全.md",
  "max_related_items": 5,
  "include_related_content": false
}
```

支持定位字段：

- `fileId`
- `path`
- `filename`
- `directory`
- `source`

### 7.2 字段约束

| 字段 | 类型 | 必填 | 说明 |
|---|---|---:|---|
| `projectPath` | `string` | 是 | 知识库项目根目录 |
| `fileId` | `string` | 条件必填 | 推荐首选 |
| `path` | `string` | 条件必填 | 与 `fileId` 等价定位 |
| `filename` | `string` | 条件必填 | 仅文件名定位 |
| `directory` | `string` | 否 | 配合 `filename` 缩小范围 |
| `source` | `string` | 否 | 配合 `filename` 缩小范围 |
| `max_related_items` | `number` | 否 | 默认 `5`，最大 `10` |
| `include_related_content` | `boolean` | 否 | 是否返回相关文档正文片段 |

### 7.3 定位规范

优先级建议：

1. `fileId`
2. `path`
3. `filename + directory`
4. `filename + source`
5. `filename`

注意：

- 仅传 `filename` 且命中多个文档时返回 `409`
- `include_related_content=true` 时，相关文档正文会被截断，不保证完整

### 7.4 响应

```json
{
  "object": "vector_store.document",
  "document": {
    "file_id": "wiki/concepts/知识库安全.md",
    "filename": "知识库安全.md",
    "attributes": {
      "path": "wiki/concepts/知识库安全.md",
      "title": "知识库安全",
      "source": "wiki",
      "directory": "wiki/concepts",
      "type": "concept",
      "tags": [],
      "sources": [],
      "related": []
    },
    "content_text": "...",
    "summary": "...",
    "rag_related_info": ["..."],
    "outbound_wikilinks": ["RAG系统安全漏洞"]
  },
  "related": [
    {
      "file_id": "wiki/concepts/RAG系统安全漏洞.md",
      "filename": "RAG系统安全漏洞.md",
      "score": 0.95,
      "relation_reasons": ["wikilink -> RAG系统安全漏洞"],
      "attributes": {
        "path": "wiki/concepts/RAG系统安全漏洞.md",
        "title": "RAG系统安全漏洞",
        "source": "wiki",
        "directory": "wiki/concepts",
        "type": "concept",
        "tags": [],
        "sources": [],
        "related": []
      },
      "content_preview": "...",
      "summary": "...",
      "rag_related_info": ["..."]
    }
  ]
}
```

## 8. 状态与探活规范

### 8.1 `GET /status`

用途：

- 读取主 socket 状态与发现信息

返回关键字段：

- `transport`
- `socketPath`
- `socketInfoPath`
- `heartbeatSocketPath`
- `healthEndpoint`
- `ready`
- `status`
- `reason`

### 8.2 `GET /health`

用途：

- readiness 检查
- 判断知识库通道当前是否可接收请求

返回语义：

- `200`：`ready=true`
- `503`：`ready=false`

注意：

- `health` 表示“知识库通道就绪”
- 不表示 TCP clip server 是否可用
- 不表示外部 embedding endpoint 一定可用

## 9. 错误规范

### 9.1 错误 body 结构

服务端错误统一返回：

```json
{
  "ok": false,
  "error": "..."
}
```

### 9.2 状态码约定

| 状态码 | 场景 |
|---:|---|
| `200` | 请求成功 |
| `400` | JSON 非法、缺少必填字段、`projectPath` 非法、`retrieval_mode` 参数不合法 |
| `403` | 在 TCP 端口上调用 Unix-only 知识库接口 |
| `404` | endpoint 不存在、文档不存在 |
| `409` | 文档定位冲突，例如同名文件有多个 |
| `500` | 本地内部错误、序列化错误、向量检索内部失败 |
| `502` | embedding endpoint 请求失败或返回格式非法 |
| `503` | heartbeat 检测为未就绪 |

### 9.3 常见报错

#### 1. `projectPath does not exist`

响应：

```json
{
  "ok": false,
  "error": "projectPath does not exist: /bad/path"
}
```

原因：

- 目录不存在
- 路径拼写错误
- 调用方传了空路径拼接结果

处理：

- 使用绝对路径
- 调用前先本地校验目录存在
- 确认项目根目录不是 `wiki/` 子目录，而是项目根目录本身

#### 2. `projectPath is not a directory`

原因：

- 传入的是文件路径而不是项目目录

处理：

- 传项目根目录

#### 3. `projectPath must contain 'wiki/' or 'raw/sources/'`

原因：

- 路径存在，但不是有效知识库项目

处理：

- 确认目标目录下至少存在 `wiki/` 或 `raw/sources/`

#### 4. `extensions.embedding_config is required when retrieval_mode is 'vector'`

响应：

```json
{
  "ok": false,
  "error": "extensions.embedding_config is required when retrieval_mode is 'vector'"
}
```

原因：

- 显式要求 `vector` 或 `hybrid`
- 但没有传可用 embedding 配置

处理：

- 补充 `extensions.embedding_config`
- 或改成 `retrieval_mode = "keyword"`

#### 5. `Invalid JSON: ...`

原因：

- body 不是合法 JSON
- shell 引号转义错误

处理：

- 优先将 JSON 放到文件中再 `curl -d @body.json`
- 或使用单引号包裹完整 body

#### 6. `Document not found`

原因：

- `fileId/path/filename` 未命中

处理：

- 优先使用 `fileId`
- 先调搜索接口确认路径后再调文档接口

#### 7. `Multiple documents match filename`

原因：

- 只用 `filename` 定位，但有多个同名文件

处理：

- 改用 `fileId`
- 或补 `directory` / `source`

#### 8. `403 Knowledge base API only accepts Unix socket requests on this platform`

原因：

- 在 Unix 平台走了 TCP 路径

处理：

- 改为 `curl --unix-socket ...`
- Node 侧改用 `http.request({ socketPath, ... })`

#### 9. `sourcePath or sourcePaths is required`

原因：

- 调用了 `/knowledge-base/ingest`
- 但没有传 `sourcePath` 或 `sourcePaths`

处理：

- 单文件触发时传 `sourcePath`
- 多文件触发时传 `sourcePaths`

#### 10. `sourcePath does not exist`

原因：

- 触发时传了不存在的真实文件路径

处理：

- 先确保文件已经真正落盘
- 再调用 `/knowledge-base/ingest`

#### 11. `sourcePath is not a file`

原因：

- 传入的是目录路径，不是文件路径

处理：

- 改为传具体文件

#### 12. `sourcePath must be inside project raw/sources`

原因：

- 触发路径不在当前项目的 `raw/sources/` 树下
- 或路径归一化后落到了项目外部

处理：

- 只对项目内的 source 文件调用增量触发
- 如果你使用了软链目录，传项目视图路径或真实落点路径都可以，但最终必须映射回 `raw/sources/`

## 10. 注意事项

### 10.1 不建议把 `POST /project` 当成强依赖

原因：

- 它是进程级共享状态
- 同一进程内不同调用方会相互影响

建议：

- 每次请求显式传 `projectPath`
- `POST /project` 只用于本地单用户串行工具链

### 10.2 `ranker` 和 `rewrite_query` 当前是保留字段

现状：

- 会被接受
- 不会报错
- 当前不会参与实际检索逻辑

建议：

- 不要依赖它们改变结果
- 如需稳定行为，请只使用已生效字段

### 10.3 `summary` / `rag_related_info` 不是全文

现状：

- 它们是提炼字段
- 适合摘要展示、结果概览
- 不适合做全文存档或精确引用

建议：

- 需要全文时调用 `POST /knowledge-base/document`

### 10.4 搜索结果不包含缓存和隐藏产物

现状：

- `.cache`
- 隐藏文件/隐藏目录
- 图片/媒体/二进制占位内容

都不会进入知识库检索结果。

### 10.5 语义检索依赖外部 embedding endpoint

现状：

- `vector/hybrid` 需要 embedding 配置
- endpoint 不可用时可能返回 `502`

建议：

- 接入方自行设置超时与重试
- 语义检索失败时，可降级到 `keyword`

### 10.6 自动更新依赖应用内 watcher 处于运行状态

现状：

- `/knowledge-base/ingest` 只负责登记待处理源文件
- 真正把触发请求转成 ingest 队列任务的是应用内 watcher
- 直接修改 `raw/sources/` 文件的“自动重建”也依赖同一个 watcher
- 当前实现只会处理“当前打开项目”的增量触发请求

建议：

- 如果你需要自动抽取，确保 LLM Wiki 主应用处于运行状态，并且目标项目就是当前打开项目
- 纯后台只发 `/knowledge-base/ingest`，但应用未运行，或当前打开的是别的项目时，请求都不会推进到实际抽取
- 需要立即抽取时，建议同时先做 `GET /health`

## 11. 推荐调用顺序

### 11.1 稳定接入顺序

1. 读取 `knowledge-base-api.json`
2. 调 `GET /health`
3. `ready=true` 后调用 `POST /vector_stores/search`
4. 如需全文，再调用 `POST /knowledge-base/document`

### 11.2 推荐降级策略

- `health != 200`：直接不发主查询
- `vector/hybrid` 失败：降级为 `keyword`
- `filename` 冲突：回退到先搜索、再用 `file_id` 取文档

## 12. 接入示例

### 12.1 curl 搜索

```bash
curl --unix-socket "$HOME/.llm-wiki/run/knowledge-base-api.sock" \
  -H 'Content-Type: application/json' \
  -X POST http://localhost/vector_stores/search \
  -d '{
    "projectPath": "/absolute/path/to/project",
    "query": "知识库安全",
    "max_num_results": 5
  }'
```

### 12.2 curl 文档详情

```bash
curl --unix-socket "$HOME/.llm-wiki/run/knowledge-base-api.sock" \
  -H 'Content-Type: application/json' \
  -X POST http://localhost/knowledge-base/document \
  -d '{
    "projectPath": "/absolute/path/to/project",
    "fileId": "wiki/concepts/知识库安全.md",
    "max_related_items": 3
  }'
```

### 12.3 curl 触发增量抽取

```bash
curl --unix-socket "$HOME/.llm-wiki/run/knowledge-base-api.sock" \
  -H 'Content-Type: application/json' \
  -X POST http://localhost/knowledge-base/ingest \
  -d '{
    "projectPath": "/absolute/path/to/project",
    "sourcePath": "/absolute/path/to/project/raw/sources/shrimps/copilot_agent/note.md",
    "debounceMs": 1500,
    "reason": "save_note_to_kb"
  }'
```

### 12.4 curl 探活

```bash
curl --unix-socket "$HOME/.llm-wiki/run/knowledge-base-heartbeat.sock" \
  http://localhost/health
```

### 12.5 Node.js

```ts
import http from "node:http"

const socketPath = `${process.env.HOME}/.llm-wiki/run/knowledge-base-api.sock`
const body = JSON.stringify({
  projectPath: "/absolute/path/to/project",
  query: "知识库安全",
  max_num_results: 5,
})

const req = http.request(
  {
    socketPath,
    path: "/vector_stores/search",
    method: "POST",
    headers: {
      "Content-Type": "application/json",
      "Content-Length": Buffer.byteLength(body),
    },
  },
  (res) => {
    let data = ""
    res.setEncoding("utf8")
    res.on("data", (chunk) => {
      data += chunk
    })
    res.on("end", () => {
      console.log(res.statusCode, JSON.parse(data))
    })
  },
)

req.on("error", console.error)
req.write(body)
req.end()
```

### 12.6 Python

```python
import json
import socket
import os

socket_path = f"{os.environ['HOME']}/.llm-wiki/run/knowledge-base-api.sock"
body = json.dumps({
    "projectPath": "/absolute/path/to/project",
    "query": "知识库安全",
    "max_num_results": 5,
}).encode("utf-8")

request = (
    b"POST /vector_stores/search HTTP/1.1\r\n"
    b"Host: localhost\r\n"
    b"Content-Type: application/json\r\n"
    + f"Content-Length: {len(body)}\r\n\r\n".encode("utf-8")
    + body
)

with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as sock:
    sock.connect(socket_path)
    sock.sendall(request)
    response = b""
    while True:
        chunk = sock.recv(65536)
        if not chunk:
            break
        response += chunk

print(response.decode("utf-8"))
```
