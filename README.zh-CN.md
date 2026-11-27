# cordis-lua

[Cordis](https://github.com/cordiverse/cordis) 4.x 的纯 Lua 5.5 移植版：包含上下文树、带副作用清理的 Fiber、依赖追踪服务以及事件派发。零原生依赖，MIT 协议。对齐的上游提交见 [`UPSTREAM`](UPSTREAM)。

[English](README.md) | 简体中文

## 适用场景

插件重载后，旧监听器或定时器可能继续运行，甚至读到失效的服务状态。`cordis-lua` 通过 `ctx:effect` 把插件自管资源绑定到所属 Fiber（内置的 `provide`、`on` 和定时器都基于它实现）。插件重载或销毁时，同一 Fiber 下的清理句柄按逆序启动并并发等待完成（同一个 `effect` 迭代器收集的多个清理项则按逆序串行执行），服务提供方会等到所有依赖它的消费方卸载后再清理，需要隔离的服务名则通过 `ctx:isolate` 显式限定到子树。

核心代码从不调用 `coroutine.create` 或 `coroutine.resume`。传入宿主自己的 `spawn` 和 `latch`（例如 `mlua`、`tokio` 或主循环）即可接入，独立运行则使用自带的 `cordis.host.coroutine`。

如果只是写一次性脚本，或启动时 `require` 几个固定模块后不再变动，直接用原生表和函数更简单。需要热重载、依赖注入或插件作用域隔离时，再引入 `cordis-lua`。

## 快速开始

把 `lua/` 加入 `package.path`，创建宿主调度器并在任务内运行：

```lua
local cordis = require("cordis")
local sched = require("cordis.host.coroutine").new()

local ok, err = sched.drive(function()
  local root = cordis.Context.new({ host = sched.host })

  -- 在根上下文监听事件
  root:on("ready", function(msg)
    print("event:", msg)
  end)

  -- 提供服务；返回可调用、可等待的 EffectDisposer 表
  root:provide("greeting", "hello")

  -- 创建子作用域（Fiber），注入 "greeting" 并注册资源释放函数
  local child = root:inject({ "greeting" }, function(ctx)
    ctx:effect(function()
      print("child active:", ctx.greeting)
      return function()
        print("child disposed")
      end
    end)
    ctx:emit("ready", ctx.greeting .. " from child")
  end)

  cordis.await(child)
  cordis.await(child:dispose())
  root:close():await()
end)
assert(ok, err)
```

将上面的代码保存为 `quickstart.lua`，在仓库根目录运行：

```sh
LUA_PATH="lua/?.lua;lua/?/init.lua;;" lua quickstart.lua
```

输出：

```text
child active:	hello
event:	hello from child
child disposed
```

`root:inject` 创建一个子 Fiber，等到 `"greeting"` 就绪后执行回调。回调里的 `ctx:effect` 返回一个可调用、可等待的 `EffectDisposer` 句柄表，并把 setup 回调返回的清理函数绑定到这个子 Fiber。调用 `child:dispose()` 会执行该清理函数并将子 Fiber 从注册表移除；`root:close()` 返回关闭根上下文的 `Future`，调用 `root:close():await()` 等待清理全部完成。

## 整体结构

- **Context 上下文树**：`Context` 节点通过原型链继承属性、隔离键和拦截配置（`extend`、`isolate`、`intercept`），同时把注册动作记录到所属 Fiber。
- **Fiber 与副作用**：`ctx:use` 和 `ctx:inject` 创建 `Fiber`（状态包括 `PENDING`、`LOADING`、`ACTIVE`、`FAILED`、`UNLOADING`、`DISPOSED`）。通过 `ctx:effect` 注册的资源会在所属 Fiber 重载或销毁时卸载。
- **服务与依赖注入**：`ctx:provide` 把服务写进当前隔离槽位。消费方在 `inject` 中声明后即可读取 `ctx.<name>`（祖先和根作用域也可按隔离范围读取），或继承 `cordis.Service` 获得 `[Service.init]` 初始化钩子，让服务方法保留调用方上下文。
- **事件系统**：`ctx:on` 和 `ctx:once` 将监听器绑定到 Fiber 生命周期。`emit`、`bail`、`waterfall` 同步派发；`parallel` 和 `serial` 返回 `Future`；传入带 `[cordis.Context.filter]` 的 `thisArg` 可按隔离作用域过滤监听器。
- **可插拔宿主**：`Context.new({ host = ... })` 接收实现 `spawn` 与 `latch`（及可选 `sleep`、`now`、`capture`）的 `cordis.Host`，契约见 [docs/api-core.md §1](docs/api-core.md#1-host-and-async-primitives)。独立运行与测试使用内置的 `cordis.host.coroutine`。

## 模块列表

| 模块 | 内容 |
| :-- | :-- |
| `cordis` ([`lua/cordis/init.lua`](lua/cordis/init.lua)) | 统一入口，导出核心类、异步原语、Symbol 与错误类型 |
| 核心运行时与辅助模块（`lua/cordis/*.lua`） | 上下文树、Fiber 生命周期、依赖注入与反射、`Service`、事件、日志、`Future`/异步、对象模型与内部缓存；完整 27 模块清单见 [docs/README.md](docs/README.md) |
| `cordis.timer` ([`lua/cordis/timer.lua`](lua/cordis/timer.lua)) | `TimerService`（`ctx:timeout`、`ctx:interval`、`ctx:throttle`、`ctx:debounce`），基于 `host.sleep` 与 `host.now` |
| `cordis.loader` ([`lua/cordis/loader/init.lua`](lua/cordis/loader/init.lua)) | `Loader`、`EntryTree`、`EntryGroup`、`Entry`、`LocalRealm`、`{ __luaExpr = "..." }` 表达式求值与插值 |
| `cordis.host.coroutine` ([`lua/cordis/host/coroutine.lua`](lua/cordis/host/coroutine.lua)) | 纯 Lua 协作式参考调度器，带虚拟时钟（`eager`、`auto`、`contexts`、`advance`、`runAll`、`drive`） |

## 嵌入发布版本

在项目中引入带标签的发布版本时，将 [`lua/cordis/`](lua/cordis/) 复制到 Lua 模块搜索路径中（若自带 `cordis.Host` 宿主实现，可省略 `lua/cordis/host/`），并随附 [`LICENSE`](LICENSE)。参与贡献见 [`CONTRIBUTING.md`](CONTRIBUTING.md)，安全漏洞披露见 [`SECURITY.md`](SECURITY.md)。

## 文档

- [docs/README.md](docs/README.md)：文档索引与完整 27 模块清单
- [docs/getting-started.md](docs/getting-started.md)：上下文、服务、副作用清理、事件、定时器、Loader 与自定义宿主入门（英文）
- [docs/api-core.md](docs/api-core.md)：Core Lua API 与 Host 契约（§1，英文）
- [docs/hosts.md](docs/hosts.md)：在外部调度器上运行测试套件（`--host`、`kit.runner`，英文）
- [docs/deviations.md](docs/deviations.md)：与上游的语言层差异、缺陷修复、可选扩展与性能优化（英文）

## 测试与兼容性

需要 Lua 5.5（`mise install`）。不支持 Lua 5.4：虽然源码可在 5.4 下编译，但 5.4 的 `nil` 错误传播行为与 5.5 不同，可能让失败的 Fiber 停留在 `PENDING` 而不是进入 `FAILED`。逐条上游用例移植状态见 [docs/port-status.md](docs/port-status.md)（由 [`test/kit/port_check.lua`](test/kit/port_check.lua) 校验）。

```sh
lua test/run.lua             # 延迟 spawn 模式
lua test/run.lua --eager     # 立即 spawn 模式
lua test/run.lua --contexts  # 启用执行上下文捕获
lua test/run.lua --filter fiber
just check                   # 4 种测试模式（延迟/立即 x capture）、stylua、luac -p、port_check
```

也可以通过 `lua test/run.lua --host <module>` 或在嵌入方的测试环境里调用 `require("kit.runner").run({ files = ..., scheduler = factory })` 来测试宿主自己的调度器（接口见 [`test/kit/runner.lua`](test/kit/runner.lua)）。缺少虚拟时钟或 `debug` 库时，依赖它们的用例会跳过并列出原因，见 [docs/hosts.md](docs/hosts.md)。

## 许可证

采用 [MIT 许可协议](LICENSE)。
