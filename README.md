# snapgraph

事务化对象图快照库（Ruby 3.x，**零第三方依赖**：只用标准库与随 Ruby 提供的 minitest，
不许引入任何 gem，不许 Gemfile / bundler）。

它维护一张「`id` → 对象」的图，外加 `from → to` 的有向边，并提供：

- **写时复制快照**：`snapshot` 拿到一个只读视图，之后原图怎么改都看不到；
- **恢复**：`restore(snapshot)` 把图退回快照时刻，同一个快照可以反复退；
- **嵌套事务**：`transaction { ... }` 里的改动要么一起生效、要么整体回滚；
- **变更历史**：`history(id)` 看到该 `id` 上已提交的变更序列；
- **确定性导出**：`to_h` 每次导出的字节完全一致。

## 怎么跑

```bash
ruby -Ilib test/test_snapgraph.rb    # 既有用例（test/）
ruby check/checker.rb                # 固定验收程序
ruby check/checker.rb -list          # 列出全部场景
ruby check/checker.rb --only store   # 只跑一组
```

前提：**Ruby 3.x**。

> `check/` 下的 `checker.rb` 是**固定验收程序，勿改**；`test/` 里既有用例的断言、
> 以及 `lib/snapgraph/errors.rb` 里的异常类名，同样都是契约的一部分，勿改。
> 公开方法签名已经是最终形态，可以新增方法，但不要改动下面列出的这些。

## 对外契约

下面 11 条是 snapgraph 的对外契约，**它们是契约而不是「当前行为」的转述**。
语义细节以本节为准；实现方式不限，但必须让这 11 条同时成立。

1. **构造与基本读写**。`Snapgraph::Store.new` 建一张空图。`id` 是 `String`。
   - `put(id, obj)` 写入或覆盖节点值，返回 `obj`；
   - `get(id)` 返回节点值，`id` 不存在时返回 `nil`；
   - `link(from, to)` 建一条 `from → to` 的有向边，返回 `nil`；重复 `link` 幂等；
   - `unlink(from, to)` 删一条边，返回 `nil`；边不存在时幂等。
2. **写时复制（COW）快照**。`snapshot` 返回一个只读视图（`Snapgraph::Snapshot`），
   它冻结**调用时刻**的图：此后对原图做的任何 `put` / `link` / `unlink` / `restore` /
   事务提交都**不改变**这个快照；`snapshot.get(id)` 与生成时刻的 `store.get(id)` 一致。
   浅拷贝语义：快照里的值与原图里的值是**同一个对象引用**
   （生成时刻 `snapshot.get(id).equal?(store.get(id))` 为真），不深拷贝不可变叶子。
   `Snapshot` 只暴露 `get` 与 `to_h`，**不含任何写入方法**。
3. **快照是视图而不是全量拷贝**。连续 1000 次 `put` + 1000 次 `snapshot` 之后：
   - 进程内活跃对象（`ObjectSpace.count_objects[:TOTAL]`）的增量不超过
     `唯一对象数 + 快照数 × 16 + 20000`；
   - 这段过程的累计对象分配量（`GC.stat(:total_allocated_objects)` 的增量）不超过 `500000`。

   两个阈值都**按本机标定**。即快照必须靠**结构性共享**实现，
   不许 `Marshal.load(Marshal.dump(...))` 之类的整体深拷贝。
4. **循环引用**。`link` 可以构成环（包括自环）；对含环的图做 `snapshot` 与 `to_h`
   必须正常返回，不许栈溢出、不许死循环、不许漏边。
5. **`restore(snapshot)`**。把图恢复到该快照时刻的状态 —— 节点、边、以及每个 `id` 的
   变更历史都退回那一刻，此后做过的改动**全部被丢弃**；返回 `nil`。
   同一个快照可以被**反复** `restore`（幂等），且 `restore` 之后该快照仍然有效、自身不变。
6. **事务**。`transaction { ... }` 把块里的改动作为一组原子操作：块正常返回则一起生效；
   块抛异常则**这一层建立以来**的改动整体回滚，异常被记进 `errors` 并**继续向外抛出**
   （必须是同一个异常对象）。支持**嵌套**：内层回滚只回滚内层；内层回滚之前外层已做出的
   改动仍然可以照常提交。返回块的返回值。
7. **事务内的快照可见性**。事务未提交时：事务内 `get` 能看到本事务已做的改动（读己之写）；
   但事务内调用的 `snapshot`（以及 `to_h` / `history`）只反映**已提交**的状态，
   看不到任何未提交改动。
