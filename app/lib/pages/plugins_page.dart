import 'package:dsh_link_protocol/dsh_link_protocol.dart';
import 'package:flutter/material.dart';

import '../plugins_controller.dart';
import '../theme.dart';

/// 底部详情页高度占比。
const double _sheetHeightFactor = 0.75;

/// 装 / 卸 / 启停都要提前说清楚的一句话。
const String _reloadNote = '插件会短暂重载，正在跑的任务可能被打断。';

/// 插件管理页：手机上操作电脑那份 DSH 的插件清单与市场。
///
/// 数据与轮询全在 [PluginsController] 里，页面只负责画和确认。
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key, required this.client});

  final DshClient client;

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> with SingleTickerProviderStateMixin {
  late final PluginsController _controller = PluginsController(widget.client);
  late final TabController _tabs = TabController(length: 2, vsync: this);
  final TextEditingController _search = TextEditingController();

  int _seenEvent = 0;

  @override
  void initState() {
    super.initState();
    _controller.addListener(_onControllerEvent);
    _controller.refreshAll();
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerEvent);
    _controller.dispose();
    _tabs.dispose();
    _search.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------- 事件反馈

  void _onControllerEvent() {
    if (!mounted) return;
    final seq = _controller.eventSeq;
    if (seq <= _seenEvent) return;
    _seenEvent = seq;
    final text = _controller.eventText;
    if (text == null || text.isEmpty) return;
    final ok = _controller.eventOk;
    // 控制器可能在 build 期间通知，SnackBar 挪到下一帧再弹。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _toast(text, ok: ok);
    });
  }

  void _toast(String text, {bool ok = true}) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: AidockColors.surfaceAlt,
        margin: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
        duration: Duration(seconds: ok ? 3 : 5),
        content: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 1),
              child: Icon(
                ok ? Icons.check_circle_outline_rounded : Icons.error_outline_rounded,
                size: 17,
                color: ok ? AidockColors.ok : AidockColors.danger,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                text,
                style:  TextStyle(fontSize: 13, height: 1.5, color: AidockColors.text),
              ),
            ),
          ],
        ),
      ));
  }

  Future<bool> _confirm({
    required String title,
    required String message,
    required String action,
    bool danger = false,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AidockColors.surface,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
        titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
        contentPadding: const EdgeInsets.fromLTRB(20, 10, 20, 4),
        actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
        title: Text(
          title,
          style:  TextStyle(fontSize: 16, height: 1.4, fontWeight: FontWeight.w600, color: AidockColors.text),
        ),
        content: Text(
          message,
          style:  TextStyle(fontSize: 13, height: 1.6, color: AidockColors.textDim),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child:  Text('取消', style: TextStyle(fontSize: 14, color: AidockColors.textDim)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: Text(
              action,
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: danger ? AidockColors.danger : AidockColors.accent,
              ),
            ),
          ),
        ],
      ),
    );
    return result == true;
  }

  // ------------------------------------------------------------------ 动作

  Future<void> _refresh() async {
    await _controller.refreshAll();
  }

  Future<void> _toggle(InstalledPlugin plugin, bool next) async {
    final confirmed = await _confirm(
      title: next ? '启用 ${plugin.moduleName}' : '停用 ${plugin.moduleName}',
      message: next
          ? '$_reloadNote\n\n启用后这个插件会重新加载。'
          : '$_reloadNote\n\n停用后它的功能会立刻从电脑上消失。',
      action: next ? '启用' : '停用',
      danger: !next,
    );
    if (!confirmed || !mounted) return;
    final error = await _controller.setEnabled(plugin.moduleName, next);
    if (!mounted || error == null) return;
    _toast(error, ok: false);
  }

  Future<void> _uninstall(InstalledPlugin plugin) async {
    if (_controller.selfName.isNotEmpty && _controller.selfName == plugin.moduleName) {
      _toast('这个插件承载手机连接，不能在手机上卸载', ok: false);
      return;
    }
    final confirmed = await _confirm(
      title: '卸载 ${plugin.moduleName}',
      message: '会从电脑上的 DSH 里删掉这个插件。\n\n$_reloadNote',
      action: '卸载',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    final error = await _controller.removeBundle(plugin.moduleName);
    if (!mounted || error == null) return;
    _toast(error, ok: false);
  }

  Future<void> _startInstall(String name) async {
    final choice = await showDialog<Map<String, String?>>(
      context: context,
      builder: (_) => _InstallDialog(controller: _controller, name: name),
    );
    if (choice == null || !mounted) return;
    final version = choice['version'];
    final registry = choice['registry'];
    final versionText = version == null ? '最新版本' : version;
    final confirmed = await _confirm(
      title: '安装 $name',
      message: '将安装 $versionText。\n\n$_reloadNote',
      action: '安装',
    );
    if (!confirmed || !mounted) return;
    final error = await _controller.install(name: name, version: version, registry: registry);
    if (!mounted || error == null) return;
    _toast(error, ok: false);
  }

  Future<void> _cancelOperation() async {
    final confirmed = await _confirm(
      title: '停止这次操作？',
      message: '宿主会尽量中止，已经写下的文件不一定能全部还原。',
      action: '停止',
      danger: true,
    );
    if (!confirmed || !mounted) return;
    final error = await _controller.cancelOperation();
    if (!mounted || error == null) return;
    _toast(error, ok: false);
  }

  Future<void> _openDetail(String name) async {
    final bundle = _controller.bundleFor(name);
    if (bundle == null) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => FractionallySizedBox(
        heightFactor: _sheetHeightFactor,
        child: _DetailSheet(
          name: name,
          controller: _controller,
          onInstall: () {
            Navigator.of(sheetContext).pop();
            _startInstall(name);
          },
        ),
      ),
    );
  }

  // ------------------------------------------------------------------ 骨架

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) => Scaffold(
        backgroundColor: AidockColors.bg,
        appBar: AppBar(
          title: const Text('插件'),
          actions: [
            IconButton(
              tooltip: '刷新',
              onPressed: _controller.installedLoading || _controller.marketLoading ? null : _refresh,
              icon: _controller.installedLoading || _controller.marketLoading
                  ?  SizedBox(
                      width: 17,
                      height: 17,
                      child: CircularProgressIndicator(strokeWidth: 2, color: AidockColors.textDim),
                    )
                  :  Icon(Icons.refresh_rounded, size: 21, color: AidockColors.text),
            ),
          ],
          bottom: TabBar(
            controller: _tabs,
            labelColor: AidockColors.text,
            unselectedLabelColor: AidockColors.textDim,
            indicatorColor: AidockColors.accent,
            indicatorSize: TabBarIndicatorSize.label,
            indicatorWeight: 2,
            labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
            unselectedLabelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w500),
            tabs: const [Tab(text: '已安装', height: 44), Tab(text: '市场', height: 44)],
          ),
        ),
        body: Column(
          children: [
            if (_controller.operationRunning) _progressBanner(),
            Expanded(
              child: TabBarView(
                controller: _tabs,
                children: [_installedTab(), _marketTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _progressBanner() {
    final kind = _controller.kindLabel(_controller.operationKind);
    final phase = _controller.operationPhase;
    final detail = (phase == null || phase.isEmpty)
        ? '已用 ${_controller.operationElapsed} 秒'
        : '$phase · 已用 ${_controller.operationElapsed} 秒';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration:  BoxDecoration(
        color: AidockColors.surface,
        border: Border(bottom: BorderSide(color: AidockColors.line, width: 1)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
               Icon(Icons.sync_rounded, size: 16, color: AidockColors.accent),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  '正在$kind ${_controller.operationTarget}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style:  TextStyle(
                    fontSize: 13,
                    height: 1.4,
                    fontWeight: FontWeight.w500,
                    color: AidockColors.text,
                  ),
                ),
              ),
              TextButton(
                onPressed: _cancelOperation,
                style: TextButton.styleFrom(
                  minimumSize: const Size(56, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  foregroundColor: AidockColors.textDim,
                ),
                child: const Text('停止', style: TextStyle(fontSize: 12.5)),
              ),
            ],
          ),
          const SizedBox(height: 8),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child:  LinearProgressIndicator(
              minHeight: 3,
              backgroundColor: AidockColors.line,
              valueColor: AlwaysStoppedAnimation<Color>(AidockColors.accent),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            style:  TextStyle(fontSize: 11.5, height: 1.4, color: AidockColors.textDim),
          ),
        ],
      ),
    );
  }

  // -------------------------------------------------------------- 已安装 tab

  Widget _installedTab() {
    final c = _controller;
    if (c.installed.isEmpty) {
      if (c.installedLoading) return const _LoadingBlock(label: '正在读电脑上的插件清单');
      if (c.installedError != null) {
        return _ErrorBlock(
          message: c.installedError!,
          onRetry: () => c.refreshInstalled(force: true),
        );
      }
      return _EmptyBlock(
        icon: Icons.extension_outlined,
        title: '电脑上还没有插件',
        hint: '去「市场」看看能装点什么',
        action: TextButton(
          onPressed: () => _tabs.animateTo(1),
          style: TextButton.styleFrom(foregroundColor: AidockColors.accent),
          child: const Text('打开市场', style: TextStyle(fontSize: 13.5)),
        ),
      );
    }
    final items = c.installed;
    return RefreshIndicator(
      onRefresh: () => c.refreshInstalled(force: true),
      color: AidockColors.accent,
      backgroundColor: AidockColors.surface,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        itemCount: items.length + 1,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) {
          if (index == 0) return _installedHeader(items.length);
          return _installedTile(items[index - 1]);
        },
      ),
    );
  }

  Widget _installedHeader(int count) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 2),
      child: Row(
        children: [
          Text(
            '共 $count 个插件',
            style:  TextStyle(fontSize: 12, height: 1.4, color: AidockColors.textDim),
          ),
          const Spacer(),
           Text(
            '长按可卸载',
            style: TextStyle(fontSize: 12, height: 1.4, color: AidockColors.textDim),
          ),
        ],
      ),
    );
  }

  Widget _installedTile(InstalledPlugin plugin) {
    final busy = _controller.isBusy(plugin.moduleName);
    final isSelf = _controller.selfName.isNotEmpty && _controller.selfName == plugin.moduleName;
    final failed = plugin.fiberPhase == 'failed';
    return Material(
      color: AidockColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onLongPress: busy ? null : () => _uninstall(plugin),
        child: Container(
          padding: const EdgeInsets.fromLTRB(14, 10, 8, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AidockColors.line),
          ),
          child: Row(
            children: [
              _StatusDot(phase: plugin.fiberPhase),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      plugin.moduleName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style:  TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 13,
                        height: 1.45,
                        fontWeight: FontWeight.w500,
                        color: AidockColors.text,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            _phaseLabel(plugin.fiberPhase),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.35,
                              color: failed ? AidockColors.danger : AidockColors.textDim,
                            ),
                          ),
                        ),
                        if (isSelf) ...[
                          const SizedBox(width: 6),
                           _Badge(label: '连接插件', color: AidockColors.accent),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              if (busy)
                 Padding(
                  padding: EdgeInsets.only(right: 4),
                  child: SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(strokeWidth: 2, color: AidockColors.textDim),
                  ),
                ),
              Switch(
                value: plugin.enabled,
                onChanged: busy ? null : (value) => _toggle(plugin, value),
                activeColor: AidockColors.accent,
                activeTrackColor: AidockColors.accentSoft,
                inactiveThumbColor: AidockColors.textDim,
                inactiveTrackColor: AidockColors.surfaceAlt,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------- 市场 tab

  Widget _marketTab() {
    final hasQuery = _search.text.trim().isNotEmpty;
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: _search,
            onChanged: (_) => setState(() {}),
            textInputAction: TextInputAction.search,
            style:  TextStyle(fontSize: 14, height: 1.4, color: AidockColors.text),
            cursorColor: AidockColors.accent,
            decoration: InputDecoration(
              hintText: '搜索插件名或说明',
              hintStyle:  TextStyle(fontSize: 14, color: AidockColors.textDim),
              prefixIcon:  Icon(Icons.search_rounded, size: 19, color: AidockColors.textDim),
              suffixIcon: hasQuery
                  ? IconButton(
                      tooltip: '清除搜索',
                      onPressed: () => setState(_search.clear),
                      icon:  Icon(Icons.close_rounded, size: 17, color: AidockColors.textDim),
                    )
                  : null,
              isDense: true,
              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
            ),
          ),
        ),
        Expanded(child: _marketBody()),
      ],
    );
  }

  Widget _marketBody() {
    final c = _controller;
    if (c.bundles.isEmpty) {
      if (c.marketLoading) return const _LoadingBlock(label: '正在读市场清单');
      if (c.marketError != null) {
        return _ErrorBlock(message: c.marketError!, onRetry: () => c.loadMarket());
      }
      return const _EmptyBlock(
        icon: Icons.storefront_outlined,
        title: '市场里还没有可装的插件',
        hint: '下拉刷新，或到电脑上看看插件源配置',
      );
    }
    final query = _search.text.trim().toLowerCase();
    final visible = c.bundles.where((bundle) => _matches(bundle, query)).toList(growable: false);
    if (visible.isEmpty) {
      return _EmptyBlock(
        icon: Icons.search_off_rounded,
        title: '没有匹配的插件',
        hint: query.isEmpty ? '换个关键词试试' : '没有名字或说明里带「${_search.text.trim()}」的插件',
        action: TextButton(
          onPressed: () => setState(_search.clear),
          style: TextButton.styleFrom(foregroundColor: AidockColors.accent),
          child: const Text('清空搜索', style: TextStyle(fontSize: 13.5)),
        ),
      );
    }
    return RefreshIndicator(
      onRefresh: () => c.loadMarket(),
      color: AidockColors.accent,
      backgroundColor: AidockColors.surface,
      child: ListView.separated(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 32),
        itemCount: visible.length,
        separatorBuilder: (_, __) => const SizedBox(height: 10),
        itemBuilder: (context, index) => _marketTile(visible[index]),
      ),
    );
  }

  bool _matches(MarketBundle bundle, String query) {
    if (query.isEmpty) return true;
    if (bundle.name.toLowerCase().contains(query)) return true;
    if (bundle.title.toLowerCase().contains(query)) return true;
    return bundle.description.toLowerCase().contains(query);
  }

  Widget _marketTile(MarketBundle bundle) {
    final badges = <Widget>[
      if (bundle.installed)
         _Badge(label: '已装', color: AidockColors.ok, icon: Icons.check_rounded)
      else
         _Badge(label: '未装', color: AidockColors.textDim),
      if (bundle.official)  _Badge(label: '官方', color: AidockColors.warn),
      if (bundle.update != null) _Badge(label: '可更新 ${bundle.update}', color: AidockColors.accent),
      if (bundle.errorMessage != null)  _Badge(label: '不可用', color: AidockColors.danger),
    ];
    return Material(
      color: AidockColors.surface,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openDetail(bundle.name),
        child: Container(
          padding: const EdgeInsets.fromLTRB(12, 12, 10, 12),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: AidockColors.line),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _bundleIcon(bundle),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(
                          child: Text(
                            bundle.title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style:  TextStyle(
                              fontSize: 14,
                              height: 1.45,
                              fontWeight: FontWeight.w600,
                              color: AidockColors.text,
                            ),
                          ),
                        ),
                        if (bundle.version != null) ...[
                          const SizedBox(width: 6),
                          Text(
                            bundle.version!,
                            style:  TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 11,
                              height: 1.6,
                              color: AidockColors.textDim,
                            ),
                          ),
                        ],
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      bundle.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:  TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11.5,
                        height: 1.35,
                        color: AidockColors.textDim,
                      ),
                    ),
                    if (bundle.description.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        bundle.description,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style:  TextStyle(
                          fontSize: 12,
                          height: 1.5,
                          color: AidockColors.textDim,
                        ),
                      ),
                    ],
                    if (badges.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Wrap(spacing: 6, runSpacing: 6, children: badges),
                    ],
                  ],
                ),
              ),
               Padding(
                padding: EdgeInsets.only(left: 2, top: 2),
                child: Icon(Icons.chevron_right_rounded, size: 18, color: AidockColors.textDim),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _bundleIcon(MarketBundle bundle) {
    final bytes = bundle.iconBytes;
    return Container(
      width: 40,
      height: 40,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AidockColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AidockColors.line),
      ),
      child: bytes == null
          ?  Icon(Icons.extension_outlined, size: 19, color: AidockColors.textDim)
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                   Icon(Icons.extension_outlined, size: 19, color: AidockColors.textDim),
            ),
    );
  }
}

