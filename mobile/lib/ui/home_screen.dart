import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../core/domain_engine.dart';
import '../services/classifier_api.dart';
import '../services/content_guardian.dart';
import '../services/filter_vpn.dart';
import 'app_theme.dart';
import 'lockout_screen.dart';
import 'pixel_dither_background.dart';
import 'protection_island.dart';
import 'safe_browser.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _vpn = FilterVpn.instance;
  final _guardian = ContentGuardian.instance;
  final _api = ClassifierApi.instance;
  final _typeCtrl = TextEditingController();
  final _apiCtrl = TextEditingController();
  final _engine = DomainEngine();

  bool _busy = false;
  bool _showSettings = false;
  bool? _apiOnline;
  String? _error;

  @override
  void initState() {
    super.initState();
    _guardian.onLockout = () {
      if (!mounted) return;
      final ev = _guardian.lastHit.value;
      if (ev == null) return;
      Navigator.of(context).push(
        PageRouteBuilder(
          opaque: true,
          pageBuilder: (context, a, b) => LockoutScreen(event: ev),
        ),
      );
    };
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _api.loadSavedBaseUrl();
    _apiCtrl.text = _api.baseUrl;
    await _vpn.startListening();
    try {
      final nsfw = await rootBundle.loadString('assets/nsfw.txt');
      final allow = await rootBundle.loadString('assets/allowlist.txt');
      _engine.loadBlocklist(nsfw);
      _engine.loadAllowlist(allow);
    } catch (_) {}
    final online = await _api.isOnline();
    if (mounted) setState(() => _apiOnline = online);
  }

  Future<void> _toggleProtect() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_vpn.status.value == VpnStatus.active ||
          _vpn.status.value == VpnStatus.connecting) {
        await _vpn.stop();
      } else {
        await _vpn.prepareAndStart();
      }
    } catch (e) {
      setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _toggleGuard(bool on) async {
    setState(() => _busy = true);
    try {
      if (on) {
        final online = await _api.isOnline();
        if (!online && mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Can’t reach filter server on your PC')),
          );
        }
        await _guardian.start();
      } else {
        await _guardian.stop();
      }
      final online = await _api.isOnline();
      if (mounted) setState(() => _apiOnline = online);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    _typeCtrl.dispose();
    _apiCtrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: PixelDitherBackground(
        child: SafeArea(
          child: Stack(
            children: [
              ListView(
                padding: const EdgeInsets.fromLTRB(20, 64, 20, 28),
                children: [
                  const SizedBox(height: 8),
                  Center(
                    child: Column(
                      children: [
                        Container(
                          width: 88,
                          height: 88,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(22),
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.2),
                                blurRadius: 18,
                                offset: const Offset(0, 8),
                              ),
                            ],
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: Image.asset(
                            'assets/logo_square.png',
                            fit: BoxFit.cover,
                            filterQuality: FilterQuality.none,
                          ),
                        ),
                        const SizedBox(height: 14),
                        const Text(
                          'NoPornForever',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            fontWeight: FontWeight.w800,
                            letterSpacing: -0.5,
                            shadows: [
                              Shadow(
                                color: Color(0x66000000),
                                blurRadius: 8,
                                offset: Offset(0, 2),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 4),
                        Text(
                          'Stay clean. Stay focused.',
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 28),
                  _GlassCard(
                    child: ValueListenableBuilder<VpnStatus>(
                      valueListenable: _vpn.status,
                      builder: (context, status, _) {
                        final on = status == VpnStatus.active;
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            Row(
                              children: [
                                Icon(
                                  on ? Icons.shield : Icons.shield_outlined,
                                  color: on ? AppColors.success : AppColors.inkSoft,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    on ? 'Protection on' : 'Protection off',
                                    style: const TextStyle(
                                      color: AppColors.ink,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            Text(
                              on
                                  ? 'Sites on the block list can’t open.'
                                  : 'Turn on to block adult sites on this phone.',
                              style: const TextStyle(
                                color: AppColors.inkSoft,
                                fontSize: 13,
                              ),
                            ),
                            const SizedBox(height: 16),
                            FilledButton(
                              onPressed: _busy ? null : _toggleProtect,
                              style: FilledButton.styleFrom(
                                backgroundColor:
                                    on ? AppColors.danger : AppColors.accent,
                                minimumSize: const Size.fromHeight(50),
                              ),
                              child: Text(
                                _busy
                                    ? '…'
                                    : on
                                        ? 'Turn off'
                                        : 'Turn on',
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  fontSize: 16,
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ),
                  const SizedBox(height: 12),
                  ValueListenableBuilder<VpnStats>(
                    valueListenable: _vpn.stats,
                    builder: (context, s, _) {
                      return Row(
                        children: [
                          Expanded(child: _MiniStat(label: 'Checked', value: '${s.queries}')),
                          const SizedBox(width: 10),
                          Expanded(child: _MiniStat(label: 'Blocked', value: '${s.blocked}')),
                          const SizedBox(width: 10),
                          Expanded(
                            child: ValueListenableBuilder<GuardianState>(
                              valueListenable: _guardian.state,
                              builder: (context, gs, _) {
                                final gOn = gs == GuardianState.watching ||
                                    gs == GuardianState.locked;
                                return _MiniStat(
                                  label: 'Smart',
                                  value: gOn ? 'On' : 'Off',
                                );
                              },
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                  const SizedBox(height: 12),
                  _GlassCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        Row(
                          children: [
                            const Expanded(
                              child: Text(
                                'Smart guard',
                                style: TextStyle(
                                  color: AppColors.ink,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w700,
                                ),
                              ),
                            ),
                            Container(
                              width: 8,
                              height: 8,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: _apiOnline == true
                                    ? AppColors.success
                                    : _apiOnline == false
                                        ? AppColors.danger
                                        : AppColors.skyPale,
                              ),
                            ),
                            const SizedBox(width: 6),
                            Text(
                              _apiOnline == true
                                  ? 'Ready'
                                  : _apiOnline == false
                                      ? 'PC offline'
                                      : '…',
                              style: const TextStyle(
                                color: AppColors.inkSoft,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 6),
                        const Text(
                          'Blocks bad text & screen content. Closes the app if it trips.',
                          style: TextStyle(color: AppColors.inkSoft, fontSize: 13),
                        ),
                        const SizedBox(height: 10),
                        ValueListenableBuilder<GuardianState>(
                          valueListenable: _guardian.state,
                          builder: (context, st, _) {
                            final on = st == GuardianState.watching ||
                                st == GuardianState.locked;
                            return Material(
                              color: Colors.transparent,
                              child: SwitchListTile(
                                contentPadding: EdgeInsets.zero,
                                title: Text(
                                  on ? 'Watching' : 'Off',
                                  style: const TextStyle(
                                    color: AppColors.ink,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                value: on,
                                onChanged: (_busy || st == GuardianState.locked)
                                    ? null
                                    : _toggleGuard,
                                activeThumbColor: AppColors.accent,
                              ),
                            );
                          },
                        ),
                        TextField(
                          controller: _typeCtrl,
                          style: const TextStyle(color: AppColors.ink),
                          decoration: const InputDecoration(
                            hintText: 'Try typing something…',
                          ),
                          onChanged: (v) =>
                              _guardian.watchText(v, source: 'typebox'),
                        ),
                        const SizedBox(height: 10),
                        OutlinedButton.icon(
                          onPressed: () {
                            Navigator.of(context).push(
                              MaterialPageRoute(
                                builder: (_) => const SafeBrowserPage(),
                              ),
                            );
                          },
                          icon: const Icon(Icons.public, size: 18),
                          label: const Text('Safe browser'),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                  _GlassCard(
                    child: Column(
                      children: [
                        InkWell(
                          onTap: () =>
                              setState(() => _showSettings = !_showSettings),
                          borderRadius: BorderRadius.circular(12),
                          child: Row(
                            children: [
                              const Expanded(
                                child: Text(
                                  'Settings',
                                  style: TextStyle(
                                    color: AppColors.ink,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                              ),
                              Icon(
                                _showSettings
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                color: AppColors.inkSoft,
                              ),
                            ],
                          ),
                        ),
                        if (_showSettings) ...[
                          const SizedBox(height: 12),
                          TextField(
                            controller: _apiCtrl,
                            style: const TextStyle(
                              color: AppColors.ink,
                              fontSize: 13,
                            ),
                            decoration: const InputDecoration(
                              labelText: 'Filter server',
                              hintText: 'http://192.168.0.149:8765',
                            ),
                          ),
                          const SizedBox(height: 8),
                          Row(
                            children: [
                              Expanded(
                                child: OutlinedButton(
                                  onPressed: () async {
                                    await _api.setBaseUrl(_apiCtrl.text);
                                    final ok = await _api.isOnline();
                                    if (!mounted) return;
                                    setState(() => _apiOnline = ok);
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(
                                        content: Text(
                                          ok ? 'Connected' : 'Not reachable',
                                        ),
                                      ),
                                    );
                                  },
                                  child: const Text('Save & check'),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 8),
                          ValueListenableBuilder<List<String>>(
                            valueListenable: _vpn.recentBlocked,
                            builder: (context, items, _) {
                              if (items.isEmpty) {
                                return Text(
                                  'No blocks yet',
                                  style: TextStyle(
                                    color: AppColors.inkSoft.withValues(alpha: 0.8),
                                    fontSize: 12,
                                  ),
                                );
                              }
                              return Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  const Text(
                                    'Recent blocks',
                                    style: TextStyle(
                                      color: AppColors.ink,
                                      fontWeight: FontWeight.w600,
                                      fontSize: 13,
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  ...items.take(5).map(
                                        (d) => Padding(
                                          padding: const EdgeInsets.only(bottom: 4),
                                          child: Text(
                                            d,
                                            style: const TextStyle(
                                              color: AppColors.inkSoft,
                                              fontSize: 12,
                                              fontFamily: 'monospace',
                                            ),
                                          ),
                                        ),
                                      ),
                                ],
                              );
                            },
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (_error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      _error!,
                      style: const TextStyle(color: Color(0xFFFFE0E0)),
                      textAlign: TextAlign.center,
                    ),
                  ],
                ],
              ),
              Align(
                alignment: Alignment.topCenter,
                child: Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: ValueListenableBuilder<VpnStatus>(
                    valueListenable: _vpn.status,
                    builder: (context, status, _) {
                      return ValueListenableBuilder<VpnStats>(
                        valueListenable: _vpn.stats,
                        builder: (context, stats, _) {
                          return ProtectionIsland(
                            status: status,
                            stats: stats,
                            onTap: _busy ? null : _toggleProtect,
                          );
                        },
                      );
                    },
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

class _GlassCard extends StatelessWidget {
  const _GlassCard({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: Colors.white.withValues(alpha: 0.65)),
        boxShadow: [
          BoxShadow(
            color: AppColors.skyDeep.withValues(alpha: 0.12),
            blurRadius: 20,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: child,
    );
  }
}

class _MiniStat extends StatelessWidget {
  const _MiniStat({required this.label, required this.value});
  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
      decoration: BoxDecoration(
        color: AppColors.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.55)),
      ),
      child: Column(
        children: [
          Text(
            value,
            style: const TextStyle(
              color: AppColors.ink,
              fontWeight: FontWeight.w800,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: const TextStyle(color: AppColors.inkSoft, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