8. **变更历史**。`history(id)` 返回该 `id` 上**已提交**的变更序列（按提交顺序），
   每个元素是一个 Hash：
   - `{ op: :put, value: v }`，
   - `{ op: :link, to: t }`，
   - `{ op: :unlink, to: t }`（`link` / `unlink` 记在 `from` 一侧）。

   没有变更时（含未知 `id`）返回 `[]`。被回滚的改动**不出现在**历史里。
9. **并发事务隔离**。同一个 `Store` 可以被多个线程同时使用：4 个线程各自用事务写入
   互不相同的 `id`，全部结束后结果与串行写入**完全一致** —— 不许串数据、不许丢写、
   不许把异常记进 `errors`。实现需要 `Mutex` 之类的同步；判据是**结果**，不是时序。
10. **错误**。`get` 不存在的 `id` 返回 `nil`；`link(from, to)` / `unlink(from, to)` 的
    任一端点不存在时抛 `Snapgraph::NotFound`；事务块里 `raise` 导致回滚后，
    该异常对象必须出现在 `store.errors` 里（按发生顺序累积，返回数组）。
11. **确定性导出**。`to_h` 返回
    `{ "<id>" => { value: <对象>, links: [<目标 id>, ...] } }`：
    - 顶层键按 `id` 的**字符串序**升序排列；
    - 每个 `links` 数组也按目标 `id` 的**字符串序**升序排列；
    - `value` 就是 `put` 进去的原对象（同一引用）；
    - 同一图状态两次 `to_h` 逐字节一致（`Marshal.dump` 相同），
      且与 `put` / `link` 的调用顺序无关；空图为 `{}`。

    `Snapshot#to_h` 的形状与 `Store#to_h` 完全一致。

## API

```
Snapgraph::Store
  .new
  #put(id, obj)        -> obj
  #get(id)             -> obj | nil
  #link(from, to)      -> nil
  #unlink(from, to)    -> nil
  #snapshot            -> Snapgraph::Snapshot
  #restore(snapshot)   -> nil
  #transaction { ... } -> 块的返回值
  #history(id)         -> Array
  #to_h                -> Hash
  #errors              -> Array

Snapgraph::Snapshot        （只读视图，只有下面两个方法）
  #get(id)             -> obj | nil
  #to_h                -> Hash

Snapgraph::NotFound < Snapgraph::Error < StandardError
```

## 验收

`check/checker.rb` 是固定验收程序，**不要修改**。它按 6 组共 12 个场景检查上面的契约：

| 组 | 场景 | 对应契约 |
| --- | --- | --- |
| `store` | `S1_basic_put_get_link_unlink` | 1 |
| `store` | `S2_link_missing_endpoint_raises_not_found` | 10 |
| `store` | `S3_history_and_deterministic_export` | 8、11 |
| `snapshot` | `N1_reflects_state_at_creation` | 2 |
| `snapshot` | `N2_shares_leaf_objects` | 2 |
| `snapshot` | `N3_is_a_view_not_a_deep_copy` | 3 |
| `cycle` | `C1_cycle_snapshot_traverse_and_restore` | 4、5 |
| `restore` | `R1_discards_later_changes` | 5、8 |
| `restore` | `R2_is_idempotent_and_snapshot_stays_valid` | 5 |
| `tx` | `T1_rollback_on_error_records_exception` | 6、10 |
| `tx` | `T2_nested_scope_and_visibility` | 6、7 |
| `concurrency` | `X1_parallel_transactions_isolated_by_id` | 9 |

跑法：`ruby check/checker.rb` 退出码 0 表示 12/12 全过；`ruby -Ilib test/test_snapgraph.rb` 必须全绿。

判定是确定性的：没有墙钟、没有 `sleep`、没有随机源。唯一的例外是**看门狗**，它只用来
发现「卡死」（整体超时或线程 20 秒不结束），不参与任何正确性判定。

## 目录

```
.
├── README.md                本文件
├── .gitignore
├── lib/snapgraph.rb         加载入口
├── lib/snapgraph/errors.rb  异常类（勿改类名）
├── lib/snapgraph/store.rb   Store 与 Snapshot（当前为空壳）
├── test/test_snapgraph.rb   既有用例（12 个，勿改断言）
└── check/checker.rb         固定验收程序（勿改）
```
