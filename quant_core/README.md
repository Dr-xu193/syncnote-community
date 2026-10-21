# SyncNote Quant Core

Windows 端可选的 Python 3.11+ 量化与模拟执行内核。自有代码按仓库 MIT 许可证发布。

```powershell
python -m venv .venv
.venv\Scripts\python.exe -m pip install -e .
.venv\Scripts\python.exe -m pip install -e ".[dev]"
.venv\Scripts\python.exe -m pytest
```

可选扩展为 `tushare`、`duckdb`、`backtest` 和 `all`。Tushare 使用环境变量 `TUSHARE_TOKEN`，不要写入源码或提交令牌。基础模拟账户不需要 Tushare 付费积分。

数据与结果必须遵守所选供应商许可。当前模拟不是券商交易系统，也尚未覆盖全部公司行为和真实市场微观结构，参见上级目录的已知限制文档。
