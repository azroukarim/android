import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../data/catalog_service.dart';
import '../data/models.dart';
import '../data/playback.dart';
import '../data/player_engine.dart';
import '../data/repository.dart';
import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'app_backdrop.dart';
import 'back_guard.dart';
import 'player_screen.dart';
import 'top_nav.dart';
import 'tv_focus.dart';

class LiveScreen extends StatefulWidget {
  const LiveScreen({super.key});

  @override
  State<LiveScreen> createState() => _LiveScreenState();
}

class _LiveScreenState extends State<LiveScreen> {
  static const _pageSize = 80;

  final List<MediaCategory> _groups = [];
  final List<MediaItem> _items = [];
  final ScrollController _scroll = ScrollController();
  final FocusNode _firstChannelFocus = FocusNode(debugLabel: 'live-first');
  bool _focusChannelsAfterLoad = false;

  late final Player _mini;
  late final VideoController _miniController;
  late final Widget _miniVideo;
  final List<StreamSubscription<dynamic>> _subs = [];
  Timer? _previewDebounce;
  String? _miniUrl;
  bool _previewFailed = false;
  bool _previewBuffering = true;

  List<EpgEntry> _epg = const [];
  int _epgToken = 0;

  String? _groupId;
  MediaItem? _selected;
  bool _loadingGroups = true;
  bool _loadingItems = false;
  bool _hasMore = true;
  int _offset = 0;
  int _itemsToken = 0;
  String? _error;

  @override
  void initState() {
    super.initState();
    _mini = PlaybackService.I.player;
    _miniController = PlaybackService.I.controller;
    _miniVideo = Video(
      controller: _miniController,
      controls: NoVideoControls,
      fit: BoxFit.cover,
    );
    PlaybackService.I.setMuted(false);
    _subs.add(
      _mini.stream.buffering.listen((value) {
        if (mounted && value != _previewBuffering) {
          setState(() => _previewBuffering = value);
        }
      }),
    );
    _subs.add(
      _mini.stream.error.listen((_) {
        if (mounted && !_previewFailed) setState(() => _previewFailed = true);
      }),
    );
    _scroll.addListener(_maybeLoadMore);
    _loadGroups();
  }

  @override
  void dispose() {
    _previewDebounce?.cancel();
    for (final sub in _subs) {
      sub.cancel();
    }
    _scroll.dispose();
    _firstChannelFocus.dispose();
    PlaybackService.I.stop();
    super.dispose();
  }

  void _selectItem(MediaItem item) {
    if (_selected?.id == item.id) return;
    setState(() {
      _selected = item;
      _epg = const [];
    });
    _loadEpg(item);
  }

  /// OK on a channel: first press starts the Mini TV preview (and keeps it
  /// playing until another channel is pressed); a second press on the same
  /// channel opens it full screen.
  /// OK on a channel: first press starts the Mini TV preview (and keeps it
  /// playing until another channel is pressed); a second press on the same
  /// channel opens it full screen.
  void _onChannelOk(MediaItem item, int index) {
    // The channel is already selected AND the mini preview is running
    // (regardless of URL resolution): open full screen immediately.
    final alreadyPreviewing =
        _selected?.id == item.id && _miniUrl != null;
    if (alreadyPreviewing) {
      _play(index);
      return;
    }
    _selectItem(item);
    // Force an immediate preview instead of the debounced one.
    _miniUrl = null;
    _schedulePreview(immediate: true);
  }

  /// Debounced channel preview inside the right pane (Mini TV).
  void _schedulePreview({bool immediate = false}) {
    _previewDebounce?.cancel();
    final item = _selected;
    if (item == null) return;
    Future<void> run() async {
      if (!mounted) return;
      if (_miniUrl == item.url) return;
      _miniUrl = item.url;
      setState(() {
        _previewFailed = false;
        _previewBuffering = true;
      });
      try {
        final url = await Repository.I.resolveStream(item);
        if (!mounted || _miniUrl != item.url) return;
        await PlaybackService.I.open(url, muted: false);
      } catch (_) {
        if (mounted && _miniUrl == item.url) {
          setState(() => _previewFailed = true);
        }
      }
    }
    if (immediate) {
      run();
    } else {
      _previewDebounce = Timer(const Duration(milliseconds: 500), () => run());
    }
  }