// ---------------------------------------------------------------- 详情 sheet

class _DetailSheet extends StatefulWidget {
  const _DetailSheet({
    required this.name,
    required this.controller,
    required this.onInstall,
  });

  final String name;
  final PluginsController controller;
  final VoidCallback onInstall;

  @override
  State<_DetailSheet> createState() => _DetailSheetState();
}

class _DetailSheetState extends State<_DetailSheet> {
  late Future<PluginDetail> _future = widget.controller.loadDetail(widget.name);

  void _retry() {
    setState(() {
      _future = widget.controller.loadDetail(widget.name, refresh: true);
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration:  BoxDecoration(
        color: AidockColors.surface,
        borderRadius: BorderRadius.vertical(top: Radius.circular(18)),
        border: Border(top: BorderSide(color: AidockColors.line, width: 1)),
      ),
      child: AnimatedBuilder(
        animation: widget.controller,
        builder: (context, _) {
          final bundle = widget.controller.bundleFor(widget.name);
          return Column(
            children: [
              const SizedBox(height: 8),
              Container(
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: AidockColors.line,
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: _header(bundle),
              ),
               Divider(height: 1, thickness: 1, color: AidockColors.line),
              Expanded(child: _detailBody()),
              _footer(bundle),
            ],
          );
        },
      ),
    );
  }

  Widget _header(MarketBundle? bundle) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (bundle != null) ...[
          _SheetIcon(bundle: bundle),
          const SizedBox(width: 12),
        ],
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                bundle?.title ?? widget.name,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style:  TextStyle(
                  fontSize: 16,
                  height: 1.4,
                  fontWeight: FontWeight.w600,
                  color: AidockColors.text,
                ),
              ),
              const SizedBox(height: 3),
              Text(
                widget.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style:  TextStyle(
                  fontFamily: 'monospace',
                  fontSize: 11.5,
                  height: 1.35,
                  color: AidockColors.textDim,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  if (bundle?.version != null)
                    _Badge(label: bundle!.version!, color: AidockColors.textDim),
                  if (bundle?.installed == true)
                     _Badge(label: '已装', color: AidockColors.ok, icon: Icons.check_rounded)
                  else
                     _Badge(label: '未装', color: AidockColors.textDim),
                  if (bundle?.official == true)  _Badge(label: '官方', color: AidockColors.warn),
                  if (bundle?.update != null)
                    _Badge(label: '可更新 ${bundle!.update}', color: AidockColors.accent),
                  if (bundle?.protectedSelf == true)
                     _Badge(label: '连接插件', color: AidockColors.accent),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _detailBody() {
    return FutureBuilder<PluginDetail>(
      future: _future,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return  Center(
            child: SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2, color: AidockColors.accent),
            ),
          );
        }
        final detail = snapshot.data;
        if (detail == null || detail.error != null) {
          return _ErrorBlock(
            message: detail?.error ?? '说明没读出来',
            onRetry: _retry,
            compact: true,
          );
        }
        if (!detail.hasText) {
          return Center(
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 32),
              child: Text(
                detail.status == 'none' ? '这个插件没有附说明文档' : '说明文档是空的',
                textAlign: TextAlign.center,
                style:  TextStyle(fontSize: 13, height: 1.6, color: AidockColors.textDim),
              ),
            ),
          );
        }
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: _markdownBlocks(detail.markdown),
          ),
        );
      },
    );
  }

  Widget _footer(MarketBundle? bundle) {
    final blocked = bundle == null || bundle.protectedSelf || bundle.errorMessage != null;
    final label = bundle?.installed == true ? '更新 / 重装' : '安装';
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
        child: Row(
          children: [
            if (bundle?.errorMessage != null)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(right: 10),
                  child: Text(
                    bundle!.errorMessage!,
                    maxLines: 3,
                    overflow: TextOverflow.ellipsis,
                    style:  TextStyle(fontSize: 12, height: 1.45, color: AidockColors.danger),
                  ),
                ),
              )
            else
              const Spacer(),
            if (!blocked)
              FilledButton(
                onPressed: widget.onInstall,
                style: FilledButton.styleFrom(
                  backgroundColor: AidockColors.accent,
                  foregroundColor: AidockColors.bg,
                  minimumSize: const Size(96, 42),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                ),
                child: Text(label, style: const TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600)),
              ),
          ],
        ),
      ),
    );
  }

  /// Markdown 只做「能读」的处理：标题、列表、引用、分隔线，其余按等宽正文排。
  List<Widget> _markdownBlocks(String source) {
    const body = TextStyle(
      fontFamily: 'monospace',
      fontSize: 12.5,
      height: 1.65,
      color: AidockColors.text,
    );
    final blocks = <Widget>[];
    final lines = source.replaceAll('\r\n', '\n').split('\n');
    for (final raw in lines) {
      final line = raw.trimRight();
      final trimmed = line.trim();
      if (trimmed.isEmpty) {
        blocks.add(const SizedBox(height: 6));
        continue;
      }
      if (trimmed == '---' || trimmed == '***' || trimmed == '___') {
        blocks.add( Padding(
          padding: EdgeInsets.symmetric(vertical: 8),
          child: Divider(height: 1, thickness: 1, color: AidockColors.line),
        ));
        continue;
      }
      if (trimmed.startsWith('#')) {
        var level = 0;
        while (level < trimmed.length && trimmed[level] == '#') {
          level += 1;
        }
        final heading = trimmed.substring(level).trim();
        if (heading.isEmpty) continue;
        blocks.add(Padding(
          padding: const EdgeInsets.only(top: 10, bottom: 4),
          child: Text(
            heading,
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: level <= 1 ? 15 : (level == 2 ? 13.5 : 12.5),
              height: 1.45,
              fontWeight: FontWeight.w600,
              color: AidockColors.text,
            ),
          ),
        ));
        continue;
      }
      if (trimmed.startsWith('- ') || trimmed.startsWith('* ') || trimmed.startsWith('+ ')) {
        blocks.add(Padding(
          padding: const EdgeInsets.only(left: 2, bottom: 2),
          child: Text('· ${trimmed.substring(2).trim()}', style: body),
        ));
        continue;
      }
      if (trimmed.startsWith('>')) {
        blocks.add(Container(
          margin: const EdgeInsets.only(top: 2, bottom: 4),
          padding: const EdgeInsets.only(left: 9),
          decoration: BoxDecoration(
            border: Border(
              left: BorderSide(color: AidockColors.accent.withOpacity(0.45), width: 2),
            ),
          ),
          child: Text(trimmed.substring(1).trim(), style: body),
        ));
        continue;
      }
      blocks.add(Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text(trimmed, style: body),
      ));
    }
    return blocks;
  }
}

