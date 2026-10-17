#!/usr/bin/env python3
"""smoke test: 验证 ccs.py 各函数在无 TTY 环境下不崩溃."""
import sys

sys.path.insert(0, ".")
import ccs

providers = ccs.load_providers("claude")
assert providers, "should load claude providers"
print(f"providers: {len(providers)}")
assert any(p["name"] for p in providers)

# 降级选择器在管道输入下应返回 None 或有效名称
import io
sys.stdin = io.StringIO("\n")
name = ccs.pick_simple(providers)
print(f"pick_simple result: {name!r}")
assert name is None or any(p["name"] == name for p in providers)

print("OK")
