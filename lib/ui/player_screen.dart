import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';

import '../data/history_service.dart';
import '../data/models.dart';
import '../data/playback.dart';
import '../data/player_engine.dart';
import '../data/resume_service.dart';
import '../l10n/app_localizations.dart';
import '../data/repository.dart';
import '../data/stalker_api.dart';
import '../data/subtitles.dart';
import '../theme.dart';
import 'back_guard.dart';
import 'tv_focus.dart';

class PlayerScreen extends StatefulWidget {
  final List<MediaItem> items;
  final int initialIndex;
  final MediaKind kind;
  final String groupName;
  final String? groupId;

  /// For a series episode, the parent series is recorded in "Derniers lus" so
  /// reopening it shows the episode list again instead of a single episode.
  final MediaItem? historyItem;

  const PlayerScreen({
    super.key,
    required this.items,
    required this.initialIndex,
    required this.kind,
    this.groupName = '',
    this.groupId,
    this.historyItem,
  });

  @override
  State<PlayerScreen> createState() => _PlayerScreenState();
}

class _PlayerScreenState extends State<PlayerScreen> with WidgetsBindingObserver {
  static const int _pageSize = 15;

  late final AppPlayerEngine _player;
  late final Widget _video;
  late int _index;
  late List<MediaItem> _items;
  late String _playingGroupId;
  late String _playingGroupName;

  final FocusNode _focusNode = FocusNode(debugLabel: 'player');
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _controlsVisible = true;
  bool _buffering = true;
  bool _playing = true;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  bool _scrubbing = false;
  double _scrubFraction = 0;
  DateTime _lastScrubSeek = DateTime.fromMillisecondsSinceEpoch(0);
  int? _videoWidth;
  int? _videoHeight;
  int? _videoBitrate;

  // Resume: once the engine knows the duration, ask the user whether to start
  // again or continue. The position is also saved every few seconds and on
  // exit. Media that reached the end clears its saved position.
  Duration? _pendingResume;
  int _resumeToken = 0;
  bool _resumeDialogOpen = false;
  bool _resumeRestorePlayback = false;
  bool _playbackCompleted = false;
  DateTime _lastResumeSave = DateTime.fromMillisecondsSinceEpoch(0);

  List<EpgEntry> _epg = const [];
  int _epgToken = 0;
  int _openToken = 0;

  bool _channelListOpen = false;
  int _channelListIndex = 0;

  List<MediaCategory> _groups = const [];
  List<MediaItem> _browseItems = const [];
  String _browseGroupId = '';
  String _browseGroupName = '';
  int _groupIndex = 0;
  bool _groupsOpen = false;
  bool _listFocusGroups = false;
  bool _loadingBrowse = false;
  bool _countsLoaded = false;
  int _armedIndex = -1;

  /// Smooth touch scrolling for the player side panels, like the Live screen.
  final ScrollController _channelScroll = ScrollController();
  final ScrollController _groupScroll = ScrollController();
  double _sideRowHeight = 32;

  // Audio / subtitle settings panel.
  bool _settingsOpen = false;
  int _settingsIndex = 0;

  // Aspect-ratio picker opened by the ÉCRAN button.
  bool _ratioMenuOpen = false;
  int _ratioIndex = 0;
  final ScrollController _ratioScroll = ScrollController();

  /// Focus target for the movie / episode timeline inside the info bar.
  static const int _timelineFocus = -2;

  /// The ±10 s buttons keep their 10 s step; the timeline itself moves in
  /// 30 s jumps so a long movie can be navigated with fewer presses.
  static const int _seekStep = 10;
  static const int _timelineSeekStep = 30;

  // D-pad focus inside the bottom info bar:
  // -1 = video, -2 = timeline, 0 = -10 s, 1 = play/pause, 2 = +10 s,
  // series: 3 = previous episode, 4 = next episode,
  // then audio / subtitles and screen size.
  int _infoFocus = -1;
  late ScreenMode _screenMode;
  List<AppTrack> _settingsAudio = const [];
  List<AppTrack> _settingsSubs = const [];
  AppTrack? _currentAudio;
  AppTrack? _currentSubtitle;
  final ScrollController _settingsScroll = ScrollController();

  // Automatic subtitle download state.
  int _subtitleToken = 0;
  bool _subtitleChosenByUser = false;

  DateTime _now = DateTime.now();
  Timer? _hideTimer;
  Timer? _clockTimer;

  bool get _isLive => widget.kind == MediaKind.live;

