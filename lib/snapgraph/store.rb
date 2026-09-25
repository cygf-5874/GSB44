# frozen_string_literal: true

require_relative "errors"
require "monitor"

module Snapgraph
  # 不可变的图状态：nodes / edges / history 三个 Hash 全部按写时复制更新，
  # 快照只需持有某个 State 的引用即可冻结那一刻的图（结构性共享，而非深拷贝）。
  #
  # - nodes:   { id => 对象 }
  # - edges:   { from => { to => true } }
  # - history: { id => [{ op: :put, value: v } / { op: :link|:unlink, to: t }, ...] }
  class State
    attr_reader :nodes, :edges, :history

    def initialize(nodes, edges, history)
      @nodes = nodes
      @edges = edges
      @history = history
    end

    def self.empty
      new({}, {}, {})
    end

    def put(id, obj)
      State.new(
        @nodes.merge(id => obj),
        @edges,
        append_history(id, { op: :put, value: obj })
      )
    end

    def link(from, to)
      ensure_endpoint!(from)
      ensure_endpoint!(to)
      targets = @edges[from] || {}
      return self if targets.key?(to)

      State.new(
        @nodes,
        @edges.merge(from => targets.merge(to => true)),
        append_history(from, { op: :link, to: to })
      )
    end

    def unlink(from, to)
      ensure_endpoint!(from)
      ensure_endpoint!(to)
      targets = @edges[from] || {}
      return self unless targets.key?(to)

      State.new(
        @nodes,
        @edges.merge(from => targets.reject { |k, _| k == to }),
        append_history(from, { op: :unlink, to: to })
      )
    end

    # 确定性导出：顶层键与 links 都按 id 字符串序排列。
    def to_h
      result = {}
      @nodes.keys.sort.each do |id|
        targets = @edges[id]
        result[id] = { value: @nodes[id], links: targets ? targets.keys.sort : [] }
      end
      result
    end

    private

    def ensure_endpoint!(id)
      raise NotFound, "未知节点：#{id.inspect}" unless @nodes.key?(id)
    end

    def append_history(id, entry)
      list = @history[id]
      @history.merge(id => (list ? list + [entry] : [entry]))
    end
  end

  # 事务化对象图快照的入口：一张「id -> 对象」的图 + `from -> to` 有向边，
  # 外加写时复制快照、restore、嵌套事务、变更历史与确定性导出。
  #
  # 语义细节全部在 README 的「对外契约」一节。
  class Store
    def initialize
      @committed = State.empty
      @working = nil # 事务栈最内层的工作状态；不在事务中时为 nil
      @errors = []
      @lock = Monitor.new # 可重入，事务块内的读写共用同一把锁
    end

    # 写入或覆盖节点值，返回 obj。
    def put(id, obj)
      @lock.synchronize { apply { |st| st.put(id, obj) } }
      obj
    end

    # 读取节点值，不存在返回 nil。事务内可见本事务的改动（读己之写）。
    def get(id)
      @lock.synchronize { current_state.nodes[id] }
    end

    # 建立一条 from -> to 的有向边，返回 nil；重复 link 幂等。
    def link(from, to)
      @lock.synchronize { apply { |st| st.link(from, to) } }
      nil
    end

    # 删除一条 from -> to 的有向边，返回 nil；边不存在时幂等。
    def unlink(from, to)
      @lock.synchronize { apply { |st| st.unlink(from, to) } }
      nil
    end

    # 取一个只读快照视图：冻结**已提交**状态（事务内也看不到未提交改动）。
    def snapshot
      @lock.synchronize { Snapshot.new(@committed) }
    end

    # 把图恢复到某个快照，返回 nil；同一快照可反复 restore，快照自身不变。
    def restore(snapshot)
      @lock.synchronize { replace_state(snapshot.__send__(:state)) }
      nil
    end

    # 事务：块正常返回则提交，块抛异常则回滚、记录异常并继续向外抛出。
    # 支持嵌套：内层回滚只丢弃内层改动，内层成功则并入外层。
    def transaction
      @lock.synchronize do
        previous = @working
        @working = previous || @committed
        begin
          result = yield
        rescue Exception => e # rubocop:disable Lint/RescueException
          @errors << e
          @working = previous
          raise
        end
        if previous.nil?
          @committed = @working
          @working = nil
        end
        result
      end
    end

    # 某个 id 上已提交的变更序列（不含未提交与已回滚的改动）。
    def history(id)
      @lock.synchronize { (@committed.history[id] || []).dup }
    end

    # 按 id 字符串序确定性导出整张图（只反映已提交状态）。
    def to_h
      @lock.synchronize { @committed.to_h }
    end

    # 事务里被回滚的异常列表（按发生顺序）。
    def errors
      @lock.synchronize { @errors.dup }
    end

    private

    def current_state
      @working || @committed
    end

    def apply
      replace_state(yield(current_state))
    end

    def replace_state(state)
      if @working
        @working = state
      else
        @committed = state
      end
    end
  end

  # 只读快照视图：只暴露 get / to_h，不含任何写入方法。
  class Snapshot
    def initialize(state)
      @state = state
    end

    def get(id)
      @state.nodes[id]
    end

    def to_h
      @state.to_h
    end

    private

    attr_reader :state
  end
end
