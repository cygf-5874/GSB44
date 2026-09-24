# frozen_string_literal: true

# check/checker.rb —— snapgraph 的固定验收程序。
#
# ⚠️ 不要修改本文件。它按 README「对外契约」判定实现是否达标；
#    改它只会让判定失效，不会让实现变对。
#
# 用法：
#
#   ruby check/checker.rb                     # 跑全部 12 个场景
#   ruby check/checker.rb -list               # 列出全部场景
#   ruby check/checker.rb --only store        # 只跑一组
#
# 每个场景都被逐个兜住异常，失败不早退（一次把问题全暴露）。
# 另有全局看门狗线程兜「挂死」；看门狗只用于发现卡死，不参与任何正确性判定。

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "snapgraph"

WATCHDOG_SECONDS = 180
GROUPS = %w[store snapshot cycle restore tx concurrency].freeze
SCENARIOS = []

# 场景判据不满足时抛这个。
class ScenarioError < StandardError; end

# 注册一个场景：check(group, name) { ... }
def check(group, name, &block)
  SCENARIOS << [group, name, block]
end

def eq(expect, actual, what)
  return if expect == actual

  raise ScenarioError, "#{what}：期望=#{expect.inspect} 实际=#{actual.inspect}"
end

def same(expect, actual, what)
  return if expect.equal?(actual)

  raise ScenarioError, "#{what}：期望=同一对象 实际=不同对象"
end

def expect_raises(klass, what)
  begin
    yield
  rescue klass
    return nil
  rescue StandardError => e
    raise ScenarioError, "#{what}：期望=抛 #{klass} 实际=抛 #{e.class}: #{e.message}"
  end
  # 没抛异常才走到这里（ScriptError 一类不在此处兜，交给场景级兜底）。
  raise ScenarioError, "#{what}：期望=抛 #{klass} 实际=未抛异常"
end

def usage
  puts "用法：ruby check/checker.rb [-list] [--only <组名>]"
  puts "分组：#{GROUPS.join(' / ')}"
end

# ------------------------------------------------------------------ 场景

check("store", "S1_basic_put_get_link_unlink") do
  st = Snapgraph::Store.new
  eq({}, st.to_h, "新库 to_h")
  eq(nil, st.get("missing"), "get 未知 id")

  a = "A".dup
  same(a, st.put("n1", a), "put 返回 obj 本身")
  same(a, st.get("n1"), "get 返回同一对象")

  b = { k: 1 }
  st.put("n1", b)
  same(b, st.get("n1"), "重复 put 覆盖")

  st.put("n2", "B")
  st.link("n1", "n2")
  eq(["n2"], st.to_h["n1"][:links], "link 后的出边")
  st.link("n1", "n2")
  eq(["n2"], st.to_h["n1"][:links], "重复 link 幂等")
  st.unlink("n1", "n2")
  eq([], st.to_h["n1"][:links], "unlink 后的出边")
  st.unlink("n1", "n2")
  eq([], st.to_h["n1"][:links], "重复 unlink 幂等")
end

check("store", "S2_link_missing_endpoint_raises_not_found") do
  st = Snapgraph::Store.new
  st.put("a", 1)

  expect_raises(Snapgraph::NotFound, "link(a, 未知)") { st.link("a", "ghost") }
  expect_raises(Snapgraph::NotFound, "link(未知, a)") { st.link("ghost", "a") }
  expect_raises(Snapgraph::NotFound, "unlink(a, 未知)") { st.unlink("a", "ghost") }
  expect_raises(Snapgraph::NotFound, "unlink(未知, a)") { st.unlink("ghost", "a") }

  eq([], st.to_h["a"][:links], "失败的 link 不留边")
  eq(nil, st.get("ghost"), "未知 id 仍为 nil")
end

