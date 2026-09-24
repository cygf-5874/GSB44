# frozen_string_literal: true

require_relative "errors"

module Snapgraph
  # 事务化对象图快照的入口：一张「id -> 对象」的图 + `from -> to` 有向边，
  # 外加写时复制快照、restore、嵌套事务、变更历史与确定性导出。
  #
  # 语义细节全部在 README 的「对外契约」一节。
  #
  # 本文件当前是**空壳**：每个方法体只抛 NotImplementedError，公开方法签名
  # 已经是最终形态，请不要改动签名与返回约定。
  class Store
    def initialize
      raise NotImplementedError, "Snapgraph::Store#initialize 尚未实现"
    end

    # 写入或覆盖节点值，返回 obj。
    def put(id, obj)
      raise NotImplementedError, "Snapgraph::Store#put 尚未实现"
    end

    # 读取节点值，不存在返回 nil。
    def get(id)
      raise NotImplementedError, "Snapgraph::Store#get 尚未实现"
    end

    # 建立一条 from -> to 的有向边，返回 nil。
    def link(from, to)
      raise NotImplementedError, "Snapgraph::Store#link 尚未实现"
    end

    # 删除一条 from -> to 的有向边，返回 nil。
    def unlink(from, to)
      raise NotImplementedError, "Snapgraph::Store#unlink 尚未实现"
    end

    # 取一个只读快照视图。
    def snapshot
      raise NotImplementedError, "Snapgraph::Store#snapshot 尚未实现"
    end

    # 把图恢复到某个快照，返回 nil。
    def restore(snapshot)
      raise NotImplementedError, "Snapgraph::Store#restore 尚未实现"
    end

    # 事务：块正常返回则提交，块抛异常则回滚并把异常继续抛出。
    def transaction(&block)
      raise NotImplementedError, "Snapgraph::Store#transaction 尚未实现"
    end

    # 某个 id 上已提交的变更序列。
    def history(id)
      raise NotImplementedError, "Snapgraph::Store#history 尚未实现"
    end

    # 按 id 字符串序确定性导出整张图。
    def to_h
      raise NotImplementedError, "Snapgraph::Store#to_h 尚未实现"
    end

    # 事务里被回滚的异常列表（按发生顺序）。
    def errors
      raise NotImplementedError, "Snapgraph::Store#errors 尚未实现"
    end
  end

  # 只读快照视图：只暴露 get / to_h，不含任何写入方法。
  class Snapshot
    def get(id)
      raise NotImplementedError, "Snapgraph::Snapshot#get 尚未实现"
    end

    def to_h
      raise NotImplementedError, "Snapgraph::Snapshot#to_h 尚未实现"
    end
  end
end
