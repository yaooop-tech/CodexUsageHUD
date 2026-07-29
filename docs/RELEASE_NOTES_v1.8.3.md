# Codex Usage HUD v1.8.3

## Highlights

- Fixed activity monitoring when several file events arrive during an in-progress scan. The HUD now queues an immediate follow-up refresh instead of dropping the final start or completion update.
- Restored reliable real activity after documentation captures by keeping demonstration data in debug-only builds. The downloadable app contains no demonstration override.
- Prevented hover auto-collapse while task activity is visible, and balanced the divider spacing in the collapsed dual-window activity layout.
- Improved Codex window detection when the weekly window appears in the primary API slot and the short window has no duration label.
- Kept expanded error presentation compact so the fixed-size HUD remains stable.

## Notes

- Apple Silicon only; requires macOS 14 or later.
- This preview remains ad-hoc signed and not notarized. See the README for first-launch Gatekeeper steps.
- The ZIP includes only the app and required helper. A SHA-256 checksum is provided alongside the download.

---

## 中文说明

- 修复活动监听刷新期间连续收到多个文件事件时，最后一条状态可能被漏掉的问题。现在会立即补充刷新，不再让任务开始或完成状态滞留到兜底轮询。
- 截图演示数据仅存在于调试构建中，可下载 App 不包含演示状态覆盖。
- 任务活动可见时不再因鼠标移出而自动收起，并统一双额度活动态分割线与上下内容的间距。
- 改进 Codex 额度窗口识别：当周限额出现在 API 主窗口、短窗口缺少时长标记时，仍能正确保留并展示两种额度。
- 压缩展开态错误信息占用空间，保持固定尺寸 HUD 稳定。

## 提醒

- 仅支持 Apple Silicon，要求 macOS 14 或更高版本。
- 本体验版采用临时签名且未公证；首次启动的 Gatekeeper 放行步骤请见 README。
- ZIP 只含 App 和必需辅助程序；下载页同时提供 SHA-256 校验文件。