class _SheetIcon extends StatelessWidget {
  const _SheetIcon({required this.bundle});

  final MarketBundle bundle;

  @override
  Widget build(BuildContext context) {
    final bytes = bundle.iconBytes;
    return Container(
      width: 44,
      height: 44,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: AidockColors.surfaceAlt,
        borderRadius: BorderRadius.circular(11),
        border: Border.all(color: AidockColors.line),
      ),
      child: bytes == null
          ?  Icon(Icons.extension_outlined, size: 21, color: AidockColors.textDim)
          : Image.memory(
              bytes,
              fit: BoxFit.cover,
              gaplessPlayback: true,
              errorBuilder: (_, __, ___) =>
                   Icon(Icons.extension_outlined, size: 21, color: AidockColors.textDim),
            ),
    );
  }
}

// ------------------------------------------------------------ 安装选项对话框

class _InstallDialog extends StatefulWidget {
  const _InstallDialog({required this.controller, required this.name});

  final PluginsController controller;
  final String name;

  @override
  State<_InstallDialog> createState() => _InstallDialogState();
}

class _InstallDialogState extends State<_InstallDialog> {
  String _registry = '';
  String _version = '';
  PluginVersions? _versions;
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final result = await widget.controller.loadVersions(
      widget.name,
      registry: _registry.isEmpty ? null : _registry,
      refresh: true,
    );
    if (!mounted) return;
    setState(() {
      _versions = result;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    final registryOptions = <String>['', ...controller.registries];
    final versions = _versions;
    final versionOptions = <String>[''];
    if (versions != null && versions.listed) {
      for (final item in versions.versions) {
        versionOptions.add(item.version);
      }
    }
    final currentVersion = versionOptions.contains(_version) ? _version : '';

    return AlertDialog(
      backgroundColor: AidockColors.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      titlePadding: const EdgeInsets.fromLTRB(20, 18, 20, 0),
      contentPadding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      actionsPadding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
      title: Text(
        '安装 ${widget.name}',
        style:  TextStyle(fontSize: 16, height: 1.4, fontWeight: FontWeight.w600, color: AidockColors.text),
      ),
      content: SizedBox(
        width: 320,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
             Text(
              '版本',
              style: TextStyle(fontSize: 12, height: 1.4, color: AidockColors.textDim),
            ),
            const SizedBox(height: 6),
            _dropdown(
              value: currentVersion,
              items: versionOptions.map((value) {
                String label;
                if (value.isEmpty) {
                  label = '最新版本';
                } else {
                  final match = versions?.versions.where((item) => item.version == value).toList();
                  final tags = match == null || match.isEmpty ? const <String>[] : match.first.tags;
                  final prerelease = match != null && match.isNotEmpty && match.first.prerelease;
                  label = tags.isEmpty
                      ? (value.isEmpty ? '最新版本' : value)
                      : '$value（${tags.join(' / ')}）';
                  if (prerelease && tags.isEmpty) label = '$value（预发布）';
                }
                return MapEntry(value, label);
              }).toList(),
              onChanged: _loading
                  ? null
                  : (value) => setState(() {
                        _version = value;
                      }),
            ),
            const SizedBox(height: 8),
            _versionHint(versions),
            const SizedBox(height: 14),
             Text(
              'npm 源',
              style: TextStyle(fontSize: 12, height: 1.4, color: AidockColors.textDim),
            ),
            const SizedBox(height: 6),
            _dropdown(
              value: registryOptions.contains(_registry) ? _registry : '',
              items: registryOptions.map((value) {
                final label = value.isEmpty
                    ? (controller.configuredRegistry == null
                        ? '跟随宿主配置'
                        : '跟随宿主配置（${controller.configuredRegistry}）')
                    : value;
                return MapEntry(value, label);
              }).toList(),
              onChanged: (value) {
                setState(() {
                  _registry = value;
                  _version = '';
                  _versions = null;
                  _loading = true;
                });
                _load();
              },
            ),
            const SizedBox(height: 8),
            Text(
              '装完由宿主重新加载，这台手机上立刻能看到变化。',
              style:  TextStyle(fontSize: 11.5, height: 1.5, color: AidockColors.textDim),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child:  Text('取消', style: TextStyle(fontSize: 14, color: AidockColors.textDim)),
        ),
        TextButton(
          onPressed: () => Navigator.of(context).pop(<String, String?>{
            'version': currentVersion.isEmpty ? null : currentVersion,
            'registry': _registry.isEmpty ? null : _registry,
          }),
          child:  Text(
            '下一步',
            style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: AidockColors.accent),
          ),
        ),
      ],
    );
  }