check("store", "S3_history_and_deterministic_export") do
  st = Snapgraph::Store.new
  st.put("b", "B")
  st.put("a", 1)
  st.put("a", 2)
  st.link("a", "b")
  st.unlink("a", "b")

  eq([{ op: :put, value: 1 }, { op: :put, value: 2 },
      { op: :link, to: "b" }, { op: :unlink, to: "b" }],
     st.history("a"), "history(a) 的提交序")
  eq([], st.history("nope"), "未知 id 的 history")

  expect_raises(RuntimeError, "事务内 raise") do
    st.transaction do
      st.put("a", 99)
      raise "boom"
    end
  end
  eq(4, st.history("a").length, "回滚的改动不进历史")

  x = Snapgraph::Store.new
  x.put("c", 3)
  x.put("a", 1)
  x.put("b", 2)
  x.link("c", "a")
  x.link("c", "b")

  y = Snapgraph::Store.new
  y.put("a", 1)
  y.put("b", 2)
  y.put("c", 3)
  y.link("c", "b")
  y.link("c", "a")

  eq(%w[a b c], x.to_h.keys, "to_h 顶层键按 id 字符串序")
  eq(%w[a b], x.to_h["c"][:links], "links 按 id 字符串序")
  eq(Marshal.dump(x.to_h), Marshal.dump(y.to_h), "插入顺序不同、导出逐字节一致")
  eq(Marshal.dump(x.to_h), Marshal.dump(x.to_h), "同一图重复导出逐字节一致")
end

check("snapshot", "N1_reflects_state_at_creation") do
  st = Snapgraph::Store.new
  v0 = "v0".dup
  st.put("a", v0)
  st.put("b", "B")
  st.link("a", "b")

  snap = st.snapshot

  st.put("a", "v1")
  st.unlink("a", "b")
  st.put("c", "C")

  same(v0, snap.get("a"), "快照 get 与生成时刻一致")
  eq(nil, snap.get("c"), "快照看不到新节点")
  eq(["b"], snap.to_h["a"][:links], "快照冻结生成时刻的边")
  eq(nil, snap.get("ghost"), "快照 get 未知 id 返回 nil")

  eq("v1", st.get("a"), "原图按预期已改")
  eq([], st.to_h["a"][:links], "原图的边按预期已删")

  raise ScenarioError, "快照不该有 put（只读视图）" if snap.respond_to?(:put)
  raise ScenarioError, "快照不该有 link（只读视图）" if snap.respond_to?(:link)
  raise ScenarioError, "快照不该有 unlink（只读视图）" if snap.respond_to?(:unlink)
end

check("snapshot", "N2_shares_leaf_objects") do
  st = Snapgraph::Store.new
  objs = {}
  %w[a b c].each do |k|
    objs[k] = { name: k }
    st.put(k, objs[k])
  end

  snap = st.snapshot
  %w[a b c].each do |k|
    same(objs[k], snap.get(k), "snap.get(#{k}) 是原对象的同一引用")
    same(st.get(k), snap.get(k), "snap 与 store 共享同一叶子")
  end
end

check("snapshot", "N3_is_a_view_not_a_deep_copy") do
  n = 1000
  st = Snapgraph::Store.new
  values = Array.new(n) { |i| { idx: i } }
  ids = Array.new(n) { |i| "id#{i}" }
  snaps = Array.new(n)

  GC.start
  GC.start
  before_objects = ObjectSpace.count_objects[:TOTAL]
  before_alloc = GC.stat(:total_allocated_objects)

  n.times do |i|
    st.put(ids[i], values[i])
    snaps[i] = st.snapshot
  end

  GC.start
  GC.start
  after_objects = ObjectSpace.count_objects[:TOTAL]
  after_alloc = GC.stat(:total_allocated_objects)

  growth = after_objects - before_objects
  limit = n + n * 16 + 20_000
  if growth > limit
    raise ScenarioError,
          "活跃对象增量：期望 <= #{limit}（唯一对象数 + 快照数 × 16 + 20000，按本机标定）" \
          " 实际=#{growth}"
  end

  alloc = after_alloc - before_alloc
  alloc_limit = 500_000
  if alloc > alloc_limit
    raise ScenarioError,
          "对象分配量：期望 <= #{alloc_limit}（1000 次 put + 1000 次 snapshot，" \
          "整体深拷贝会到这里量级）实际=#{alloc}"
  end

  same(values[0], snaps[0].get("id0"), "首个快照仍然正确")
  eq(nil, snaps[0].get("id#{n - 1}"), "首个快照看不到之后的节点")
  same(values[n - 1], snaps[n - 1].get("id#{n - 1}"), "末个快照仍然正确")
  eq(n, st.to_h.size, "节点总数")