  Future<void> _loadEpg(MediaItem item) async {
    final token = ++_epgToken;
    try {
      final epg = await Repository.I.epg(item);
      if (!mounted || token != _epgToken) return;
      setState(() => _epg = epg);
    } catch (_) {
      // EPG is optional.
    }
  }

  Future<void> _stopPreview() async {
    _previewDebounce?.cancel();
    _miniUrl = null;
    _previewBuffering = true;
    _epgToken++;
    _epg = const [];
    // Let libmpv finish stopping before the full-screen player takes over:
    // tearing the Mini TV video output down while mpv is still stopping can
    // invoke a deleted native callback and abort the app.
    await PlaybackService.I.stopIfCreated();
  }

  void _maybeLoadMore() {
    if (!_scroll.hasClients) return;
    if (_scroll.position.pixels >= _scroll.position.maxScrollExtent - 500) {
      _loadMore();
    }
  }

  /// CH+ / CH- scroll the channel list by one viewport of rows.
  void _pageChannels(int direction) {
    if (!_scroll.hasClients) return;
    final position = _scroll.position;
    final target = (position.pixels + direction * position.viewportDimension)
        .clamp(0.0, position.maxScrollExtent);
    _scroll.animateTo(
      target,
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeOutCubic,
    );
    if (direction > 0) unawaited(_loadMore());
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    // OK on the Mini TV (or when the preview is already playing) opens the
    // channel full screen.
    if ((event.logicalKey == LogicalKeyboardKey.select ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter ||
            event.logicalKey == LogicalKeyboardKey.gameButtonA) &&
        _selected != null &&
        _miniUrl != null) {
      final idx = _items.indexWhere((e) => e.id == _selected!.id);
      if (idx >= 0) {
        _play(idx);
        return KeyEventResult.handled;
      }
    }
    if (event.logicalKey == LogicalKeyboardKey.channelUp) {
      _pageChannels(1);
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.channelDown) {
      _pageChannels(-1);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  Future<void> _loadGroups() async {
    try {
      final groups = await Repository.I.categories(MediaKind.live);
      if (!mounted) return;
      setState(() {
        _groups
          ..clear()
          ..addAll(groups);
        _loadingGroups = false;
      });
      if (groups.isNotEmpty) {
        // Keep the provider's first real bouquet as the default view: the
        // smart "Nouveautés / Derniers lus" bouquets stay visible at the top.
        final initial = groups.firstWhere(
          (group) => !isVirtualCategory(group.id),
          orElse: () => groups.first,
        );
        _groupId = initial.id;
        await _loadItems(initial.id);
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loadingGroups = false;
      });
    }
  }

  Future<void> _loadItems(String groupId, {bool append = false}) async {
    // A newer selection supersedes any request still in flight; its result is
    // discarded through the token instead of blocking the new bouquet.
    final token = ++_itemsToken;
    if (!append) {
      _stopPreview();
      setState(() {
        _items.clear();
        _offset = 0;
        _hasMore = true;
        _selected = null;
      });
    }
    setState(() => _loadingItems = true);
    try {
      final page = await Repository.I.items(
        MediaKind.live,
        groupId,
        limit: _pageSize,
        offset: _offset,
      );
      if (!mounted || token != _itemsToken) return;
      setState(() {
        _items.addAll(page);
        _offset += page.length;
        _hasMore = page.length == _pageSize;
        _loadingItems = false;
        _selected ??= _items.isNotEmpty ? _items.first : null;
      });
      _schedulePreview();
      if (_focusChannelsAfterLoad) {
        _focusChannelsAfterLoad = false;
        _focusFirstChannel();
      }
      final item = _selected;
      if (item != null) _loadEpg(item);
    } catch (e) {
      if (!mounted || token != _itemsToken) return;
      _focusChannelsAfterLoad = false;
      setState(() {
        _error = '$e';
        _loadingItems = false;
      });
    }
  }

  Future<void> _loadMore() async {
    final id = _groupId;
    if (id == null || !_hasMore || _loadingItems) return;
    await _loadItems(id, append: true);
  }

  /// Selecting a bouquet (OK/tap) jumps to the first channel of the list.
  void _selectGroup(String id) {
    if (_groupId == id) {
      if (_items.isNotEmpty) {
        _focusFirstChannel();
        return;
      }
      if (_loadingItems) {
        // The bouquet is already loading; focus when it arrives.
        _focusChannelsAfterLoad = true;
        return;
      }
      return;
    }
    _focusChannelsAfterLoad = true;
    setState(() => _groupId = id);
    _loadItems(id);
  }

  void _focusFirstChannel() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_scroll.hasClients) _scroll.jumpTo(0);
      // The first tile is built during the next frame after the jump, so the
      // FocusNode is only attachable then.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        _firstChannelFocus.requestFocus();
      });
    });
  }

  Future<void> _play(int index) async {
    await _stopPreview();
    if (!mounted) return;
    // On tall phone panels, force PLEIN so the channel fills the screen
    // (a legacy AUTO/FIT mode would leave black bands on both sides).
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final tall = views.isNotEmpty &&
        views.first.physicalSize.shortestSide > 0 &&
        views.first.physicalSize.longestSide /
                views.first.physicalSize.shortestSide >=
            1.9;
    if (tall) {
      await PlayerEngineService.I.saveScreenMode(ScreenMode.full);
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => PlayerScreen(
          items: List<MediaItem>.of(_items),
          initialIndex: index,
          kind: MediaKind.live,
          groupName: _groupName,
          groupId: _groupId,
        ),
      ),
    );
    if (!mounted) return;
    _miniUrl = null;
    _schedulePreview();
    final item = _selected;
    if (item != null) _loadEpg(item);
  }

  String get _groupName {
    for (final group in _groups) {
      if (group.id == _groupId) return group.name;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    return GuardedBack(
      child: Focus(
        canRequestFocus: false,
        onKeyEvent: _onKey,
        child: Scaffold(
          body: Stack(
            fit: StackFit.expand,
            children: [
              const AppBackdrop(),
              Column(
                children: [
                  const TopNav(current: 'live', background: kTileGradient),
                  Expanded(
                    child: _error != null && _groups.isEmpty
                        ? Center(
                            child: Text(
                              _error!,
                              style: const TextStyle(color: Colors.white),
                            ),
                          )
                        : Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 28,
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                Expanded(flex: 30, child: _buildGroups()),
                                Expanded(flex: 32, child: _buildChannels()),
                                Expanded(flex: 38, child: _buildPreview()),
                              ],
                            ),
                          ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildGroups() {
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 8, 0, 12),
      decoration: BoxDecoration(
        gradient: kTileGradient,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: _loadingGroups
          ? const Center(child: CircularProgressIndicator(color: kAccent))
          : LayoutBuilder(
              builder: (context, constraints) {
                // 12 bouquets visible, with room for a gap between names.
                final extent = ((constraints.maxHeight - 8) / 12).clamp(
                  24.0,
                  52.0,
                );
                return ListView.builder(
                  padding: const EdgeInsets.symmetric(vertical: 6),
                  itemExtent: extent,
                  itemCount: _groups.length,
                  itemBuilder: (ctx, i) {
                    final group = _groups[i];
                    return _GroupTile(
                      category: group,
                      selected: group.id == _groupId,
                      autofocus: i == 0,
                      onTap: () => _selectGroup(group.id),
                    );
                  },
                );
              },
            ),
    );
  }

  Widget _buildChannels() {
    return Container(
      margin: const EdgeInsets.fromLTRB(2, 8, 0, 12),
      decoration: BoxDecoration(
        gradient: kTileGradient,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          Container(
            height: 28,
            padding: const EdgeInsets.only(left: 12, right: 6),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: Colors.white10)),
            ),
            child: Row(
              children: [
                Text(
                  S.of(context).t('live.channels'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                const Spacer(),
                _PageButton(label: 'CH−', onTap: () => _pageChannels(-1)),
                const SizedBox(width: 4),
                _PageButton(label: 'CH+', onTap: () => _pageChannels(1)),
              ],
            ),
          ),
          Expanded(
            child: _loadingItems && _items.isEmpty
                ? const Center(child: CircularProgressIndicator(color: kAccent))
                : LayoutBuilder(
                    builder: (context, constraints) {
                      // 12 channels visible, with a gap between rows.
                      final extent = (constraints.maxHeight / 12).clamp(
                        22.0,
                        52.0,
                      );
                      final logoSize = extent >= 38
                          ? 28.0
                          : (extent - 10).clamp(14.0, 28.0);
                      return ListView.builder(
                        controller: _scroll,
                        itemExtent: extent,
                        itemCount: _items.length + (_hasMore ? 1 : 0),
                        itemBuilder: (ctx, i) {
                          if (i >= _items.length) {
                            return const Center(
                              child: SizedBox(
                                width: 16,
                                height: 16,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                  color: kAccent,
                                ),
                              ),
                            );
                          }
                          final item = _items[i];
                          return _ChannelTile(
                            item: item,
                            selected: _selected?.id == item.id,
                            focusNode: i == 0 ? _firstChannelFocus : null,
                            logoSize: logoSize,
                            onFocus: () => _selectItem(item),
                            onTap: () => _onChannelOk(item, i),
                          );
                        },
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildPreview() {
    final item = _selected;
    final showVideo = _miniUrl != null && !_previewFailed;
    return Container(
      margin: const EdgeInsets.fromLTRB(2, 8, 12, 12),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        gradient: kTileGradient,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.3),
            blurRadius: 12,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: item == null
          ? const Center(
              child: Icon(
                Icons.live_tv_rounded,
                color: Colors.white12,
                size: 70,
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Small 16:9 Mini TV window.
                AspectRatio(
                  aspectRatio: 16 / 9,
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      color: Colors.black,
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          if (item.logo.isNotEmpty)
                            Center(
                              child: Padding(
                                padding: const EdgeInsets.all(22),
                                child: Image.network(
                                  item.logo,
                                  fit: BoxFit.contain,
                                  cacheWidth: 240,
                                  errorBuilder: (_, __, ___) => const Icon(
                                    Icons.live_tv_rounded,
                                    color: Colors.white24,
                                    size: 42,
                                  ),
                                ),
                              ),
                            )
                          else
                            const Center(
                              child: Icon(
                                Icons.live_tv_rounded,
                                color: Colors.white24,
                                size: 42,
                              ),
                            ),
                          if (showVideo)
                            ValueListenableBuilder<bool>(
                              valueListenable: PlaybackService.I.fullscreen,
                              builder: (context, fullscreen, _) => fullscreen
                                  ? const ColoredBox(color: Colors.black)
                                  : _miniVideo,
                            ),
                          if (showVideo && _previewBuffering)
                            const Center(
                              child: SizedBox(
                                width: 26,
                                height: 26,
                                child: CircularProgressIndicator(
                                  color: kAccent,
                                  strokeWidth: 2.5,
                                ),
                              ),
                            ),
                          Positioned(
                            top: 6,
                            left: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: kRed,
                                borderRadius: BorderRadius.circular(3),
                              ),
                              child: const Text(
                                'LIVE',
                                style: TextStyle(
                                  color: Colors.white,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w800,
                                  letterSpacing: 1,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Channel name directly below the mini window.
                Text(
                  item.name,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    height: 1.15,
                  ),
                ),
                const SizedBox(height: 10),
                // EPG from the provider (when available).
                Expanded(child: _buildEpg(item)),
                const SizedBox(height: 8),
                Row(
                  children: [
                    Expanded(
                      child: _PreviewButton(
                        label: S.of(context).t('live.watch'),
                        onTap: () {
                          final index = _items.indexWhere(
                            (e) => e.id == item.id,
                          );
                          if (index >= 0) _play(index);
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: _PreviewButton(
                        label: S.of(context).t('live.search'),
                        onTap: () => Navigator.pushNamed(context, '/search'),
                      ),
                    ),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildEpg(MediaItem item) {
    if (_epg.isEmpty) {
      return Container(
        width: double.infinity,
        alignment: Alignment.topLeft,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          gradient: kTileGradient,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
        ),
        child: Text(
          S.of(context).t('live.noProgramme'),
          style: const TextStyle(color: Colors.white, fontSize: 12),
        ),
      );
    }
    final now = DateTime.now();
    EpgEntry? current;
    for (final entry in _epg) {
      if (entry.nowPlaying) {
        current = entry;
        break;
      }
    }
    if (current == null) {
      for (final entry in _epg) {
        final start = entry.start;
        final end = entry.end;
        if (start != null &&
            end != null &&
            now.isAfter(start) &&
            now.isBefore(end)) {
          current = entry;
          break;
        }
      }
    }
    current ??= _epg.first;
    final index = _epg.indexOf(current);
    final next = index + 1 < _epg.length ? _epg[index + 1] : null;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        gradient: kTileGradient,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white.withValues(alpha: 0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Text(
                S.of(context).t('live.now'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                ),
              ),
              const Spacer(),
              Text(
                current.timeRange,
                style: const TextStyle(color: kAccent, fontSize: 10),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            current.title,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w800,
              height: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(2),
            child: LinearProgressIndicator(
              value: current.progress ?? 0,
              minHeight: 3,
              backgroundColor: Colors.white.withValues(alpha: 0.14),
              valueColor: const AlwaysStoppedAnimation(kRed),
            ),
          ),
          if (next != null && next.title.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              S.of(context).t('live.next', {'title': next.title}),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
        ],
      ),
    );
  }
}

class _GroupTile extends StatefulWidget {
  final MediaCategory category;
  final bool selected;
  final bool autofocus;
  final VoidCallback onTap;

  const _GroupTile({
    required this.category,
    required this.selected,
    required this.onTap,
    this.autofocus = false,
  });

  @override
  State<_GroupTile> createState() => _GroupTileState();
}

class _GroupTileState extends State<_GroupTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.selected || _focused;
    return TvFocus(
      autofocus: widget.autofocus,
      onActivate: widget.onTap,
      onFocusChange: (f) {
        setState(() => _focused = f);
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          // A real gap between bouquet names instead of packed rows.
          margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.22)
                : widget.selected
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: _focused ? kAccent : Colors.transparent,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Expanded(
                child: Stack(
                  children: [
                    // Stroke (outline) for bold effect
                    Text(
                      widget.category.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        foreground: Paint()
                          ..style = PaintingStyle.stroke
                          ..strokeWidth = 1.2
                          ..color = Colors.black,
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                    // Fill
                    Text(
                      widget.category.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: _focused ? Colors.white : (Colors.white),
                        fontSize: 14,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ],
                ),
              ),
              if (widget.category.count > 0)
                Padding(
                  padding: const EdgeInsets.only(left: 10),
                  child: Text(
                    '${widget.category.count}',
                    style: TextStyle(color: Colors.white, fontSize: 10.5),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ChannelTile extends StatefulWidget {
  final MediaItem item;
  final bool selected;
  final double logoSize;
  final FocusNode? focusNode;
  final VoidCallback onFocus;
  final VoidCallback onTap;

  const _ChannelTile({
    required this.item,
    required this.selected,
    required this.onFocus,
    required this.onTap,
    this.logoSize = 28,
    this.focusNode,
  });

  @override
  State<_ChannelTile> createState() => _ChannelTileState();
}

class _ChannelTileState extends State<_ChannelTile> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = widget.selected || _focused;
    return TvFocus(
      focusNode: widget.focusNode,
      onActivate: widget.onTap,
      onFocusChange: (f) {
        setState(() => _focused = f);
        if (f) widget.onFocus();
      },
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          color: highlighted
              ? Colors.white.withValues(alpha: 0.18)
              : Colors.transparent,
          // Vertical gap so channel names never touch each other.
          margin: const EdgeInsets.symmetric(horizontal: 5, vertical: 4),
          padding: const EdgeInsets.symmetric(horizontal: 9),
          child: Row(
            children: [
              SizedBox(
                width: 34,
                child: Text(
                  widget.item.num > 0 ? '${widget.item.num}' : '',
                  style: const TextStyle(color: Colors.white, fontSize: 11.5),
                ),
              ),
              const SizedBox(width: 8),
              SizedBox(
                width: widget.logoSize,
                height: widget.logoSize,
                child: widget.item.logo.isNotEmpty
                    ? Image.network(
                        widget.item.logo,
                        fit: BoxFit.contain,
                        cacheWidth: 56,
                        errorBuilder: (_, __, ___) => const SizedBox.shrink(),
                      )
                    : const SizedBox.shrink(),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  widget.item.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14.5,
                    fontWeight: highlighted ? FontWeight.w900 : FontWeight.w800,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewButton extends StatefulWidget {
  final String label;
  final VoidCallback? onTap;

  const _PreviewButton({required this.label, required this.onTap});

  @override
  State<_PreviewButton> createState() => _PreviewButtonState();
}

class _PreviewButtonState extends State<_PreviewButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      onActivate: widget.onTap,
      onFocusChange: (f) => setState(() => _focused = f),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 140),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            gradient: kTileGradient,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.28),
              width: _focused ? 2 : 1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.3),
                blurRadius: 8,
                offset: const Offset(0, 4),
              ),
            ],
          ),
          child: Text(
            widget.label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 14,
              fontWeight: FontWeight.w800,
            ),
          ),
        ),
      ),
    );
  }
}

/// Compact CH- / CH+ button that pages the channel list by one viewport.
class _PageButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PageButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: kAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: kAccent.withValues(alpha: 0.45)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: kAccent,
            fontSize: 10,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }
}