  Widget _versionHint(PluginVersions? versions) {
    if (_loading) {
      return  Row(
        children: [
          SizedBox(width: 11, height: 11, child: CircularProgressIndicator(strokeWidth: 2, color: AidockColors.textDim)),
          SizedBox(width: 6),
          Text('正在查可选版本', style: TextStyle(fontSize: 11.5, height: 1.4, color: AidockColors.textDim)),
        ],
      );
    }
    if (versions == null) {
      return  Text(
        '没查到版本，按最新版本装',
        style: TextStyle(fontSize: 11.5, height: 1.4, color: AidockColors.textDim),
      );
    }
    if (!versions.listed) {
      final detail = versions.error ?? versions.problemText;
      return Text(
        detail.isEmpty ? '这个源上没列出这个插件' : '这个源拒绝了：$detail',
        style:  TextStyle(fontSize: 11.5, height: 1.5, color: AidockColors.warn),
      );
    }
    if (versions.versions.isEmpty) {
      return  Text(
        '这个源上没有可选版本，按最新版本装',
        style: TextStyle(fontSize: 11.5, height: 1.4, color: AidockColors.textDim),
      );
    }
    return Text(
      '共 ${versions.versions.length} 个版本，默认最新',
      style:  TextStyle(fontSize: 11.5, height: 1.4, color: AidockColors.textDim),
    );
  }

