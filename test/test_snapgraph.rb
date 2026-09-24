# frozen_string_literal: true

# 既有用例。
#
# 这 12 个用例断言的是 README「对外契约」里的语义，**断言本身是契约的一部分，不要修改**。
# 起点状态下 lib/snapgraph/ 全是空壳，Store.new 就会抛 NotImplementedError，
# 所以 12 个用例现在全部是 error —— 这是预期起点。
#
#   ruby -Ilib test/test_snapgraph.rb

lib = File.expand_path("../lib", __dir__)
$LOAD_PATH.unshift(lib) unless $LOAD_PATH.include?(lib)

require "minitest/autorun"
require "snapgraph"

class TestSnapgraph < Minitest::Test
  def store
    Snapgraph::Store.new
  end

  # 契约 1、10：新库为空；get 未知 id 返回 nil；history 未知 id 返回 []
  def test_01_new_store_is_empty
    st = store
    assert_nil st.get("missing")
    assert_equal({}, st.to_h)
    assert_equal [], st.history("missing")
    assert_equal [], st.errors
  end

  # 契约 1：put 覆盖并返回 obj；get 返回同一个对象引用；link/unlink 幂等
  def test_02_put_overwrites_and_returns_value
    st = store
    a = "A".dup
    assert_same a, st.put("n1", a)
    assert_same a, st.get("n1")

    b = { k: 1 }
    st.put("n1", b)
    assert_same b, st.get("n1")

    st.put("n2", "B")
    st.link("n1", "n2")
    assert_equal ["n2"], st.to_h["n1"][:links]
    st.link("n1", "n2")
    assert_equal ["n2"], st.to_h["n1"][:links]

    st.unlink("n1", "n2")
    assert_equal [], st.to_h["n1"][:links]
    st.unlink("n1", "n2")
    assert_equal [], st.to_h["n1"][:links]
  end

  # 契约 10：link / unlink 端点不存在时抛 NotFound
  def test_03_link_requires_existing_endpoints
    st = store
    st.put("a", 1)
    assert_raises(Snapgraph::NotFound) { st.link("a", "ghost") }
    assert_raises(Snapgraph::NotFound) { st.link("ghost", "a") }
    assert_raises(Snapgraph::NotFound) { st.unlink("a", "ghost") }
    assert_equal [], st.to_h["a"][:links], "失败的 link 不该留下边"
  end

  # 契约 2：快照冻结生成时刻；浅拷贝共享叶子引用；快照是只读视图
  def test_04_snapshot_freezes_creation_time
    st = store
    v0 = "v0".dup
    st.put("a", v0)
    st.put("b", "B")
    st.link("a", "b")

    snap = st.snapshot
    st.put("a", "v1")
    st.put("c", "C")
    st.unlink("a", "b")

    assert_same v0, snap.get("a"), "快照里的值与生成时刻是同一引用"
    assert_nil snap.get("c"), "快照看不到生成之后新增的节点"
    assert_equal ["b"], snap.to_h["a"][:links], "快照冻结生成时刻的边"
    assert_nil snap.get("ghost")
    refute_respond_to snap, :put, "快照是只读视图"
    refute_respond_to snap, :link, "快照是只读视图"
  end

  # 契约 4：带环的图能正常快照与遍历（不许栈溢出 / 死循环）
  def test_05_cycle_snapshot_and_traverse
    st = store
    st.put("a", 1)
    st.put("b", 2)
    st.put("c", 3)
    st.link("a", "b")
    st.link("b", "c")
    st.link("c", "a")

    h = st.snapshot.to_h
    assert_equal %w[a b c], h.keys
    assert_equal ["b"], h["a"][:links]
    assert_equal ["c"], h["b"][:links]
    assert_equal ["a"], h["c"][:links]
  end

  # 契约 5：restore 丢弃之后的改动（含历史）
  def test_06_restore_discards_later_changes
    st = store
    st.put("a", 1)
    st.put("b", 2)
    st.link("a", "b")
    hist = st.history("a").dup

    snap = st.snapshot
    st.put("a", 99)
    st.put("c", 3)
    st.unlink("a", "b")
    st.restore(snap)

    assert_equal 1, st.get("a")
    assert_equal 2, st.get("b")
    assert_nil st.get("c")
    assert_equal ["b"], st.to_h["a"][:links]
    assert_equal hist, st.history("a")
    assert_equal snap.to_h, st.to_h
  end

  # 契约 5：同一快照可反复 restore（幂等）
  def test_07_restore_is_idempotent
    st = store
    st.put("a", 1)
    snap = st.snapshot
    st.put("a", 2)

    st.restore(snap)
    first = st.to_h
    st.restore(snap)
    assert_equal first, st.to_h

    st.put("a", 3)
    assert_equal 3, st.get("a")
    st.restore(snap)
    assert_equal 1, st.get("a")
    assert_equal 1, snap.get("a"), "restore 不该改动快照自身"
  end

  # 契约 6、10：事务抛异常整体回滚，异常继续抛出并记入 errors
  def test_08_transaction_rolls_back_on_raise
    st = store
    st.put("a", 1)
    boom = RuntimeError.new("boom")

    raised = assert_raises(RuntimeError) do
      st.transaction do
        st.put("a", 2)
        st.put("b", 3)
        raise boom
      end
    end

    assert_same boom, raised, "事务把原异常继续向外抛出"
    assert_equal 1, st.get("a")
    assert_nil st.get("b")
    assert_includes st.errors, boom
  end

  # 契约 6：嵌套事务，内层回滚只回滚内层
  def test_09_nested_transaction_inner_rollback_is_scoped
    st = store
    st.transaction do
      st.put("outer", 1)
      assert_raises(RuntimeError) do
        st.transaction do
          st.put("inner", 2)
          raise "inner boom"
        end
      end
      assert_nil st.get("inner")
      assert_equal 1, st.get("outer")
    end

    assert_equal 1, st.get("outer")
    assert_nil st.get("inner")
  end

  # 契约 7：事务未提交时 snapshot 看不到未提交改动，但事务自己能看到
  def test_10_snapshot_in_uncommitted_transaction_sees_committed_only
    st = store
    st.put("base", 0)

    st.transaction do
      st.put("base", 1)
      st.put("pending", 2)
      assert_equal 1, st.get("base"), "事务内读己之写"
      assert_equal 2, st.get("pending"), "事务内读己之写"

      snap = st.snapshot
      assert_equal 0, snap.get("base"), "未提交快照只反映已提交状态"
      assert_nil snap.get("pending"), "未提交快照看不到未提交节点"
    end

    assert_equal 1, st.get("base")
    assert_equal 2, st.get("pending")
  end

  # 契约 8：history 按提交序记录，回滚不进历史
  def test_11_history_records_committed_changes_in_order
    st = store
    st.put("b", "B")
    st.put("a", 1)
    st.put("a", 2)
    st.link("a", "b")
    st.unlink("a", "b")

    assert_equal [
      { op: :put, value: 1 },
      { op: :put, value: 2 },
      { op: :link, to: "b" },
      { op: :unlink, to: "b" },
    ], st.history("a")
    assert_equal [], st.history("nope")

    assert_raises(RuntimeError) do
      st.transaction do
        st.put("a", 99)
        raise "rollback"
      end
    end
    assert_equal 4, st.history("a").length, "回滚的改动不进历史"
  end

  # 契约 11：to_h 按 id 字符串序确定性导出
  def test_12_to_h_is_deterministic_and_sorted
    x = store
    x.put("c", 3)
    x.put("a", 1)
    x.put("b", 2)
    x.link("c", "a")
    x.link("c", "b")

    y = store
    y.put("a", 1)
    y.put("b", 2)
    y.put("c", 3)
    y.link("c", "b")
    y.link("c", "a")

    assert_equal %w[a b c], x.to_h.keys
    assert_equal %w[a b], x.to_h["c"][:links]
    assert_equal Marshal.dump(x.to_h), Marshal.dump(y.to_h), "两次导出逐字节一致"
    assert_equal Marshal.dump(x.to_h), Marshal.dump(x.to_h)
  end
end
