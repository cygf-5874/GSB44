# frozen_string_literal: true

require "monitor"
require_relative "errors"

module Snapgraph
  # 事务化对象图快照的入口：一张「id -> 对象」的图 + `from -> to` 有向边，
  # 外加写时复制快照、restore、嵌套事务、变更历史与确定性导出。
  #
  # 实现要点：
  # - 已提交状态是三个哈希：@nodes（id -> 值）、@links（id -> [目标 id]）、
  #   @history（id -> [变更条目]）。这些哈希以及里面的数组**永不在原地修改**，
  #   每次写入都先整体替换引用（写时复制），因此快照只需抓住三个引用，
  #   就是 O(1) 的结构性共享视图，而非全量拷贝。
  # - 事务帧（Frame）从父状态引用出发，帧内写入同样走写时复制；
  #   提交时把帧状态交给父层，回滚时直接丢弃整帧。
  # - 历史只在提交时追加：帧内变更先攒在 pending 里，提交才并入 @history，
  #   回滚自然不进历史。
  # - 所有公开方法都在可重入的 Monitor 下串行化，事务期间锁不释放，
  #   多线程事务因此等价于某种串行顺序。
  class Store
    # 单个事务帧：nodes / links 从父层引用出发（写时复制），
    # pending 是本帧已做、尚未提交的历史条目（[id, entry] 对）。
    Frame = Struct.new(:nodes, :links, :pending)

    def initialize
      @lock = Monitor.new
      @nodes = {}    # 已提交：id -> 值
      @links = {}    # 已提交：id -> [目标 id]（去重，导出时排序）
      @history = {}  # 已提交：id -> [{ op: ..., ... }]
      @frames = []   # 事务帧栈（嵌套事务）
      @errors = []   # 回滚事务的异常，按发生顺序
    end

    # 写入或覆盖节点值，返回 obj。
    def put(id, obj)
      @lock.synchronize do
        write_nodes { |nodes| nodes[id] = obj }
        record(id, { op: :put, value: obj })
        obj
      end
    end

    # 读取节点值，不存在返回 nil。事务内读己之写。
    def get(id)
      @lock.synchronize { current_nodes[id] }
    end

    # 建立一条 from -> to 的有向边，返回 nil；重复 link 幂等。
    def link(from, to)
      @lock.synchronize do
        check_endpoints!(from, to)
        existing = current_links[from] || []
        unless existing.include?(to)
          write_links { |links| links[from] = existing + [to] }
          record(from, { op: :link, to: to })
        end
        nil
      end
    end

    # 删除一条 from -> to 的有向边，返回 nil；边不存在时幂等。
    def unlink(from, to)
      @lock.synchronize do
        check_endpoints!(from, to)
        existing = current_links[from] || []
        if existing.include?(to)
          write_links { |links| links[from] = existing - [to] }
          record(from, { op: :unlink, to: to })
        end
        nil
      end
    end

    # 取一个只读快照视图：只抓住已提交状态的三个引用，O(1)。
    # 事务内调用时只看到已提交状态（契约 7）。
    def snapshot
      @lock.synchronize { Snapshot.new(@nodes, @links, @history) }
    end

    # 把图恢复到某个快照：节点、边、历史都退回那一刻，返回 nil。
    # 快照自身不变，可以反复 restore。
    def restore(snapshot)
      @lock.synchronize do
        unless snapshot.is_a?(Snapshot)
          raise ArgumentError, "restore 需要 Snapgraph::Snapshot"
        end

        nodes, links, history = snapshot.__send__(:committed_state)
        @nodes = nodes
        @links = links
        @history = history
        # 进行中的事务帧一并回到恢复后的状态（其未提交改动随之丢弃）。
        @frames.each do |frame|
          frame.nodes = @nodes
          frame.links = @links
          frame.pending.clear
        end
        nil
      end
    end

    # 事务：块正常返回则提交，块抛异常则回滚并把同一异常继续抛出。
    # 支持嵌套：内层回滚只丢弃内层帧。
    def transaction
      @lock.synchronize do
        frame = Frame.new(current_nodes, current_links, [])
        @frames.push(frame)
        begin
          result = yield
        rescue Exception => e # rubocop:disable Lint/RescueException
          @frames.pop
          @errors << e
          raise
        end
        @frames.pop
        if @frames.empty?
          @nodes = frame.nodes
          @links = frame.links
          apply_pending(frame.pending)
        else
          parent = @frames.last
          parent.nodes = frame.nodes
          parent.links = frame.links
          parent.pending.concat(frame.pending)
        end
        result
      end
    end

    # 某个 id 上已提交的变更序列（按提交顺序）；未知 id 返回 []。
    def history(id)
      @lock.synchronize { (@history[id] || []).dup }
    end

    # 按 id 字符串序确定性导出整张图（只反映已提交状态）。
    def to_h
      @lock.synchronize { Store.export(@nodes, @links) }
    end

    # 事务里被回滚的异常列表（按发生顺序）。
    def errors
      @lock.synchronize { @errors.dup }
    end

    # 确定性导出：顶层键与 links 都按 id 字符串序升序。
    # 不递归遍历图，含环与自环都安全。
    def self.export(nodes, links)
      result = {}
      nodes.keys.sort.each do |id|
        result[id] = { value: nodes[id], links: (links[id] || []).sort }
      end
      result
    end

    private

    def in_transaction?
      !@frames.empty?
    end

    def current_nodes
      in_transaction? ? @frames.last.nodes : @nodes
    end

    def current_links
      in_transaction? ? @frames.last.links : @links
    end

    # 写时复制地修改 nodes：复制当前哈希，交给块改，再替换引用。
    def write_nodes
      nodes = current_nodes.dup
      yield nodes
      if in_transaction?
        @frames.last.nodes = nodes
      else
        @nodes = nodes
      end
    end

    def write_links
      links = current_links.dup
      yield links
      if in_transaction?
        @frames.last.links = links
      else
        @links = links
      end
    end

    # 记录一条变更：事务内先攒在帧的 pending，事务外直接提交进历史。
    def record(id, entry)
      if in_transaction?
        @frames.last.pending << [id, entry]
      else
        apply_pending([[id, entry]])
      end
    end

    # 把待提交的历史条目并入已提交历史（写时复制，数组不在原地改）。
    def apply_pending(pending)
      return if pending.empty?

      history = @history.dup
      pending.each do |id, entry|
        history[id] = (history[id] || []) + [entry]
      end
      @history = history
    end

    def check_endpoints!(from, to)
      nodes = current_nodes
      raise NotFound, "link/unlink 的 from 端点不存在：#{from.inspect}" unless nodes.key?(from)
      raise NotFound, "link/unlink 的 to 端点不存在：#{to.inspect}" unless nodes.key?(to)
    end
  end

  # 只读快照视图：只暴露 get / to_h，不含任何写入方法。
  # 内部只是对已提交状态三个哈希的引用（结构性共享），不是拷贝。
  class Snapshot
    def initialize(nodes, links, history)
      @nodes = nodes
      @links = links
      @history = history
    end

    def get(id)
      @nodes[id]
    end

    def to_h
      Store.export(@nodes, @links)
    end

    protected

    # 供 Store#restore 取回快照时刻的完整已提交状态（含历史）。
    def committed_state
      [@nodes, @links, @history]
    end
  end
end