  Widget _dropdown({
    required String value,
    required List<MapEntry<String, String>> items,
    required ValueChanged<String>? onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        color: AidockColors.surfaceAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AidockColors.line),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isExpanded: true,
          dropdownColor: AidockColors.surfaceAlt,
          icon:  Icon(Icons.expand_more_rounded, size: 18, color: AidockColors.textDim),
          style:  TextStyle(fontSize: 13, height: 1.4, color: AidockColors.text),
          onChanged: onChanged == null
              ? null
              : (next) {
                  if (next != null) onChanged(next);
                },
          items: items
              .map((item) => DropdownMenuItem<String>(
                    value: item.key,
                    child: Text(
                      item.value,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style:  TextStyle(fontSize: 13, height: 1.4, color: AidockColors.text),
                    ),
                  ))
              .toList(),
        ),
      ),
    );
  }
}

// ------------------------------------------------------------------ 小组件

class _StatusDot extends StatelessWidget {
  const _StatusDot({required this.phase});

  final String? phase;

  @override
  Widget build(BuildContext context) {
    final color = _phaseColor(phase);
    return Container(
      width: 9,
      height: 9,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        boxShadow: [
          BoxShadow(color: color.withOpacity(0.35), blurRadius: 6, spreadRadius: 1),
        ],
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge({required this.label, required this.color, this.icon});

  final String label;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final mark = icon;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.13),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.26), width: 0.8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (mark != null) ...[
            Icon(mark, size: 11, color: color),
            const SizedBox(width: 2),
          ],
          Text(
            label,
            style: TextStyle(fontSize: 10.5, height: 1.35, color: color, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }
}

class _LoadingBlock extends StatelessWidget {
  const _LoadingBlock({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
           SizedBox(
            width: 22,
            height: 22,
            child: CircularProgressIndicator(strokeWidth: 2, color: AidockColors.accent),
          ),
          const SizedBox(height: 12),
          Text(
            label,
            style:  TextStyle(fontSize: 12.5, height: 1.4, color: AidockColors.textDim),
          ),
        ],
      ),
    );
  }
}

