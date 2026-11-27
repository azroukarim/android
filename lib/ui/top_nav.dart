import 'package:flutter/material.dart';

import '../l10n/app_localizations.dart';
import '../theme.dart';
import 'tv_focus.dart';

class TopNav extends StatelessWidget {
  final String current;
  final Gradient? background;
  const TopNav({super.key, required this.current, this.background});

  static const _keys = ['home', 'live', 'movies', 'series'];

  static String _label(BuildContext context, String key) {
    final s = S.of(context);
    return switch (key) {
      'home' => s.t('nav.home'),
      'live' => s.t('nav.live'),
      'movies' => s.t('nav.movies'),
      _ => s.t('nav.series'),
    };
  }

  void _go(BuildContext context, String key) {
    if (key == 'home') {
      if (current == 'home') return;
      // Reset to a single fresh Home route: BACK from Home then closes the
      // app, while BACK from any other section returns to Home.
      Navigator.pushNamedAndRemoveUntil(context, '/home', (_) => false);
      return;
    }
    final route = switch (key) {
      'live' => '/live',
      'movies' => '/movies',
      _ => '/series',
    };
    if (route == '/$current') return;
    // Keep the Home route underneath: BACK from a section now returns to it
    // instead of closing the application.
    Navigator.pushReplacementNamed(context, route);
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 1100;
        // A slimmer header leaves more room for the Live lists below.
        final height = compact ? 50.0 : 62.0;
        final navFont = compact ? 17.0 : 20.0;
        final gap = compact ? 8.0 : 12.0;
        return Container(
          height: height,
          padding: EdgeInsets.symmetric(horizontal: compact ? 24 : 28),
          decoration: background != null
              ? BoxDecoration(gradient: background)
              : const BoxDecoration(color: Color(0xFF0A0918)),
          child: Row(
            children: [
              for (var i = 0; i < _keys.length; i++) ...[
                _NavItem(
                  label: _label(context, _keys[i]),
                  selected: current == _keys[i],
                  fontSize: navFont,
                  onTap: () => _go(context, _keys[i]),
                ),
                if (i != _keys.length - 1)
                  Container(
                    width: 1,
                    height: compact ? 18 : 22,
                    color: Colors.white24,
                    margin: EdgeInsets.symmetric(horizontal: gap),
                  ),
              ],
              const Spacer(),
              _SearchBox(
                compact: compact,
                red: background != null,
                onTap: () => Navigator.pushNamed(context, '/search'),
              ),
              SizedBox(width: compact ? 10 : 18),
              _Logo(compact: compact),
            ],
          ),
        );
      },
    );
  }
}

class _NavItem extends StatefulWidget {
  final String label;
  final bool selected;
  final double fontSize;
  final VoidCallback onTap;

  const _NavItem({
    required this.label,
    required this.selected,
    required this.fontSize,
    required this.onTap,
  });

  @override
  State<_NavItem> createState() => _NavItemState();
}

class _NavItemState extends State<_NavItem> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    return TvFocus(
      onActivate: widget.onTap,
      onFocusChange: (f) => setState(() => _focused = f),
      underline: true,
      child: GestureDetector(
        onTap: widget.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 5),
          child: Text(
            widget.label,
            style: TextStyle(
              fontSize: widget.fontSize,
              fontWeight: FontWeight.w800,
              color: widget.selected
                  ? kAccent
                  : (_focused ? Colors.white : Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class _SearchBox extends StatefulWidget {
  final bool compact;
  final bool red;
  final VoidCallback onTap;
  const _SearchBox({
    required this.compact,
    required this.red,
    required this.onTap,
  });

  @override
  State<_SearchBox> createState() => _SearchBoxState();
}

class _SearchBoxState extends State<_SearchBox> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final compact = widget.compact;
    // Compact magnifier only: a small icon button instead of a wide search box.
    return TvFocus(
      onActivate: widget.onTap,
      onFocusChange: (f) => setState(() => _focused = f),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          width: compact ? 36 : 42,
          height: compact ? 36 : 42,
          decoration: BoxDecoration(
            gradient: widget.red ? kTileGradient : null,
            color: widget.red ? null : const Color(0xFF151329),
            shape: BoxShape.circle,
            border: Border.all(
              color: _focused
                  ? kAccent
                  : widget.red
                  ? Colors.white.withValues(alpha: 0.28)
                  : Colors.white24,
              width: _focused ? 2 : 1,
            ),
          ),
          child: Icon(
            Icons.search,
            color: Colors.white,
            size: compact ? 18 : 20,
          ),
        ),
      ),
    );
  }
}

class _Logo extends StatelessWidget {
  final bool compact;
  const _Logo({required this.compact});

  @override
  Widget build(BuildContext context) {
    final size = compact ? 26.0 : 28.0;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Image.asset(
          'assets/branding/streamplayer_logo.png',
          width: size,
          height: size,
          fit: BoxFit.contain,
          filterQuality: FilterQuality.high,
        ),
        SizedBox(width: compact ? 6 : 8),
        Text(
          'Stream',
          style: TextStyle(
            color: Colors.white,
            fontSize: compact ? 16 : 20,
            fontWeight: FontWeight.w800,
          ),
        ),
        Text(
          'player',
          style: TextStyle(
            color: const Color(0xFF59E0FF),
            fontSize: compact ? 16 : 20,
            fontWeight: FontWeight.w800,
          ),
        ),
      ],
    );
  }
}