  /// Only series episodes show previous / next buttons in the info bar.
  /// Movies keep the bar focused on playback, the timeline, audio/subs and
  /// the screen mode. Live TV keeps its own channel zapping controls.
  bool get _showEpisodeNav =>
      widget.kind == MediaKind.series && _items.length > 1;
  int get _settingsFocus => _showEpisodeNav ? 5 : 3;
  int get _modeFocus => _showEpisodeNav ? 6 : 4;
  int get _infoFocusMax => _showEpisodeNav ? 6 : 4;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    WidgetsBinding.instance.addObserver(this);
    // Re-apply immersive mode: the status/navigation bars can come back after
    // the Live screen and would shrink the full-screen video.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    SystemChrome.setSystemUIOverlayStyle(
      const SystemUiOverlayStyle(
        statusBarColor: Colors.transparent,
        systemNavigationBarColor: Colors.transparent,
        statusBarIconBrightness: Brightness.light,
        systemNavigationBarIconBrightness: Brightness.light,
      ),
    );
    _index = widget.initialIndex;
    _items = List<MediaItem>.of(widget.items);
    _playingGroupId = widget.groupId ?? '';
    _playingGroupName = widget.groupName;
    _screenMode = PlayerEngineService.I.screenMode.value;
    // Safety net for phones (18:9..21:9): a legacy AUTO/FIT default leaves wide
    // black bands, so upgrade it to PLEIN on tall panels.
    final views = WidgetsBinding.instance.platformDispatcher.views;
    final tall = views.isNotEmpty &&
        views.first.physicalSize.shortestSide > 0 &&
        views.first.physicalSize.longestSide /
                views.first.physicalSize.shortestSide >=
            1.9;
    if (tall && _isLive && _screenMode != ScreenMode.full) {
      _screenMode = ScreenMode.full;
      unawaited(PlayerEngineService.I.saveScreenMode(_screenMode));
    } else if (tall &&
        (_screenMode == ScreenMode.auto || _screenMode == ScreenMode.fit)) {
      _screenMode = ScreenMode.full;
      unawaited(PlayerEngineService.I.saveScreenMode(_screenMode));
    }
    final firstUrl = _items.isEmpty ? '' : _items[_index].url;
    _player = createPlayerEngine(
      initialUrl: firstUrl,
      deferInitial: StalkerApi.isStalkerUrl(firstUrl),
      forceStereo: StalkerApi.isStalkerUrl(firstUrl),
    );
    _video = _player.video;
    PlaybackService.I.fullscreen.value = true;
    // The Live mini preview always runs on MPV: stop it so the chosen engine
    // does not decode the stream a second time in the background.
    if (_player.kind != PlayerEngineKind.mpv) {
      PlaybackService.I.stopIfCreated();
    }

    _subs.add(
      _player.buffering.listen((value) {
        if (mounted && value != _buffering) setState(() => _buffering = value);
      }),
    );
    _subs.add(
      _player.playing.listen((value) {
        if (mounted && value != _playing) setState(() => _playing = value);
      }),
    );
    _subs.add(
      _player.position.listen((value) {
        if (!mounted || _isLive) return;
        _maybeSaveResume(value);
        // Repaint at most once per second, and never while the info bar is
        // hidden: rebuilding this screen on every player tick made cheap boxes
        // lag.
        if (!_controlsVisible) {
          _position = value;
          return;
        }
        if (value.inSeconds != _position.inSeconds) {
          setState(() => _position = value);
        }
      }),
    );
    _subs.add(
      _player.duration.listen((value) {
        if (!mounted) return;
        final pending = _pendingResume;
        if (pending != null && value > const Duration(seconds: 1)) {
          _pendingResume = null;
          // A saved position longer than the current duration belongs to an
          // older version of the item: ignore it instead of showing a prompt.
          if (pending <= value) _askResume(pending, value);
        }
        // Keep the provider's duration when the stream reports none, so the
        // counter never reverts to --:--.
        if (value <= Duration.zero) return;
        if (!_controlsVisible) {
          _duration = value;
          return;
        }
        if (value.inSeconds != _duration.inSeconds) {
          setState(() => _duration = value);
        }
      }),
    );
    _subs.add(
      _player.width.listen((value) {
        if (mounted && value != _videoWidth) {
          setState(() => _videoWidth = value);
        }
      }),
    );
    _subs.add(
      _player.height.listen((value) {
        if (mounted && value != _videoHeight) {
          setState(() => _videoHeight = value);
        }
      }),
    );
    _subs.add(
      _player.tracks.listen((tracks) {
        if (!mounted) return;
        setState(() {
          _videoBitrate = tracks.videoBitrate;
          _settingsAudio = List<AppTrack>.of(tracks.audio);
          _settingsSubs = List<AppTrack>.of(tracks.subtitle);
          if (_settingsIndex >= _settingsOptionCount) _settingsIndex = 0;
        });
      }),
    );
    _subs.add(
      _player.selection.listen((track) {
        if (!mounted) return;
        if (track.audio?.id == _currentAudio?.id &&
            track.subtitle?.id == _currentSubtitle?.id) {
          return;
        }
        setState(() {
          _currentAudio = track.audio;
          _currentSubtitle = track.subtitle;
        });
      }),
    );
    _subs.add(
      _player.completed.listen((value) {
        if (!value || _isLive || _items.isEmpty) return;
        _playbackCompleted = true;
        unawaited(ResumeService.I.clear(widget.kind, _items[_index]));
        if (_index < _items.length - 1) _next();
      }),
    );

    _open();
    unawaited(_player.setScreenMode(_screenMode));
    _loadFullGroup();
    _loadGroups();
    _restartHideTimer();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      // Some engines emit the duration only once, before the info bar is
      // built, or not at all for a VOD/HLS episode. Polling the live engine
      // state keeps the counter and seeking correct in every case.
      _syncEngineState();
      if (!_controlsVisible) return;
      final now = DateTime.now();
      if (now.minute != _now.minute) setState(() => _now = now);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _hideTimer?.cancel();
    _clockTimer?.cancel();
    _saveResumeNow();
    for (final sub in _subs) {
      sub.cancel();
    }
    // The MPV player is shared with the Live preview: the engine stops it
    // without disposing it.
    PlaybackService.I.fullscreen.value = false;
    _player.dispose();
    _focusNode.dispose();
    _settingsScroll.dispose();
    _channelScroll.dispose();
    _groupScroll.dispose();
    _ratioScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      SystemChrome.setSystemUIOverlayStyle(
        const SystemUiOverlayStyle(
          statusBarColor: Colors.transparent,
          systemNavigationBarColor: Colors.transparent,
          statusBarIconBrightness: Brightness.light,
          systemNavigationBarIconBrightness: Brightness.light,
        ),
      );
    }
  }

  void _open() {
    unawaited(_openCurrent());
  }

  Future<void> _openCurrent() async {
    if (_items.isEmpty) return;
    final index = _index;
    final item = _items[index];
    final openToken = ++_openToken;
    // Invalidate a prompt belonging to the previous episode/movie before the
    // new stream starts. Its callback checks this token and does nothing.
    ++_resumeToken;
    if (_resumeDialogOpen) {
      _resumeDialogOpen = false;
      if (mounted) Navigator.of(context, rootNavigator: true).pop();
    }
    _playbackCompleted = false;
    unawaited(
      HistoryService.I.record(
        widget.kind,
        widget.historyItem ?? item,
        Repository.I.config?.id ?? '',
      ),
    );
    final resume = _isLive ? null : ResumeService.I.entryFor(widget.kind, item);
    setState(() {
      _buffering = true;
      _position = Duration.zero;
      // Prefer the provider's duration when the stream itself does not report
      // one (common for some series episodes), so the counter is never stuck
      // on --:--.
      _duration = _items.isEmpty
          ? Duration.zero
          : (_items[index].duration ?? Duration.zero);
      _videoWidth = null;
      _videoHeight = null;
      _videoBitrate = null;
      _epg = const [];
      _pendingResume = resume?.position;
    });
    var url = item.url;
    if (StalkerApi.isStalkerUrl(url)) {
      try {
        url = await Repository.I.resolveStream(item);
      } catch (_) {
        if (mounted && openToken == _openToken) {
          setState(() => _buffering = false);
        }
        return;
      }
      if (!mounted || openToken != _openToken || index != _index) return;
    }
    final opening = _player.open(url).catchError((_) {});
    if (_isLive) {
      _subtitleToken++;
      _loadEpg(item);
    } else {
      // Search/download while the stream starts, then attach the file once
      // mpv has finished opening the movie.
      _subtitleChosenByUser = false;
      final token = ++_subtitleToken;
      unawaited(_autoSubtitle(item, token, opening));
    }
  }

  Future<void> _autoSubtitle(
    MediaItem item,
    int token,
    Future<void> opening,
  ) async {
    try {
      final result = await SubtitleService.I.downloadFor(
        item,
        kind: widget.kind,
        groupName: widget.groupName,
      );
      if (result == null) return;
      await opening;
      if (!mounted || token != _subtitleToken || _subtitleChosenByUser) return;
      await _player.setSubtitleFile(
        result.path,
        title: S.of(context).t('player.autoProvider', {
          'provider': result.provider,
        }),
        language: result.language,
      );
    } catch (_) {
      // A missing subtitle must never interrupt playback.
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

  /// The Live screen opens the player with the pages it has already loaded.
  /// Fetch the whole category in the background so the UP channel list and
  /// left/right zapping cover every channel of the group.
  Future<void> _loadFullGroup() async {
    final groupId = widget.groupId;
    if (groupId == null || groupId.isEmpty || !_isLive) return;
    try {
      final all = await Repository.I.items(widget.kind, groupId, limit: 100000);
      if (!mounted || all.length <= _items.length) return;
      final currentId = _items.isEmpty ? '' : _items[_index].id;
      setState(() {
        _items = all;
        final newIndex = all.indexWhere((e) => e.id == currentId);
        if (newIndex >= 0) _index = newIndex;
        if (_browseGroupId == _playingGroupId) {
          _browseItems = all;
          if (_channelListIndex >= all.length) _channelListIndex = _index;
        }
      });
      _scheduleReveal();
    } catch (_) {
      // The list simply keeps the items passed by the Live screen.
    }
  }

  Future<void> _loadGroups() async {
    if (!_isLive) return;
    try {
      final groups = await Repository.I.categories(MediaKind.live);
      if (!mounted) return;
      setState(() {
        _groups = groups;
        final i = groups.indexWhere((g) => g.id == _playingGroupId);
        if (i >= 0) _groupIndex = i;
        if (_groupIndex >= groups.length) _groupIndex = 0;
      });
    } catch (_) {
      // Bouquets stay unavailable; the current channel list still works.
    }
  }

  /// Xtream category lists have no channel count: fill it once on demand.
  Future<void> _loadGroupCounts() async {
    if (_countsLoaded || _groups.isEmpty) return;
    try {
      final counts = await Repository.I.categoryCounts(MediaKind.live);
      if (!mounted) return;
      setState(() {
        _countsLoaded = true;
        _groups = [
          for (final g in _groups)
            MediaCategory(g.id, g.name, count: counts[g.id] ?? g.count),
        ];
      });
    } catch (_) {
      // Counts stay hidden.
    }
  }

  void _next() {
    if (_index >= _items.length - 1) return;
    _saveResumeNow();
    _closeResumeDialog();
    setState(() => _index++);
    _open();
  }

  void _prev() {
    if (_index <= 0) return;
    _saveResumeNow();
    _closeResumeDialog();
    setState(() => _index--);
    _open();
  }

  /// Writes the current position at most once every five seconds; the final
  /// write also happens on exit and when changing item.
  void _maybeSaveResume(Duration position) {
    final now = DateTime.now();
    if (now.difference(_lastResumeSave).inSeconds < 5) return;
    _lastResumeSave = now;
    unawaited(_saveResume(position));
  }

  void _saveResumeNow() => unawaited(_saveResume(_position));

  Future<void> _saveResume(Duration position) async {
    if (_isLive ||
        _playbackCompleted ||
        _items.isEmpty ||
        position <= Duration.zero) {
      return;
    }
    final item = _items[_index];
    await ResumeService.I.save(widget.kind, item, position, _duration);
  }

  void _closeResumeDialog() {
    if (!_resumeDialogOpen || !mounted) return;
    _resumeDialogOpen = false;
    Navigator.of(context, rootNavigator: true).pop();
  }

  /// Pauses the stream and asks the user whether to continue from the saved
  /// frame or start the movie/episode again. Back dismisses the dialog and is
  /// treated as "start again", so the player is never left stuck.
  void _askResume(Duration at, Duration total) {
    if (!mounted || _resumeDialogOpen || _isLive) return;
    if (at < const Duration(seconds: 8) || at > total) return;
    _resumeDialogOpen = true;
    _resumeRestorePlayback = _player.isPlaying;
    if (_resumeRestorePlayback) unawaited(_player.playOrPause());
    final token = _resumeToken;
    final time = _format(at);
    unawaited(
      showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (_) => _ResumeDialog(time: time),
      ).then((choice) {
        if (!mounted || token != _resumeToken) return;
        _resumeDialogOpen = false;
        unawaited(_player.seek(choice == true ? at : Duration.zero));
        if (_resumeRestorePlayback && !_player.isPlaying) {
          unawaited(_player.playOrPause());
        }
        _showControls();
      }),
    );
  }

  void _toggle() {
    _player.playOrPause();
    _showControls();
  }

  /// On Live TV the OK button must never pause the stream: it only reveals
  /// the info bar (and hides it again when already visible).
  void _toggleLiveControls() {
    if (_controlsVisible) {
      _hideTimer?.cancel();
      setState(() {
        _controlsVisible = false;
        _infoFocus = -1;
      });
    } else {
      setState(() => _controlsVisible = true);
      _restartHideTimer();
    }
  }

  void _seek(int seconds) {
    // Prefer the engine's live position: `_position` can be one tick behind,
    // which made repeated seeks on an episode appear to do nothing.
    var target = _player.currentPosition + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    final total = _player.currentDuration;
    if (total > Duration.zero && target > total) target = total;
    setState(() => _position = target);
    unawaited(_player.seek(target));
    _showControls();
  }

  void _seekToFraction(double fraction) {
    final total = _player.currentDuration;
    if (total <= Duration.zero) return;
    final target = Duration(
      milliseconds: (total.inMilliseconds * fraction).round(),
    );
    setState(() => _position = target);
    unawaited(_player.seek(target));
    _showControls();
  }

  /// Opens the aspect-ratio picker on the mode currently in use.
  void _openRatioMenu() {
    _hideTimer?.cancel();
    setState(() {
      _channelListOpen = false;
      _groupsOpen = false;
      _listFocusGroups = false;
      _settingsOpen = false;
      _ratioMenuOpen = true;
      _ratioIndex = ScreenMode.values.indexOf(_screenMode);
      if (_ratioIndex < 0) _ratioIndex = 0;
      _infoFocus = -1;
      _controlsVisible = true;
    });
    _scrollRatioIntoView();
  }

  void _closeRatioMenu() {
    if (!_ratioMenuOpen) return;
    setState(() => _ratioMenuOpen = false);
    _restartHideTimer();
  }

  void _moveRatio(int delta) {
    setState(() {
      _ratioIndex = (_ratioIndex + delta).clamp(
        0,
        ScreenMode.values.length - 1,
      );
    });
    _scrollRatioIntoView();
  }

  void _applyRatio(int index) {
    final mode = ScreenMode.values[index];
    setState(() {
      _screenMode = mode;
      _ratioMenuOpen = false;
    });
    PlayerEngineService.I.saveScreenMode(mode);
    unawaited(_player.setScreenMode(mode));
    _restartHideTimer();
  }

  void _scrollRatioIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_ratioScroll.hasClients) return;
      final target = (_ratioIndex * 40.0).clamp(
        0.0,
        _ratioScroll.position.maxScrollExtent,
      );
      _ratioScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  /// Runs the info-bar button currently highlighted by the D-pad.
  void _activateInfoFocus() {
    // OK on the timeline is the familiar play / pause shortcut.
    if (_infoFocus == _timelineFocus) {
      _toggle();
      return;
    }
    if (_showEpisodeNav) {
      switch (_infoFocus) {
        case 0:
          _seek(-_seekStep);
        case 1:
          _toggle();
        case 2:
          _seek(_seekStep);
        case 3:
          _prev();
        case 4:
          _next();
        case 5:
          _openSettings();
        case 6:
          _openRatioMenu();
      }
    } else {
      switch (_infoFocus) {
        case 0:
          _seek(-_seekStep);
        case 1:
          _toggle();
        case 2:
          _seek(_seekStep);
        case 3:
          _openSettings();
        case 4:
          _openRatioMenu();
      }
    }
    _restartHideTimer();
  }

  void _showControls() {
    _now = DateTime.now();
    if (!_controlsVisible) {
      setState(() => _controlsVisible = true);
    }
    _restartHideTimer();
  }

  /// Touch devices cannot always tap the native video view to dismiss the
  /// overlay, so the info bar and the top button call this directly.
  void _hideControls() {
    _hideTimer?.cancel();
    if (!_controlsVisible) return;
    setState(() {
      _controlsVisible = false;
      _infoFocus = -1;
    });
  }

  /// Reads position and duration directly from the engine once a second.
  /// This is what makes an episode show `2:40 / 42:00` instead of `--:--`
  /// when its duration stream was missed or never emitted.
  void _syncEngineState() {
    if (_isLive || _items.isEmpty) return;
    final position = _player.currentPosition;
    var duration = _player.currentDuration;
    if (duration <= Duration.zero && _items.isNotEmpty) {
      duration = _items[_index].duration ?? Duration.zero;
    }

    final pending = _pendingResume;
    if (pending != null && duration > const Duration(seconds: 1)) {
      _pendingResume = null;
      if (pending <= duration) _askResume(pending, duration);
    }

    if (position == _position && duration == _duration) return;
    if (!_controlsVisible) {
      _position = position;
      _duration = duration;
      return;
    }
    setState(() {
      _position = position;
      _duration = duration;
    });
  }

  void _restartHideTimer() {
    _hideTimer?.cancel();
    // Info bar shows briefly (3s) on Live TV, then hides until recalled.
    final seconds = _isLive ? 3 : 8;
    _hideTimer = Timer(Duration(seconds: seconds), () {
      if (!mounted) return;
      // Keep the bar up while a control of the bar owns the D-pad.
      if (_settingsOpen || _infoFocus != -1) return;
      setState(() => _controlsVisible = false);
    });
  }

  void _openChannelList() {
    if (!_isLive || _items.isEmpty) return;
    _hideTimer?.cancel();
    setState(() {
      _channelListIndex = _index;
      _channelListOpen = true;
      _settingsOpen = false;
      _infoFocus = -1;
      _controlsVisible = true;
      _groupsOpen = false;
      _listFocusGroups = false;
      _browseItems = List<MediaItem>.of(_items);
      _browseGroupId = _playingGroupId;
      _browseGroupName = _playingGroupName;
      _armedIndex = -1;
      final i = _groups.indexWhere((g) => g.id == _playingGroupId);
      if (i >= 0) _groupIndex = i;
    });
    _scheduleReveal();
    if (_groups.isEmpty) _loadGroups();
  }

  void _closeChannelList() {
    if (!_channelListOpen) return;
    setState(() {
      _channelListOpen = false;
      _groupsOpen = false;
      _listFocusGroups = false;
      _armedIndex = -1;
    });
    _restartHideTimer();
  }

  Future<void> _showGroups() async {
    if (_groups.isEmpty) {
      await _loadGroups();
      if (!mounted) return;
    }
    setState(() {
      _groupsOpen = true;
      _listFocusGroups = true;
    });
    _scheduleReveal();
    _loadGroupCounts();
  }

  void _hideGroups() {
    setState(() {
      _groupsOpen = false;
      _listFocusGroups = false;
      _armedIndex = -1;
    });
    _scheduleReveal();
  }

  // ---------------------------------------------------------------------------
  // Audio / subtitle settings
  // ---------------------------------------------------------------------------

  int get _settingsOptionCount =>
      _settingsAudio.length + 1 + _settingsSubs.length;

  String _trackName(String? title, String? language, String fallback) {
    if (title != null && title.trim().isNotEmpty) return title.trim();
    if (language != null && language.trim().isNotEmpty) {
      return language.trim().toUpperCase();
    }
    return fallback;
  }

  String _audioLabel(AppTrack track, int index) {
    final name = _trackName(
      track.title,
      track.language,
      S.of(context).t('player.track', {'number': '${index + 1}'}),
    );
    final extras = <String>[];
    if (track.title != null &&
        track.title!.isNotEmpty &&
        track.language != null &&
        track.language!.isNotEmpty) {
      extras.add(track.language!.toUpperCase());
    }
    if (track.codec != null && track.codec!.isNotEmpty) {
      extras.add(track.codec!.toUpperCase());
    }
    return extras.isEmpty ? name : '$name · ${extras.join(' · ')}';
  }

  String _subtitleLabel(AppTrack track, int index) {
    return _trackName(
      track.title,
      track.language,
      S.of(context).t('player.subtitleTrack', {'number': '${index + 1}'}),
    );
  }

  AppTrack? _audioAt(int index) => index >= 0 && index < _settingsAudio.length
      ? _settingsAudio[index]
      : null;

  AppTrack? _subtitleAt(int index) {
    if (index == _settingsAudio.length) return AppTrack.off;
    final j = index - _settingsAudio.length - 1;
    return j >= 0 && j < _settingsSubs.length ? _settingsSubs[j] : null;
  }

  bool _audioSelected(AppTrack track) => track.id == _currentAudio?.id;

  bool _subtitlesOffSelected() =>
      _currentSubtitle == null || _currentSubtitle!.id == 'no';

  void _openSettings() {
    _hideTimer?.cancel();
    final current = _settingsAudio.indexWhere((t) => t.id == _currentAudio?.id);
    var index = current >= 0 ? current : 0;
    if (index >= _settingsOptionCount) index = 0;
    setState(() {
      _channelListOpen = false;
      _groupsOpen = false;
      _listFocusGroups = false;
      _settingsOpen = true;
      _infoFocus = -1;
      _controlsVisible = true;
      _settingsIndex = index;
    });
    _scrollSettingsIntoView();
  }

  void _closeSettings() {
    if (!_settingsOpen) return;
    setState(() => _settingsOpen = false);
    _restartHideTimer();
  }

  void _toggleSettings() {
    if (_settingsOpen) {
      _closeSettings();
    } else {
      _openSettings();
    }
  }

  void _moveSettings(int delta) {
    if (_settingsOptionCount == 0) return;
    setState(() {
      _settingsIndex = (_settingsIndex + delta).clamp(
        0,
        _settingsOptionCount - 1,
      );
    });
    _scrollSettingsIntoView();
  }

  void _scrollSettingsIntoView() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || !_settingsScroll.hasClients) return;
      final target = (_settingsIndex * 34.0).clamp(
        0.0,
        _settingsScroll.position.maxScrollExtent,
      );
      _settingsScroll.animateTo(
        target,
        duration: const Duration(milliseconds: 140),
        curve: Curves.easeOut,
      );
    });
  }

  Future<void> _applySettingsOption(int index) async {
    final audio = _audioAt(index);
    if (audio != null) {
      await _player.setAudioTrack(audio);
      return;
    }
    final subtitle = _subtitleAt(index);
    if (subtitle != null) {
      // Once the viewer picks a track (including "off"), the automatic
      // download must not replace it.
      _subtitleChosenByUser = true;
      await _player.setSubtitleTrack(subtitle);
    }
  }

  /// Scrollable side list used by the player overlay. It behaves like the
  /// channel list of the Live screen: touch scrolling is handled by the
  /// ListView itself (natural direction, kinetic scrolling), while the remote
  /// keeps moving [_channelListIndex] / [_groupIndex] and the list follows.
  Widget _scrollableColumn({
    required int itemCount,
    required ScrollController controller,
    required Widget Function(int index, double rowHeight) itemBuilder,
  }) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final rowHeight = (constraints.maxHeight / _pageSize).clamp(26.0, 72.0);
        _sideRowHeight = rowHeight;
        return ListView.builder(
          controller: controller,
          itemExtent: rowHeight,
          padding: EdgeInsets.zero,
          physics: const ClampingScrollPhysics(),
          itemCount: itemCount,
          itemBuilder: (context, i) => itemBuilder(i, rowHeight),
        );
      },
    );
  }

  /// Keeps the remote-selected row visible after a DPAD move or CH+ / CH-.
  void _revealSelected() {
    final controller = _listFocusGroups ? _groupScroll : _channelScroll;
    final index = _listFocusGroups ? _groupIndex : _channelListIndex;
    if (!controller.hasClients) return;
    final position = controller.position;
    final rowHeight = position.viewportDimension / _pageSize;
    final top = index * rowHeight;
    final bottom = top + rowHeight;
    double? target;
    if (top < position.pixels) {
      target = top;
    } else if (bottom > position.pixels + position.viewportDimension) {
      target = bottom - position.viewportDimension;
    }
    if (target == null) return;
    controller.animateTo(
      target.clamp(0.0, position.maxScrollExtent),
      duration: const Duration(milliseconds: 180),
      curve: Curves.easeOutCubic,
    );
  }

  void _scheduleReveal() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _revealSelected();
    });
  }

  /// `1-15 / 71` label that follows the touch scroll position instead of only
  /// the remote selection.
  Widget _rangeLabel(ScrollController controller, int count) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        var first = 1;
        var last = count;
        if (count > 0 && controller.hasClients) {
          final position = controller.position;
          final row = _sideRowHeight > 0 ? _sideRowHeight : 32.0;
          first = (position.pixels / row).floor() + 1;
          first = first.clamp(1, count);
          last = (first + _pageSize - 1).clamp(0, count);
        }
        return Text(
          count == 0 ? '0 / 0' : '$first-$last / $count',
          style: const TextStyle(color: Colors.white, fontSize: 10.5),
        );
      },
    );
  }

  void _moveList(int delta) {
    if (_listFocusGroups) {
      if (_groups.isEmpty) return;
      setState(() {
        _groupIndex = (_groupIndex + delta).clamp(0, _groups.length - 1);
        _armedIndex = -1;
      });
      _scheduleReveal();
      return;
    }
    if (_browseItems.isEmpty) return;
    setState(() {
      _channelListIndex = (_channelListIndex + delta).clamp(
        0,
        _browseItems.length - 1,
      );
      _armedIndex = -1;
    });
    _scheduleReveal();
  }

  /// CH+ / CH- jump the highlighted overlay list a whole page at a time:
  /// the 15 channels currently on screen are replaced by the next/previous 15.
  void _jumpPage(int direction) {
    if (_channelListOpen && _listFocusGroups) {
      if (_groups.isEmpty) return;
      setState(() {
        _groupIndex = (_groupIndex + direction * _pageSize).clamp(
          0,
          _groups.length - 1,
        );
        _armedIndex = -1;
      });
      _scheduleReveal();
      return;
    }
    if (_browseItems.isEmpty) return;
    setState(() {
      _channelListIndex = (_channelListIndex + direction * _pageSize).clamp(
        0,
        _browseItems.length - 1,
      );
      _armedIndex = -1;
    });
    _scheduleReveal();
  }

  Future<void> _selectBrowseGroup(int index) async {
    if (index < 0 || index >= _groups.length) return;
    final group = _groups[index];
    setState(() {
      _groupIndex = index;
      _browseGroupId = group.id;
      _browseGroupName = group.name;
      _browseItems = const [];
      _channelListIndex = 0;
      _armedIndex = -1;
      _loadingBrowse = true;
      // The channel list takes the place of the bouquet list while loading.
      _groupsOpen = false;
      _listFocusGroups = false;
    });
    try {
      final items = await Repository.I.items(
        MediaKind.live,
        group.id,
        limit: 100000,
      );
      if (!mounted) return;
      setState(() {
        _browseItems = items;
        _channelListIndex = 0;
        _loadingBrowse = false;
        _listFocusGroups = _groupsOpen;
      });
      _scheduleReveal();
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingBrowse = false);
    }
  }

  void _onChannelOk() {
    if (_browseItems.isEmpty || _loadingBrowse) return;
    // Second OK on the same channel: hide the overlay and watch fullscreen.
    if (_armedIndex == _channelListIndex) {
      _hideTimer?.cancel();
      setState(() {
        _channelListOpen = false;
        _groupsOpen = false;
        _listFocusGroups = false;
        _armedIndex = -1;
        _controlsVisible = false;
      });
      return;
    }
    final playingId = _items.isEmpty ? '' : _items[_index].id;
    if (_browseItems[_channelListIndex].id == playingId) {
      // Already on air: the first OK just arms the channel.
      setState(() => _armedIndex = _channelListIndex);
      return;
    }
    _tuneFromBrowse();
  }

  /// Play the highlighted channel but keep the overlay visible: the second OK
  /// hides it. Opening the stream here lets the user preview channels in place.
  void _tuneFromBrowse() {
    if (_browseItems.isEmpty) return;
    final selected = _channelListIndex.clamp(0, _browseItems.length - 1);
    final newItems = List<MediaItem>.of(_browseItems);
    _hideTimer?.cancel();
    setState(() {
      _items = newItems;
      _index = selected;
      _playingGroupId = _browseGroupId;
      _playingGroupName = _browseGroupName;
      _armedIndex = _channelListIndex;
      _controlsVisible = true;
    });
    _open();
  }

  void _activateListEntry() {
    if (_listFocusGroups) {
      _selectBrowseGroup(_groupIndex);
    } else {
      _onChannelOk();
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }
    final key = event.logicalKey;
    final wasVisible = _controlsVisible;

    // The aspect-ratio picker owns the D-pad while it is open.
    if (_ratioMenuOpen) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveRatio(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveRatio(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.gameButtonA) {
        _applyRatio(_ratioIndex);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.escape ||
          key == LogicalKeyboardKey.goBack) {
        _closeRatioMenu();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // While the audio / subtitle panel is open, D-pad picks a track.
    if (_settingsOpen) {
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveSettings(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveSettings(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.gameButtonA) {
        _applySettingsOption(_settingsIndex);
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // While the overlay is open the D-pad navigates bouquets and channels.
    if (_channelListOpen) {
      if (key == LogicalKeyboardKey.channelUp) {
        _jumpPage(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.channelDown) {
        _jumpPage(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        _moveList(-1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        _moveList(1);
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        if (!_listFocusGroups) _showGroups();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.gameButtonA) {
        _activateListEntry();
        return KeyEventResult.handled;
      }
      return KeyEventResult.handled;
    }

    // The VOD timeline owns LEFT/RIGHT while it is highlighted: each press
    // moves the movie or episode forward / backward by 30 seconds. DOWN then
    // hands the D-pad to the Play button.
    if (_infoFocus == _timelineFocus) {
      if (!_isLive) {
        if (key == LogicalKeyboardKey.arrowLeft) {
          _seek(-_timelineSeekStep);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowRight) {
          _seek(_timelineSeekStep);
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowDown) {
          setState(() => _infoFocus = 1);
          _restartHideTimer();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.arrowUp) {
          setState(() => _infoFocus = -1);
          _restartHideTimer();
          return KeyEventResult.handled;
        }
        if (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.gameButtonA) {
          _activateInfoFocus();
          return KeyEventResult.handled;
        }
      }
      return KeyEventResult.handled;
    }

    // The bottom info bar owns the D-pad while one of its buttons is focused.
    if (_infoFocus >= 0) {
      if (key == LogicalKeyboardKey.select ||
          key == LogicalKeyboardKey.enter ||
          key == LogicalKeyboardKey.numpadEnter ||
          key == LogicalKeyboardKey.gameButtonA) {
        _activateInfoFocus();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowUp) {
        // VOD: UP from the playback row returns to the timeline; UP from the
        // audio / screen row returns to Play. UP above that shows the video.
        if (_isLive) {
          setState(() => _infoFocus = -1);
        } else if (_infoFocus <= 2) {
          setState(() => _infoFocus = _timelineFocus);
        } else {
          setState(() => _infoFocus = 1);
        }
        _restartHideTimer();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowLeft) {
        // VOD: LEFT/RIGHT navigate between the bar controls, wrapping around
        // so Audio/Subs and Screen stay one press away from Play.
        if (_isLive) {
          if (_infoFocus > 3) setState(() => _infoFocus -= 1);
        } else {
          setState(
            () => _infoFocus = _infoFocus <= 0 ? _infoFocusMax : _infoFocus - 1,
          );
        }
        _restartHideTimer();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowRight) {
        if (_isLive) {
          if (_infoFocus < _infoFocusMax) setState(() => _infoFocus += 1);
        } else {
          setState(
            () => _infoFocus = _infoFocus >= _infoFocusMax ? 0 : _infoFocus + 1,
          );
        }
        _restartHideTimer();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.arrowDown) {
        // VOD: DOWN from the playback row reaches Audio/Subs (then Screen),
        // and DOWN from the lower row returns to the video.
        if (!_isLive) {
          setState(() => _infoFocus = _infoFocus <= 2 ? _settingsFocus : -1);
        }
        _restartHideTimer();
        return KeyEventResult.handled;
      }
      setState(() => _infoFocus = -1);
    }

    // CH+ / CH- open the overlay on the next/previous page of channels.
    if (_isLive &&
        (key == LogicalKeyboardKey.channelUp ||
            key == LogicalKeyboardKey.channelDown)) {
      final forward = key == LogicalKeyboardKey.channelUp;
      _openChannelList();
      _jumpPage(forward ? 1 : -1);
      return KeyEventResult.handled;
    }

    // On Live TV, OK reveals/hides the info bar instead of pausing.
    if (_isLive &&
        (key == LogicalKeyboardKey.select ||
            key == LogicalKeyboardKey.enter ||
            key == LogicalKeyboardKey.numpadEnter ||
            key == LogicalKeyboardKey.gameButtonA)) {
      _toggleLiveControls();
      return KeyEventResult.handled;
    }

    _showControls();

    // DOWN reaches the info bar: play/pause on VOD, Audio/Subs on Live TV.
    // On Live TV the first DOWN recalls the info bar for 3 s, then it hides
    // automatically. A second DOWN while visible highlights Audio/Subs.
    if (key == LogicalKeyboardKey.arrowDown) {
      if (_isLive) {
        if (!wasVisible) {
          // Recall the info bar: it shows for 3 s then auto-hides.
          _showControls();
        } else {
          setState(() => _infoFocus = 3);
          _restartHideTimer();
        }
      } else {
        // VOD: the first DOWN lands on the timeline, a second DOWN on Play.
        setState(() => _infoFocus = _timelineFocus);
        _restartHideTimer();
      }
      return KeyEventResult.handled;
    }

    // Back is handled by the system Navigator (handling it here too pops two
    // routes and closes the app).
    if (key == LogicalKeyboardKey.select ||
        key == LogicalKeyboardKey.enter ||
        key == LogicalKeyboardKey.mediaPlayPause ||
        key == LogicalKeyboardKey.gameButtonA) {
      _toggle();
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowLeft) {
      _isLive ? _prev() : _seek(-_timelineSeekStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowRight) {
      _isLive ? _next() : _seek(_timelineSeekStep);
      return KeyEventResult.handled;
    }
    if (key == LogicalKeyboardKey.arrowUp) {
      if (_isLive) {
        _openChannelList();
      }
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String _format(Duration duration) {
    final hours = duration.inHours;
    final minutes = duration.inMinutes.remainder(60).toString().padLeft(2, '0');
    final seconds = duration.inSeconds.remainder(60).toString().padLeft(2, '0');
    return hours > 0 ? '$hours:$minutes:$seconds' : '$minutes:$seconds';
  }

  String get _clock {
    final h = _now.hour.toString().padLeft(2, '0');
    final m = _now.minute.toString().padLeft(2, '0');
    return '$h:$m';
  }

  EpgEntry? get _currentProgram {
    if (_epg.isEmpty) return null;
    for (final entry in _epg) {
      if (entry.nowPlaying) return entry;
    }
    final now = DateTime.now();
    for (final entry in _epg) {
      final start = entry.start;
      final end = entry.end;
      if (start != null &&
          end != null &&
          now.isAfter(start) &&
          now.isBefore(end)) {
        return entry;
      }
    }
    return _epg.first;
  }

  EpgEntry? get _nextProgram {
    if (_epg.isEmpty) return null;
    final current = _currentProgram;
    final index = current == null ? 0 : _epg.indexOf(current);
    if (index >= 0 && index + 1 < _epg.length) return _epg[index + 1];
    return null;
  }

  String get _streamInfo {
    final parts = <String>[];
    final width = _videoWidth;
    final height = _videoHeight;
    if (height != null) {
      if (height >= 1900) {
        parts.add('4K');
      } else if (height >= 1000) {
        parts.add('FULL HD');
      } else if (height >= 700) {
        parts.add('HD');
      } else {
        parts.add('SD');
      }
    }
    if (width != null && height != null && width > 0 && height > 0) {
      parts.add('${width}x$height');
    }
    final bitrate = _videoBitrate;
    if (bitrate != null && bitrate > 0) {
      parts.add('${(bitrate / 1000000).toStringAsFixed(1)} Mbps');
    }
    if (parts.isEmpty) {
      parts.add(_isLive ? 'LIVE' : 'VOD');
    }
    return parts.join('  ·  ');
  }

  @override
  Widget build(BuildContext context) {
    final item = _items.isEmpty
        ? const MediaItem(id: '', name: '', url: '')
        : _items[_index];

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        // Ignore the duplicate BACK some TV boxes send.
        if (!BackGuard.allow()) return;
        if (_settingsOpen) {
          _closeSettings();
          return;
        }
        if (_channelListOpen) {
          if (_groupsOpen) {
            _hideGroups();
          } else {
            _closeChannelList();
          }
          return;
        }
        _hideTimer?.cancel();
        _player.stop();
        Navigator.of(context).pop();
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _onKey,
          child: GestureDetector(
            onTap: () {
              if (_settingsOpen) {
                _closeSettings();
                return;
              }
              if (_controlsVisible) {
                setState(() {
                  _controlsVisible = false;
                  _infoFocus = -1;
                });
                _hideTimer?.cancel();
              } else {
                _showControls();
              }
            },
            // Touch equivalents of the TV remote, for Android phones/tablets:
            // swipe up opens the channel list, left/right zaps channels.
            // Null while a side list is open: the list owns the drag gesture,
            // otherwise the parent recogniser steals the swipe and the phone
            // user cannot scroll the channels or bouquets.
            onVerticalDragEnd: (!_isLive || _channelListOpen)
                ? null
                : (details) {
                    if ((details.primaryVelocity ?? 0) < -250) {
                      _openChannelList();
                    }
                  },
            onHorizontalDragEnd: _channelListOpen
                ? null
                : (details) {
                    final v = details.primaryVelocity ?? 0;
                    if (v.abs() < 250) return;
                    if (_isLive) {
                      if (v < 0) {
                        _next();
                      } else {
                        _prev();
                      }
                    } else {
                      // Swipe left/right on a movie or an episode seeks ±10 s.
                      _seek(v < 0 ? _seekStep : -_seekStep);
                    }
                  },
            child: Stack(
              children: [
                Positioned.fill(child: _video),
                // On phones a native video surface (VLC/ExoPlayer) can swallow
                // touches before they reach the outer GestureDetector. This
                // transparent layer sits above the video, so one tap anywhere
                // on the screen always reveals the info bar. It is only
                // present while the bar is hidden and stays below the bars
                // themselves, so every button keeps its own tap.
                if (!_controlsVisible)
                  Positioned.fill(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTap: _showControls,
                    ),
                  ),
                if (_buffering)
                  const Center(
                    child: SizedBox(
                      width: 44,
                      height: 44,
                      child: CircularProgressIndicator(
                        color: kAccent,
                        strokeWidth: 3,
                      ),
                    ),
                  ),
                if (_controlsVisible) _buildTopBar(item),
                if (_controlsVisible && !_channelListOpen) _buildInfoBar(item),
                if (_channelListOpen && _isLive) _buildChannelList(),
                if (_settingsOpen) _buildSettingsPanel(),
                if (_ratioMenuOpen) _buildRatioMenu(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildTopBar(MediaItem item) {
    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: const EdgeInsets.fromLTRB(44, 18, 44, 34),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Colors.black.withValues(alpha: 0.78), Colors.transparent],
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.arrow_back_rounded, color: Colors.white, size: 30),
            const SizedBox(width: 12),
            if (_isLive)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: kRed,
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(
                  S.of(context).t('player.live'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.2,
                  ),
                ),
              ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            Tooltip(
              message: S.of(context).t('player.hideControls'),
              child: GestureDetector(
                onTap: _hideControls,
                child: Container(
                  margin: const EdgeInsets.only(right: 14),
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: Colors.white24),
                  ),
                  child: const Icon(
                    Icons.visibility_off_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                ),
              ),
            ),
            GestureDetector(
              onTap: _toggleSettings,
              child: Container(
                margin: const EdgeInsets.only(right: 14),
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: _settingsOpen
                      ? kAccent.withValues(alpha: 0.20)
                      : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(
                    color: _settingsOpen ? kAccent : Colors.white24,
                  ),
                ),
                child: Icon(
                  Icons.settings_rounded,
                  color: Colors.white,
                  size: 20,
                ),
              ),
            ),
            Text(
              '${_index + 1} / ${_items.length}',
              style: const TextStyle(color: Colors.white, fontSize: 15),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildChannelList() {
    // Single drill-down panel: the bouquet list replaces the channel list and
    // vice versa, using the same red gradient as the rest of the app.
    return Positioned(
      left: 0,
      top: 0,
      bottom: 0,
      width: 360,
      child: Container(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: kTileGradient.begin,
            end: kTileGradient.end,
            colors: [
              kTileTop.withValues(alpha: 0.85),
              kTileBottom.withValues(alpha: 0.85),
            ],
          ),
          borderRadius: const BorderRadius.horizontal(
            right: Radius.circular(9),
          ),
          border: Border(
            right: BorderSide(color: Colors.white.withValues(alpha: 0.16)),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 24,
            ),
          ],
        ),
        child: SafeArea(
          child: _groupsOpen ? _buildGroupPanel() : _buildChannelPanel(),
        ),
      ),
    );
  }

  /// Centred list of every display mode: D-pad or touch picks one.
  Widget _buildRatioMenu() {
    final s = S.of(context);
    final modes = ScreenMode.values;
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closeRatioMenu,
        child: ColoredBox(
          color: Colors.black.withValues(alpha: 0.55),
          child: Center(
            child: GestureDetector(
              onTap: () {},
              child: Container(
                width: 380,
                constraints: BoxConstraints(
                  maxHeight: MediaQuery.of(context).size.height * 0.78,
                ),
                decoration: BoxDecoration(
                  gradient: kTileGradient,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.5),
                      blurRadius: 28,
                    ),
                  ],
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 14, 12, 8),
                      child: Row(
                        children: [
                          const Icon(
                            Icons.aspect_ratio_rounded,
                            color: kAccent,
                            size: 18,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            s.t('player.ratioTitle'),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.1,
                            ),
                          ),
                          const Spacer(),
                          GestureDetector(
                            onTap: _closeRatioMenu,
                            child: const Padding(
                              padding: EdgeInsets.all(4),
                              child: Icon(
                                Icons.close_rounded,
                                color: Colors.white,
                                size: 20,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    Flexible(
                      child: ListView.builder(
                        controller: _ratioScroll,
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 6),
                        itemExtent: 40,
                        itemCount: modes.length,
                        itemBuilder: (ctx, i) {
                          final mode = modes[i];
                          final selected = mode == _screenMode;
                          final focused = i == _ratioIndex;
                          return GestureDetector(
                            onTap: () {
                              setState(() => _ratioIndex = i);
                              _applyRatio(i);
                            },
                            child: Container(
                              margin: const EdgeInsets.symmetric(
                                vertical: 2,
                                horizontal: 4,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              decoration: BoxDecoration(
                                color: focused
                                    ? kAccent.withValues(alpha: 0.22)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: focused ? kAccent : Colors.transparent,
                                  width: 1.5,
                                ),
                              ),
                              child: Row(
                                children: [
                                  Icon(
                                    selected
                                        ? Icons.radio_button_checked_rounded
                                        : Icons.radio_button_unchecked_rounded,
                                    size: 18,
                                    color: selected ? kAccent : Colors.white54,
                                  ),
                                  const SizedBox(width: 10),
                                  Expanded(
                                    child: Text(
                                      mode.label,
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: selected
                                            ? FontWeight.w900
                                            : FontWeight.w700,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(18, 2, 18, 12),
                      child: Text(
                        s.t('player.ratioAll'),
                        style: const TextStyle(
                          color: Colors.white54,
                          fontSize: 10.5,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildSettingsPanel() {
    final audio = _settingsAudio;
    final subs = _settingsSubs;
    final rows = <Widget>[];
    var row = 0;

    rows.add(_settingsSection('AUDIO', audio.length));
    if (audio.isEmpty) {
      rows.add(_settingsEmpty(S.of(context).t('player.noAudio')));
    } else {
      for (var i = 0; i < audio.length; i++) {
        final index = row++;
        rows.add(
          _settingsRow(
            icon: Icons.volume_up_rounded,
            label: _audioLabel(audio[i], i),
            selected: _audioSelected(audio[i]),
            focused: index == _settingsIndex,
            onTap: () {
              setState(() => _settingsIndex = index);
              _applySettingsOption(index);
            },
          ),
        );
      }
    }

    rows.add(
      _settingsSection(S.of(context).t('player.subtitles'), subs.length),
    );
    final offIndex = row++;
    rows.add(
      _settingsRow(
        icon: Icons.subtitles_off_rounded,
        label: S.of(context).t('player.off'),
        selected: _subtitlesOffSelected(),
        focused: offIndex == _settingsIndex,
        onTap: () {
          setState(() => _settingsIndex = offIndex);
          _applySettingsOption(offIndex);
        },
      ),
    );
    for (var i = 0; i < subs.length; i++) {
      final index = row++;
      rows.add(
        _settingsRow(
          icon: Icons.subtitles_rounded,
          label: _subtitleLabel(subs[i], i),
          selected: _currentSubtitle?.id == subs[i].id,
          focused: index == _settingsIndex,
          onTap: () {
            setState(() => _settingsIndex = index);
            _applySettingsOption(index);
          },
        ),
      );
    }

    return Positioned(
      right: 0,
      top: 0,
      bottom: 0,
      width: 380,
      child: Container(
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            begin: Alignment.centerRight,
            end: Alignment.centerLeft,
            colors: [Color(0xFA080812), Color(0xF20B0B18)],
          ),
          border: Border(
            left: BorderSide(color: Colors.white.withValues(alpha: 0.10)),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.5),
              blurRadius: 24,
            ),
          ],
        ),
        child: SafeArea(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(18, 16, 12, 8),
                child: Row(
                  children: [
                    const Icon(
                      Icons.settings_rounded,
                      color: kAccent,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      S.of(context).t('player.settings'),
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 13,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 1.1,
                      ),
                    ),
                    const Spacer(),
                    GestureDetector(
                      onTap: _closeSettings,
                      child: const Padding(
                        padding: EdgeInsets.all(4),
                        child: Icon(
                          Icons.close_rounded,
                          color: Colors.white,
                          size: 20,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 18),
                child: Text(
                  _items.isEmpty ? '' : _items[_index].name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: Colors.white, fontSize: 10.5),
                ),
              ),
              const SizedBox(height: 4),
              Expanded(
                child: ListView(
                  controller: _settingsScroll,
                  padding: const EdgeInsets.only(bottom: 8),
                  children: rows,
                ),
              ),
              Container(
                padding: const EdgeInsets.fromLTRB(18, 6, 12, 12),
                child: Row(
                  children: [
                    _hint('↑ ↓', S.of(context).t('player.choose')),
                    const Spacer(),
                    _hint('OK', S.of(context).t('player.apply')),
                    const SizedBox(width: 12),
                    _hint('BACK', S.of(context).t('player.close')),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _settingsSection(String label, int count) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(18, 12, 12, 4),
      child: Row(
        children: [
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: const TextStyle(color: Colors.white24, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _settingsEmpty(String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6),
      child: Text(
        text,
        style: const TextStyle(color: Colors.white24, fontSize: 11.5),
      ),
    );
  }

  Widget _settingsRow({
    required IconData icon,
    required String label,
    required bool selected,
    required bool focused,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 34,
        padding: const EdgeInsets.only(left: 14, right: 12),
        decoration: BoxDecoration(
          color: focused
              ? Colors.white.withValues(alpha: 0.10)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: focused ? kAccent : Colors.transparent,
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 15),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white,
                  fontSize: 12,
                  fontWeight: selected ? FontWeight.w900 : FontWeight.w800,
                ),
              ),
            ),
            if (selected)
              const Icon(Icons.check_rounded, color: kAccent, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupPanel() {
    return Container(
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.10),
        border: Border(
          right: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 16, 8, 8),
            child: Row(
              children: [
                const Icon(Icons.grid_view_rounded, color: kAccent, size: 16),
                const SizedBox(width: 7),
                Text(
                  S.of(context).t('player.bouquets'),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.1,
                  ),
                ),
                const Spacer(),
                _rangeLabel(_groupScroll, _groups.length),
              ],
            ),
          ),
          Expanded(
            child: _groups.isEmpty
                ? const Center(
                    child: SizedBox(
                      width: 22,
                      height: 22,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: kAccent,
                      ),
                    ),
                  )
                : _scrollableColumn(
                    itemCount: _groups.length,
                    controller: _groupScroll,
                    itemBuilder: (i, _) => _groupRow(_groups[i], i),
                  ),
          ),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 6, 8, 12),
            child: Row(
              children: [
                _hint('OK', S.of(context).t('player.choose')),
                const Spacer(),
                _hint('BACK', S.of(context).t('player.return')),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChannelPanel() {
    final left = 14.0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: EdgeInsets.fromLTRB(left, 16, 12, 8),
          child: Row(
            children: [
              if (!_groupsOpen) ...[
                _BouquetButton(onTap: _showGroups),
                const SizedBox(width: 8),
              ],
              Text(
                S.of(context).t('player.channelList'),
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.0,
                ),
              ),
              const Spacer(),
              _rangeLabel(_channelScroll, _browseItems.length),
              const SizedBox(width: 8),
              _PageButton(label: 'CH−', onTap: () => _jumpPage(-1)),
              const SizedBox(width: 4),
              _PageButton(label: 'CH+', onTap: () => _jumpPage(1)),
            ],
          ),
        ),
        Padding(
          padding: EdgeInsets.only(left: left, right: 12),
          child: Text(
            _browseGroupName.isEmpty
                ? S.of(context).t('player.allChannels')
                : _browseGroupName.toUpperCase(),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              letterSpacing: 1,
            ),
          ),
        ),
        const SizedBox(height: 8),
        Expanded(
          child: _loadingBrowse
              ? const Center(
                  child: SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 2.4,
                      color: kAccent,
                    ),
                  ),
                )
              : _browseItems.isEmpty
              ? Center(
                  child: Text(
                    S.of(context).t('player.noChannels'),
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                  ),
                )
              : _scrollableColumn(
                  itemCount: _browseItems.length,
                  controller: _channelScroll,
                  itemBuilder: (i, rowHeight) =>
                      _channelRow(_browseItems[i], i, rowHeight),
                ),
        ),
        Container(
          padding: EdgeInsets.fromLTRB(left, 6, 12, 12),
          child: Row(
            children: [
              _hint(
                'OK',
                _armedIndex == _channelListIndex
                    ? S.of(context).t('player.fullscreen')
                    : S.of(context).t('player.watch'),
              ),
              const SizedBox(width: 12),
              if (!_groupsOpen) ...[
                _hint('←', S.of(context).t('player.bouquets')),
                const SizedBox(width: 12),
              ],
              _hint('CH±', 'PAGE'),
              const Spacer(),
              _hint('BACK', ''),
            ],
          ),
        ),
      ],
    );
  }

  Widget _groupRow(MediaCategory group, int index) {
    final selected = index == _groupIndex;
    final playing = group.id == _playingGroupId;
    final focused = selected && _listFocusGroups;
    return GestureDetector(
      onTap: () => _selectBrowseGroup(index),
      child: Container(
        padding: const EdgeInsets.only(left: 14, right: 10),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: focused ? 0.16 : 0.08)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: playing
                  ? kRed
                  : (focused ? Colors.white : Colors.transparent),
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            Expanded(
              child: Text(
                group.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: selected ? Colors.white : Colors.white,
                  fontSize: 12.5,
                  fontWeight: focused ? FontWeight.w900 : FontWeight.w800,
                ),
              ),
            ),
            if (group.count > 0) ...[
              const SizedBox(width: 6),
              Text(
                '${group.count}',
                style: TextStyle(color: Colors.white, fontSize: 10.5),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _channelRow(MediaItem item, int index, double rowHeight) {
    final playingId = _items.isEmpty ? '' : _items[_index].id;
    final current = item.id == playingId;
    final selected = index == _channelListIndex;
    final armed = selected && index == _armedIndex;
    // Keep the full 28 px logos on TV; only shrink them on a short phone
    // landscape window where a 28 px row would not fit.
    final logoSize = rowHeight >= 28 ? 28.0 : (rowHeight - 2).clamp(14.0, 28.0);
    return GestureDetector(
      onTap: () {
        setState(() => _channelListIndex = index);
        _onChannelOk();
      },
      child: Container(
        padding: const EdgeInsets.only(left: 16, right: 8),
        decoration: BoxDecoration(
          color: selected
              ? Colors.white.withValues(alpha: armed ? 0.18 : 0.10)
              : Colors.transparent,
          border: Border(
            left: BorderSide(
              color: current
                  ? kRed
                  : (armed
                        ? kAccent
                        : (selected ? Colors.white : Colors.transparent)),
              width: 3,
            ),
          ),
        ),
        child: Row(
          children: [
            SizedBox(
              width: 26,
              child: Text(
                '${index + 1}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: current ? FontWeight.w900 : FontWeight.w800,
                ),
              ),
            ),
            SizedBox(
              width: logoSize,
              height: logoSize,
              child: item.logo.isNotEmpty
                  ? Image.network(
                      item.logo,
                      fit: BoxFit.contain,
                      cacheWidth: 56,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.live_tv_rounded,
                        color: Colors.white24,
                        size: 17,
                      ),
                    )
                  : const Icon(
                      Icons.live_tv_rounded,
                      color: Colors.white24,
                      size: 17,
                    ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                item.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 13.5,
                  fontWeight: current ? FontWeight.w900 : FontWeight.w800,
                ),
              ),
            ),
            if (armed)
              const Icon(Icons.play_arrow_rounded, color: kAccent, size: 18)
            else if (current)
              const Icon(Icons.graphic_eq_rounded, color: kAccent, size: 16),
          ],
        ),
      ),
    );
  }

  Widget _buildInfoBar(MediaItem item) {
    final program = _currentProgram;
    final next = _nextProgram;
    return Positioned(
      left: 0,
      right: 0,
      bottom: 0,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _hideControls,
        child: Container(
          padding: const EdgeInsets.fromLTRB(44, 52, 44, 20),
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Colors.transparent, Color(0xF2070713), Colors.black],
              stops: [0.0, 0.55, 1.0],
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildLogo(item),
                  const SizedBox(width: 16),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Row(
                          children: [
                            Text(
                              '${_index + 1}',
                              style: const TextStyle(
                                color: kAccent,
                                fontSize: 22,
                                fontWeight: FontWeight.w800,
                                height: 1,
                              ),
                            ),
                            Text(
                              ' / ${_items.length}',
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 14,
                                height: 1,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Flexible(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.white.withValues(alpha: 0.08),
                                  borderRadius: BorderRadius.circular(3),
                                ),
                                child: Text(
                                  _playingGroupName.isNotEmpty
                                      ? _playingGroupName.toUpperCase()
                                      : _kindLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 10,
                                    letterSpacing: 1.1,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 5),
                        Text(
                          item.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 27,
                            fontWeight: FontWeight.w800,
                            height: 1.1,
                          ),
                        ),
                        const SizedBox(height: 9),
                        if (_isLive)
                          _buildLiveProgram(program, next)
                        else
                          _buildVodProgress(),
                      ],
                    ),
                  ),
                  const SizedBox(width: 24),
                  SizedBox(
                    width: 196,
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          _clock,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 30,
                            fontWeight: FontWeight.w800,
                            height: 1,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          _streamInfo,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 12,
                            letterSpacing: 0.2,
                          ),
                        ),
                        const SizedBox(height: 6),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.end,
                          children: [
                            Icon(
                              _buffering
                                  ? Icons.hourglass_top_rounded
                                  : (_playing
                                        ? Icons.play_arrow_rounded
                                        : Icons.pause_rounded),
                              color: _buffering ? kAccent : Colors.white,
                              size: 15,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              _buffering
                                  ? S.of(context).t('player.loading')
                                  : S
                                        .of(context)
                                        .t(
                                          _playing
                                              ? 'player.playing'
                                              : 'player.paused',
                                        ),
                              style: TextStyle(
                                color: _buffering ? kAccent : Colors.white,
                                fontSize: 10,
                                letterSpacing: 1,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          _hint(
                            'OK',
                            _isLive
                                ? S.of(context).t('player.info')
                                : 'PLAY / PAUSE',
                          ),
                          const SizedBox(width: 18),
                          _hint(
                            '←  →',
                            _isLive
                                ? S.of(context).t('player.channel')
                                : S.of(context).t('player.forward'),
                          ),
                          const SizedBox(width: 18),
                          if (_isLive) ...[
                            _hint('↑', S.of(context).t('player.channelList')),
                            const SizedBox(width: 18),
                            _hint('CH ±', 'PAGE'),
                            const SizedBox(width: 18),
                          ],
                          if (_showEpisodeNav) ...[
                            _buildItemNav(),
                            const SizedBox(width: 10),
                          ],
                          _buildSettingsButton(),
                          const SizedBox(width: 10),
                          _buildScreenModeButton(),
                          const SizedBox(width: 18),
                          _hint('BACK', S.of(context).t('player.exit')),
                        ],
                      ),
                    ),
                  ),
                  if (_isLive)
                    Row(
                      children: [
                        Container(
                          width: 7,
                          height: 7,
                          decoration: const BoxDecoration(
                            color: kRed,
                            shape: BoxShape.circle,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          S.of(context).t('player.live'),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            letterSpacing: 1.4,
                          ),
                        ),
                      ],
                    ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  String get _kindLabel => switch (widget.kind) {
    MediaKind.live => S.of(context).t('player.live'),
    MediaKind.movie => S.of(context).t('player.movie'),
    MediaKind.series => S.of(context).t('player.series'),
  };

  Widget _buildLogo(MediaItem item) {
    return Container(
      width: 80,
      height: 80,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(7),
        border: Border.all(color: Colors.white12),
      ),
      child: item.logo.isNotEmpty
          ? Image.network(
              item.logo,
              fit: BoxFit.contain,
              cacheWidth: 200,
              errorBuilder: (_, _, _) => _logoFallback(item),
            )
          : _logoFallback(item),
    );
  }

  Widget _logoFallback(MediaItem item) {
    final letter = item.name.isEmpty
        ? 'TV'
        : item.name.substring(0, 1).toUpperCase();
    return Center(
      child: Text(
        letter,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 30,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _buildLiveProgram(EpgEntry? program, EpgEntry? next) {
    final progress = program?.progress;
    final title = program?.title.isNotEmpty == true
        ? program!.title
        : S.of(context).t('player.noProgramme');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Text(
              S.of(context).t('player.now'),
              style: const TextStyle(
                color: kRed,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.4,
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                title,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 15,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: LinearProgressIndicator(
            value: progress ?? 0,
            minHeight: 3,
            backgroundColor: Colors.white.withValues(alpha: 0.16),
            valueColor: const AlwaysStoppedAnimation(kRed),
          ),
        ),
        const SizedBox(height: 4),
        Row(
          children: [
            Text(
              program?.timeRange.isNotEmpty == true ? program!.timeRange : '',
              style: const TextStyle(color: Colors.white, fontSize: 10),
            ),
            if (next != null && next.title.isNotEmpty) ...[
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  S.of(context).t('player.next', {'title': next.title}),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  textAlign: TextAlign.right,
                  style: const TextStyle(color: Colors.white, fontSize: 10),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _buildVodProgress() {
    final total = _duration.inMilliseconds;
    final played = total <= 0
        ? 0.0
        : (_position.inMilliseconds / total).clamp(0.0, 1.0);
    final value = _scrubbing ? _scrubFraction : played;
    final timelineFocused = _infoFocus == _timelineFocus;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        AnimatedContainer(
          duration: const Duration(milliseconds: 110),
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
          decoration: BoxDecoration(
            color: timelineFocused
                ? kAccent.withValues(alpha: 0.16)
                : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: timelineFocused ? kAccent : Colors.transparent,
              width: 1.4,
            ),
          ),
          child: _buildVodSeekBar(value, focused: timelineFocused),
        ),
        const SizedBox(height: 2),
        Row(
          children: [
            _RoundControl(
              icon: Icons.replay_10_rounded,
              tooltip: S.of(context).t('player.rewind10'),
              focused: _infoFocus == 0,
              onTap: () => _seek(-_seekStep),
            ),
            const SizedBox(width: 8),
            _RoundControl(
              icon: _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              tooltip: S
                  .of(context)
                  .t(_playing ? 'player.pause' : 'player.play'),
              focused: _infoFocus == 1,
              onTap: _toggle,
            ),
            const SizedBox(width: 8),
            _RoundControl(
              icon: Icons.forward_10_rounded,
              tooltip: S.of(context).t('player.forward10'),
              focused: _infoFocus == 2,
              onTap: () => _seek(_seekStep),
            ),
            const SizedBox(width: 14),
            Text(
              _format(
                _scrubbing
                    ? Duration(
                        milliseconds: (_duration.inMilliseconds * value)
                            .round(),
                      )
                    : _position,
              ),
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
            Text(
              ' / ${_duration > Duration.zero ? _format(_duration) : '--:--'}',
              style: const TextStyle(color: Colors.white, fontSize: 11),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildVodSeekBar(double value, {required bool focused}) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final thumbLeft = (value * width - 7)
            .clamp(0.0, (width - 14).clamp(0.0, width))
            .toDouble();
        void updateFromDx(double dx) {
          if (_duration <= Duration.zero) return;
          final fraction = (dx / width).clamp(0.0, 1.0);
          final now = DateTime.now();
          final due = now.difference(_lastScrubSeek).inMilliseconds >= 300;
          if (due) _lastScrubSeek = now;
          setState(() {
            _scrubbing = true;
            _scrubFraction = fraction;
          });
          if (due) _seekToFraction(fraction);
        }

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (details) {
            final fraction = (details.localPosition.dx / width).clamp(0.0, 1.0);
            setState(() {
              _scrubbing = false;
              _scrubFraction = fraction;
            });
            _seekToFraction(fraction);
          },
          onHorizontalDragStart: (details) =>
              updateFromDx(details.localPosition.dx),
          onHorizontalDragUpdate: (details) =>
              updateFromDx(details.localPosition.dx),
          onHorizontalDragEnd: (details) {
            final fraction = _scrubFraction;
            setState(() => _scrubbing = false);
            _seekToFraction(fraction);
          },
          onHorizontalDragCancel: () {
            final fraction = _scrubFraction;
            setState(() => _scrubbing = false);
            _seekToFraction(fraction);
          },
          child: SizedBox(
            height: 26,
            child: Stack(
              alignment: Alignment.centerLeft,
              children: [
                Container(
                  height: 4,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                FractionallySizedBox(
                  widthFactor: value,
                  child: Container(
                    height: 4,
                    decoration: BoxDecoration(
                      color: kRed,
                      borderRadius: BorderRadius.circular(2),
                    ),
                  ),
                ),
                Positioned(
                  left: thumbLeft,
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 110),
                    width: focused ? 18 : 14,
                    height: focused ? 18 : 14,
                    decoration: BoxDecoration(
                      color: kRed,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: focused ? kAccent : Colors.white,
                        width: 2,
                      ),
                      boxShadow: focused
                          ? [
                              BoxShadow(
                                color: kAccent.withValues(alpha: 0.55),
                                blurRadius: 12,
                              ),
                            ]
                          : null,
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildSettingsButton() {
    final active = _infoFocus == _settingsFocus || _settingsOpen;
    return GestureDetector(
      onTap: _openSettings,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? kAccent.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: active ? kAccent : Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.settings_rounded, size: 13, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              S.of(context).t('player.audioSubs'),
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _infoFocus == _settingsFocus ? 'OK' : '→',
              style: TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildScreenModeButton() {
    final active = _infoFocus == _modeFocus;
    return GestureDetector(
      onTap: _openRatioMenu,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active
              ? kAccent.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: active ? kAccent : Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.aspect_ratio_rounded, size: 13, color: Colors.white),
            const SizedBox(width: 6),
            Text(
              S.of(context).t('player.screen'),
              style: TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: kRed,
                borderRadius: BorderRadius.circular(2),
              ),
              child: Text(
                _screenMode.label,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 9,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.4,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              _infoFocus == _modeFocus ? 'OK' : '→',
              style: TextStyle(
                color: Colors.white,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Previous / next controls for series episodes only. Both buttons stay
  /// visible so the ⏮ / ⏭ symbols are always recognisable; the one at the
  /// start/end of the list is dimmed and inert.
  Widget _buildItemNav() {
    final atStart = _index <= 0;
    final atEnd = _index >= _items.length - 1;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _itemButton(
          icon: Icons.skip_previous_rounded,
          label: S.of(context).t('player.previous'),
          focused: _infoFocus == 3,
          enabled: !atStart,
          onTap: _prev,
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          decoration: BoxDecoration(
            color: kRed,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            '${_index + 1}/${_items.length}',
            style: const TextStyle(
              color: Colors.white,
              fontSize: 9,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.4,
            ),
          ),
        ),
        const SizedBox(width: 6),
        _itemButton(
          icon: Icons.skip_next_rounded,
          label: S.of(context).t('player.nextEpisode'),
          focused: _infoFocus == 4,
          enabled: !atEnd,
          onTap: _next,
        ),
      ],
    );
  }

  Widget _itemButton({
    required IconData icon,
    required String label,
    required bool focused,
    required bool enabled,
    required VoidCallback onTap,
  }) {
    final foreground = enabled ? Colors.white : Colors.white38;
    return GestureDetector(
      onTap: enabled ? onTap : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: focused
              ? kAccent.withValues(alpha: 0.18)
              : Colors.white.withValues(alpha: enabled ? 0.10 : 0.04),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: focused
                ? kAccent
                : Colors.white.withValues(alpha: enabled ? 0.24 : 0.10),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: foreground,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1,
              ),
            ),
            const SizedBox(width: 6),
            Text(
              focused ? 'OK' : '→',
              style: TextStyle(
                color: foreground,
                fontSize: 9,
                fontWeight: FontWeight.w800,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hint(String key, String label) {
    return Row(
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.1),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(color: Colors.white24),
          ),
          child: Text(
            key,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              fontWeight: FontWeight.w800,
              letterSpacing: 0.5,
            ),
          ),
        ),
        if (label.isNotEmpty) ...[
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              color: Colors.white,
              fontSize: 10,
              letterSpacing: 1,
            ),
          ),
        ],
      ],
    );
  }
}

/// Small confirmation shown when a movie or an episode has a saved position.
class _ResumeDialog extends StatelessWidget {
  final String time;

  const _ResumeDialog({required this.time});

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      elevation: 0,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Container(
        width: 470,
        padding: const EdgeInsets.fromLTRB(28, 24, 28, 22),
        decoration: BoxDecoration(
          gradient: kTileGradient,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 30,
              offset: const Offset(0, 12),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.play_circle_outline_rounded,
              color: kAccent,
              size: 38,
            ),
            const SizedBox(height: 12),
            Text(
              S.of(context).t('resume.title'),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 22,
                fontWeight: FontWeight.w900,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              S.of(context).t('resume.body', {'time': time}),
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.w800,
                height: 1.35,
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: [
                Expanded(
                  child: _ResumeButton(
                    label: S.of(context).t('resume.restart'),
                    icon: Icons.restart_alt_rounded,
                    autofocus: false,
                    onTap: () => Navigator.of(context).pop(false),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: _ResumeButton(
                    label: S.of(context).t('resume.continue', {'time': time}),
                    icon: Icons.play_arrow_rounded,
                    autofocus: true,
                    onTap: () => Navigator.of(context).pop(true),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ResumeButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final bool autofocus;
  final VoidCallback onTap;

  const _ResumeButton({
    required this.label,
    required this.icon,
    required this.autofocus,
    required this.onTap,
  });

  @override
  State<_ResumeButton> createState() => _ResumeButtonState();
}

class _ResumeButtonState extends State<_ResumeButton> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      autofocus: widget.autofocus,
      onActivate: widget.onTap,
      onFocusChange: (value) => setState(() => _focused = value),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 130),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 14),
          decoration: BoxDecoration(
            color: _focused
                ? Colors.white.withValues(alpha: 0.14)
                : Colors.white.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: _focused
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.16),
              width: _focused ? 2.5 : 1,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, color: Colors.white, size: 22),
              const SizedBox(width: 9),
              Flexible(
                child: Text(
                  widget.label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w900,
                    height: 1.15,
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

/// Left arrow button that reveals the bouquet (group) panel.
class _BouquetButton extends StatelessWidget {
  final VoidCallback onTap;

  const _BouquetButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.06),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: Colors.white24),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.chevron_left_rounded, color: kAccent, size: 18),
            const SizedBox(width: 3),
            Text(
              S.of(context).t('player.bouquets'),
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w800,
                letterSpacing: 1.1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact CH- / CH+ button that pages the channel list by 15 entries.
class _PageButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const _PageButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
        decoration: BoxDecoration(
          color: kAccent.withValues(alpha: 0.10),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: kAccent.withValues(alpha: 0.45)),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: kAccent,
            fontSize: 10.5,
            fontWeight: FontWeight.w800,
            letterSpacing: 0.4,
          ),
        ),
      ),
    );
  }
}

/// Circular touch control (seek / play-pause) used by the VOD progress bar.
class _RoundControl extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;
  final bool focused;

  const _RoundControl({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.focused = false,
  });

  @override
  State<_RoundControl> createState() => _RoundControlState();
}

class _RoundControlState extends State<_RoundControl> {
  bool _down = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _down || widget.focused;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 700),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _down = true),
        onTapUp: (_) => setState(() => _down = false),
        onTapCancel: () => setState(() => _down = false),
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 90),
          width: 42,
          height: 42,
          decoration: BoxDecoration(
            color: highlighted
                ? kAccent.withValues(alpha: 0.24)
                : Colors.white.withValues(alpha: 0.10),
            shape: BoxShape.circle,
            border: Border.all(
              color: highlighted ? kAccent : Colors.white24,
              width: highlighted ? 2 : 1,
            ),
          ),
          child: Icon(widget.icon, size: 22, color: Colors.white),
        ),
      ),
    );
  }
}