class _ErrorBlock extends StatelessWidget {
  const _ErrorBlock({required this.message, required this.onRetry, this.compact = false});

  final String message;
  final VoidCallback onRetry;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final body = Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          Icons.cloud_off_rounded,
          size: compact ? 26 : 32,
          color: AidockColors.textDim,
        ),
        SizedBox(height: compact ? 8 : 12),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            message,
            textAlign: TextAlign.center,
            style:  TextStyle(fontSize: 13, height: 1.6, color: AidockColors.textDim),
          ),
        ),
        const SizedBox(height: 10),
        TextButton(
          onPressed: onRetry,
          style: TextButton.styleFrom(foregroundColor: AidockColors.accent),
          child: const Text('重试', style: TextStyle(fontSize: 13.5)),
        ),
      ],
    );
    return Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24), child: body));
  }
}

class _EmptyBlock extends StatelessWidget {
  const _EmptyBlock({
    required this.icon,
    required this.title,
    required this.hint,
    this.action,
  });

  final IconData icon;
  final String title;
  final String hint;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 34, color: AidockColors.textDim),
            const SizedBox(height: 14),
            Text(
              title,
              textAlign: TextAlign.center,
              style:  TextStyle(
                fontSize: 14.5,
                height: 1.45,
                fontWeight: FontWeight.w600,
                color: AidockColors.text,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              hint,
              textAlign: TextAlign.center,
              style:  TextStyle(fontSize: 12.5, height: 1.6, color: AidockColors.textDim),
            ),
            if (action != null) ...[
              const SizedBox(height: 6),
              action!,
            ],
          ],
        ),
      ),
    );
  }
}

Color _phaseColor(String? phase) {
  if (phase == 'active') return AidockColors.ok;
  if (phase == 'failed') return AidockColors.danger;
  return AidockColors.warn;
}

String _phaseLabel(String? phase) {
  switch (phase) {
    case 'active':
      return '运行中';
    case 'loading':
      return '正在加载';
    case 'unloading':
      return '正在卸载';
    case 'pending':
      return '等待启用';
    case 'failed':
      return '加载失败';
    default:
      return '未运行';
  }
}