end

check("cycle", "C1_cycle_snapshot_traverse_and_restore") do
  st = Snapgraph::Store.new
  %w[a b c].each_with_index { |k, i| st.put(k, i) }
  st.link("a", "b")
  st.link("b", "c")
  st.link("c", "a")

  snap = st.snapshot
  h = snap.to_h
  eq(%w[a b c], h.keys, "顶层键序")
  eq(["b"], h["a"][:links], "a 的出边")
  eq(["c"], h["b"][:links], "b 的出边")
  eq(["a"], h["c"][:links], "c 的出边")

  st.put("s", "S")
  st.link("s", "s")
  eq(["s"], st.snapshot.to_h["s"][:links], "自环")

  st.put("a", 42)
  st.restore(snap)
  eq(0, st.get("a"), "restore 恢复环上的值")
  eq(["b"], st.to_h["a"][:links], "restore 恢复环上的边")
  eq(nil, st.get("s"), "restore 丢弃快照之后的自环节点")
end

check("restore", "R1_discards_later_changes") do
  st = Snapgraph::Store.new
  st.put("a", 1)
  st.put("b", 2)
  st.link("a", "b")
  hist_before = st.history("a").dup

  snap = st.snapshot

  st.put("a", 99)
  st.put("c", 3)
  st.unlink("a", "b")
  st.link("b", "a")

  st.restore(snap)

  eq(1, st.get("a"), "恢复节点值")
  eq(2, st.get("b"), "恢复节点值")
  eq(nil, st.get("c"), "丢弃快照之后新增的节点")
  eq(["b"], st.to_h["a"][:links], "恢复边")
  eq([], st.to_h["b"][:links], "丢弃快照之后新增的边")
  eq(hist_before, st.history("a"), "历史回到快照时刻")
  eq(snap.to_h, st.to_h, "restore 后与快照一致")
end

check("restore", "R2_is_idempotent_and_snapshot_stays_valid") do
  st = Snapgraph::Store.new
  st.put("a", 1)
  snap = st.snapshot
  st.put("a", 2)

  st.restore(snap)
  first = st.to_h
  st.restore(snap)
  eq(first, st.to_h, "重复 restore 幂等")

  st.put("a", 3)
  eq(3, st.get("a"), "restore 之后仍可继续改")
  st.restore(snap)
  eq(1, st.get("a"), "同一快照可以再次 restore")

  st.restore(snap)
  eq(1, snap.get("a"), "restore 不改动快照自身")
end

check("tx", "T1_rollback_on_error_records_exception") do
  st = Snapgraph::Store.new
  st.put("a", 1)
  boom = RuntimeError.new("boom")
  got = nil

  begin
    st.transaction do
      st.put("a", 2)
      st.put("b", 3)
      raise boom
    end
  rescue RuntimeError => e
    got = e
  end

  same(boom, got, "原异常被继续抛出")
  eq(1, st.get("a"), "put 被回滚")
  eq(nil, st.get("b"), "新增节点被回滚")
  eq(1, st.errors.length, "errors 长度")
  same(boom, st.errors.first, "errors 记录该异常对象")

  st.transaction { st.put("c", 3) }
  eq(3, st.get("c"), "成功事务生效")
  eq(1, st.errors.length, "成功事务不追加 errors")
end

