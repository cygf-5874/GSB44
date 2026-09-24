# frozen_string_literal: true

module Snapgraph
  # snapgraph 的异常基类。
  class Error < StandardError; end

  # 端点不存在：`link` / `unlink` 的 from 或 to 没有对应节点。
  class NotFound < Error; end
end
