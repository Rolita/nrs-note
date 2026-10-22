/// 浏览器没有可拦截的「关闭窗口」。
///
/// 关闭标签页时脚本拿不到可靠的收尾时机，强行监听 `beforeunload` 也只能
/// 发起异步写入、无法保证落盘；因此这里不做拦截，实际写入仍由每次保存完成。
Future<void> guardCloseBeforeExit(Future<void> Function() flush) async {}