check("tx", "T2_nested_scope_and_visibility") do
  st = Snapgraph::Store.new
  st.put("base", 0)

  st.transaction do
    st.put("base", 1)
    st.put("outer", 10)

    eq(1, st.get("base"), "事务内读己之写 base")
    eq(10, st.get("outer"), "事务内读己之写 outer")

    snap_inside = st.snapshot
    eq(0, snap_inside.get("base"), "未提交快照只看已提交 base")
    eq(nil, snap_inside.get("outer"), "未提交快照看不到 outer")

    expect_raises(RuntimeError, "内层事务抛异常") do
      st.transaction do
        st.put("inner", 20)
        st.put("base", 2)
        raise "inner boom"
      end
    end

    eq(nil, st.get("inner"), "内层回滚丢弃 inner")
    eq(1, st.get("base"), "内层回滚不影响外层对 base 的改动")
    eq(10, st.get("outer"), "外层改动仍在")

    st.put("after", 30)
  end

  eq(1, st.get("base"), "外层提交 base")
  eq(10, st.get("outer"), "外层提交 outer")
  eq(30, st.get("after"), "外层提交 after")
  eq(nil, st.get("inner"), "内层始终未提交")
  eq(1, st.errors.length, "内层异常被记录")
end

check("concurrency", "X1_parallel_transactions_isolated_by_id") do
  st = Snapgraph::Store.new
  st.put("root", "R")

  nthreads = 4
  per = 100

  workers = (0...nthreads).map do |t|
    Thread.new do
      per.times do |i|
        st.transaction do
          id = "n_#{t}_#{i}"
          st.put(id, "#{t}:#{i}")
          st.link("root", id)
        end
      end
    end
  end

  workers.each do |w|
    raise ScenarioError, "线程 20 秒内未结束（疑似死锁）" if w.join(20).nil?
  end

  eq(nthreads * per, st.to_h.size - 1, "节点总数")
  nthreads.times do |t|
    per.times do |i|
      eq("#{t}:#{i}", st.get("n_#{t}_#{i}"), "并发写入 n_#{t}_#{i}")
    end
  end

  links = st.to_h["root"][:links]
  eq(nthreads * per, links.length, "root 的出边数")
  eq(links.sort, links, "root 的出边已按 id 字符串序")
  eq([], st.errors, "并发过程没有错误")
end

# ------------------------------------------------------------------ 入口

list = false
only = nil
args = ARGV.dup
until args.empty?
  a = args.shift
  case a
  when "-list", "--list"
    list = true
  when "--only"
    only = args.shift
    if only.nil?
      warn "--only 需要一个组名"
      exit 2
    end
  when "-h", "--help"
    usage
    exit 0
  else
    if a.start_with?("--only=")
      only = a.sub("--only=", "")
    else
      warn "未知参数 #{a}"
      usage
      exit 2
    end
  end
end

if list
  SCENARIOS.each { |(group, name, _)| puts format("%-12s %s", group, name) }
  exit 0
end

if only && !GROUPS.include?(only)
  warn "未知分组 #{only}（可选：#{GROUPS.join(' / ')}）"
  exit 2
end

Thread.new do
  sleep WATCHDOG_SECONDS
  warn "看门狗：checker 整体运行超过 #{WATCHDOG_SECONDS} 秒仍未结束，判定为挂死"
  Process.exit!(3)
end

passed = 0
total = 0

SCENARIOS.each do |(group, name, block)|
  next if only && group != only

  total += 1
  begin
    block.call
    passed += 1
    puts "PASS #{group}/#{name}"
  rescue ScenarioError => e
    puts "FAIL #{group}/#{name}  #{e.message}"
  rescue Exception => e # rubocop:disable Lint/RescueException
    # 起点状态下空壳抛的是 NotImplementedError（ScriptError），不属于 StandardError，
    # 所以这里要兜住 Exception，才能做到「失败不早退」。
    raise if e.is_a?(SystemExit) || e.is_a?(SignalException) || e.is_a?(NoMemoryError)

    puts "FAIL #{group}/#{name}  期望=场景正常结束 实际=#{e.class}: #{e.message}"
  end
end

puts
puts "结果：通过 #{passed}/#{total}"
exit(passed == total && total.positive? ? 0 : 1)
