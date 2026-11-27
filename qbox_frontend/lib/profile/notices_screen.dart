import 'package:flutter/material.dart';

import '../onboarding_draft.dart';
import '../services/api_client.dart';
import '../services/app_services.dart';
import '../calculator/voice_services.dart';
import '../payments/payment_models.dart' show receivedWords;
import '../services/push_notifications.dart';
import '../translator/languages.dart';
import '../translator/voice_language.dart';
import '../udhaar/udhaar_models.dart' show whenLabel;
import '../udhaar/udhaar_widgets.dart';
import 'notices.dart';

/// The bell's list for one role. Tapping one opens the screen it is about.
class NoticesScreen extends StatefulWidget {
  const NoticesScreen({required this.role, this.now, super.key});

  final QboxRole role;
  final DateTime? now;

  @override
  State<NoticesScreen> createState() => _NoticesScreenState();
}

class _NoticesScreenState extends State<NoticesScreen> {
  AppServices? _services;
  Notices? _notices;
  String? _error;
  bool _busy = false;

  AppServices get _app => _services!;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services != null) return;
    _services = ServicesScope.of(context);
    _load();
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final notices = await _app.notices.all(widget.role);
      if (mounted) {
        setState(() {
          _notices = notices;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isNetwork ? 'Offline: notifications need internet.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _readAll() async {
    try {
      await _app.notices.markRead(widget.role);
    } on ApiException catch (e) {
      if (mounted) udNotify(context, e.isNetwork ? 'This needs internet. Please try again.' : e.message);
      return;
    }
    if (mounted) await _load();
  }

  Future<void> _open(Notice notice) async {
    final notices = _notices;
    if (notice.unread && notices != null) {
      setState(() {
        _notices = Notices(
          unread: notices.unread - 1,
          off: notices.off,
          items: [for (final n in notices.items) n.id == notice.id ? n.read() : n],
        );
      });
      // Opening matters more than marking: it is tried again next time.
      _app.notices.markRead(widget.role, id: notice.id).catchError((Object _) {});
    }
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => notice.screen));
    if (mounted) await _load();
  }

  Future<void> _settings() async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => NoticeSettingsScreen(role: widget.role)));
    if (mounted) await _load();
  }

  @override
  Widget build(BuildContext context) {
    final notices = _notices;
    final now = widget.now ?? DateTime.now();
    return Scaffold(
      backgroundColor: udBackground,
      body: SafeArea(
        child: Column(
          children: [
            UdHeader(
              title: 'Notifications',
              subtitle: notices == null || notices.unread == 0 ? null : '${notices.unread} new',
              busy: _busy,
              actions: [
                if (notices != null && notices.unread > 0)
                  IconButton(
                    key: const Key('notices-read-all'),
                    onPressed: _busy ? null : _readAll,
                    icon: const Icon(Icons.done_all_rounded, color: udPurple),
                    tooltip: 'Mark all as read',
                  ),
                if (NoticeType.of(widget.role).isNotEmpty)
                  IconButton(
                    key: const Key('notices-settings'),
                    onPressed: _settings,
                    icon: const Icon(Icons.settings_outlined, color: udPurple),
                    tooltip: 'Choose notifications',
                  ),
              ],
            ),
            if (_error != null)
              UdBanner(
                key: const Key('notices-error'),
                icon: Icons.wifi_off_rounded,
                text: _error!,
                actionLabel: 'Retry',
                onAction: _busy ? null : _load,
              ),
            Expanded(
              child: RefreshIndicator(
                onRefresh: _load,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
                  children: [
                    if (notices != null && notices.items.isEmpty)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 64),
                        child: Column(
                          children: [
                            const Icon(Icons.notifications_none_rounded, size: 44, color: udBody),
                            const SizedBox(height: 8),
                            Text(
                              'Nothing new.',
                              key: const Key('notices-empty'),
                              style: udText(15, color: udBody),
                            ),
                          ],
                        ),
                      ),
                    for (final n in notices?.items ?? const <Notice>[]) _tile(n, now),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _tile(Notice n, DateTime now) {
    final detail = n.detail ?? '';
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: n.unread ? Colors.white : const Color(0xFFF4F1FA),
        borderRadius: BorderRadius.circular(16),
        child: InkWell(
          key: Key('notice-${n.id}'),
          borderRadius: BorderRadius.circular(16),
          onTap: () => _open(n),
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(n.icon, color: n.color, size: 24),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(n.title, style: udText(14, weight: n.unread ? FontWeight.w700 : FontWeight.w500)),
                      if (detail.isNotEmpty)
                        Text(
                          detail,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: udText(12, color: udBody),
                        ),
                      const SizedBox(height: 2),
                      Text(whenLabel(n.at, now), style: udText(11, color: udBody)),
                      if (n.testMode) const UdBadge('Test money', color: udPurple),
                    ],
                  ),
                ),
                if (n.unread)
                  Container(
                    key: Key('notice-new-${n.id}'),
                    width: 10,
                    height: 10,
                    margin: const EdgeInsets.only(left: 8, top: 5),
                    decoration: const BoxDecoration(color: Color(0xFFE11D48), shape: BoxShape.circle),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Which notifications to show.
class NoticeSettingsScreen extends StatefulWidget {
  const NoticeSettingsScreen({required this.role, super.key});

  final QboxRole role;

  @override
  State<NoticeSettingsScreen> createState() => _NoticeSettingsScreenState();
}

class _NoticeSettingsScreenState extends State<NoticeSettingsScreen> {
  AppServices? _services;
  Set<NoticeType>? _off;
  String? _error;
  bool _busy = false;
  AlertPrefs _prefs = const AlertPrefs();
  AppLanguage _language = AppLanguage.english;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_services != null) return;
    _services = ServicesScope.of(context);
    _load();
    _loadPrefs();
  }

  Future<void> _loadPrefs() async {
    final prefs = await _services!.push.prefs();
    final language = await readVoiceLanguage(_services!.settings);
    if (mounted) {
      setState(() {
        _prefs = prefs;
        _language = language;
      });
    }
  }

  Future<void> _savePrefs(AlertPrefs prefs) async {
    setState(() => _prefs = prefs);
    await _services!.push.savePrefs(prefs);
  }

  Future<void> _setSpoken(NoticeType type, bool on) {
    final key = AlertPrefs.key(widget.role, type.code);
    final spoken = {..._prefs.spoken};
    on ? spoken.add(key) : spoken.remove(key);
    return _savePrefs(_prefs.copyWith(spoken: spoken));
  }

  bool get _speaksAny => NoticeType.of(widget.role).any((t) => _prefs.speaks(widget.role, t.code));

  // ---------- voice ----------

  /// "₹500 received from Ravi", in the voice language: what a sample sounds like.
  String get _sample => receivedWords(50000, _language, from: 'Ravi');

  Future<void> _pickVoice() async {
    final speaker = _services!.speaker;
    final voices = speaker is VoiceChoices ? await (speaker as VoiceChoices).voices(_language.voiceLocale) : <String>[];
    if (!mounted) return;
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _VoiceSheet(
        voices: voices,
        current: _prefs.voice,
        language: _language,
        onPlay: (voice) => voice == null
            ? speaker.say(_sample, locale: _language.voiceLocale)
            : sayAlert(speaker, _sample, _language, voice: voice),
      ),
    );
    if (picked == null) return;
    await _savePrefs(picked.isEmpty ? _prefs.copyWith(usualVoice: true) : _prefs.copyWith(voice: picked));
  }

  // ---------- quiet hours ----------

  static String _time(int minute) {
    final h = minute ~/ 60, m = minute % 60;
    final hour12 = h % 12 == 0 ? 12 : h % 12;
    return '$hour12:${m.toString().padLeft(2, '0')} ${h < 12 ? 'AM' : 'PM'}';
  }

  Future<void> _setQuiet(bool on) => _savePrefs(
    on ? _prefs.copyWith(quietFrom: 22 * 60, quietTo: 7 * 60) : _prefs.copyWith(noQuiet: true),
  );

  Future<void> _pickQuiet({required bool from}) async {
    final now = (from ? _prefs.quietFrom : _prefs.quietTo) ?? 0;
    final picked = await showTimePicker(context: context, initialTime: TimeOfDay(hour: now ~/ 60, minute: now % 60));
    if (picked == null) return;
    final minute = picked.hour * 60 + picked.minute;
    await _savePrefs(from ? _prefs.copyWith(quietFrom: minute) : _prefs.copyWith(quietTo: minute));
  }

  Future<void> _load() async {
    setState(() => _busy = true);
    try {
      final notices = await _services!.notices.all(widget.role);
      if (mounted) {
        setState(() {
          _off = notices.off;
          _error = null;
        });
      }
    } on ApiException catch (e) {
      if (mounted) setState(() => _error = e.isNetwork ? 'This needs internet.' : e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _set(NoticeType type, bool on) async {
    final before = _off!;
    final after = {...before};
    on ? after.remove(type) : after.add(type);
    setState(() {
      _off = after;
      _busy = true;
    });
    try {
      await _services!.notices.setOff(widget.role, after);
    } on ApiException catch (e) {
      if (mounted) {
        setState(() => _off = before);
        udNotify(context, e.isNetwork ? 'This needs internet. Please try again.' : e.message);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final off = _off;
    return Scaffold(
      backgroundColor: udBackground,
      body: SafeArea(
        child: Column(
          children: [
            UdHeader(title: 'Choose notifications', busy: _busy),
            if (_error != null)
              UdBanner(
                icon: Icons.wifi_off_rounded,
                text: _error!,
                actionLabel: 'Retry',
                onAction: _busy ? null : _load,
              ),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  if (NoticeType.of(widget.role).isEmpty)
                    Text('There is nothing to choose yet.', style: udText(14, color: udBody)),
                  if (off != null)
                    Material(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(20),
                      clipBehavior: Clip.antiAlias,
                      child: Column(
                        children: [
                          for (final t in NoticeType.of(widget.role))
                            SwitchListTile(
                              key: Key('notice-type-${t.code}'),
                              value: !off.contains(t),
                              onChanged: _busy ? null : (on) => _set(t, on),
                              activeTrackColor: udPurple,
                              title: Text(t.label, style: udText(15, weight: FontWeight.w600)),
                              subtitle: Text(t.about, style: udText(12, color: udBody)),
                            ),
                        ],
                      ),
                    ),
                  if (NoticeType.of(widget.role).isNotEmpty) ...[
                    const SizedBox(height: 24),
                    _heading(Icons.record_voice_over_outlined, 'Speak aloud'),
                    Text('Which alerts are also said aloud, in your voice language (${_language.nativeName}).',
                        style: udText(12, color: udBody)),
                    const SizedBox(height: 8),
                    _card([
                      for (final t in NoticeType.of(widget.role))
                        SwitchListTile(
                          key: Key('notice-speak-${t.code}'),
                          value: _prefs.speaks(widget.role, t.code),
                          onChanged: (on) => _setSpoken(t, on),
                          activeTrackColor: udPurple,
                          title: Text(t.label, style: udText(15, weight: FontWeight.w600)),
                        ),
                      ListTile(
                        key: const Key('notice-voice'),
                        leading: const Icon(Icons.graphic_eq_rounded, color: udPurple),
                        title: Text('Voice', style: udText(15, weight: FontWeight.w600)),
                        subtitle: Text(_prefs.voice == null ? 'Phone\'s usual voice' : voiceLabel(_prefs.voice!),
                            style: udText(12, color: udBody)),
                        trailing: const Icon(Icons.chevron_right_rounded, color: udPurple),
                        onTap: _pickVoice,
                      ),
                    ]),
                    const SizedBox(height: 24),
                    _heading(Icons.bedtime_outlined, 'Quiet hours'),
                    Text('Alerts still come, but silently, and nothing is said aloud.',
                        style: udText(12, color: udBody)),
                    const SizedBox(height: 8),
                    _card([
                      SwitchListTile(
                        key: const Key('notice-quiet'),
                        value: _prefs.hasQuietHours,
                        onChanged: _setQuiet,
                        activeTrackColor: udPurple,
                        title: Text('Quiet hours', style: udText(15, weight: FontWeight.w600)),
                      ),
                      if (_prefs.hasQuietHours) ...[
                        ListTile(
                          key: const Key('notice-quiet-from'),
                          title: Text('From', style: udText(15)),
                          trailing: Text(_time(_prefs.quietFrom!), style: udText(15, weight: FontWeight.w600)),
                          onTap: () => _pickQuiet(from: true),
                        ),
                        ListTile(
                          key: const Key('notice-quiet-to'),
                          title: Text('To', style: udText(15)),
                          trailing: Text(_time(_prefs.quietTo!), style: udText(15, weight: FontWeight.w600)),
                          onTap: () => _pickQuiet(from: false),
                        ),
                      ],
                    ]),
                  ],
                  if (_speaksAny)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 10, 8, 0),
                      child: Text(
                        'Tip: if alerts come but are not spoken while QBOX is closed, open your phone\'s '
                        'Settings, Apps, QBOX, Battery, and choose No restrictions (or Allow background activity).',
                        key: const Key('notice-speak-tip'),
                        style: udText(12, color: udBody),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _heading(IconData icon, String text) => Padding(
    padding: const EdgeInsets.only(bottom: 4),
    child: Row(
      children: [
        Icon(icon, color: udPurple, size: 20),
        const SizedBox(width: 8),
        Text(text, style: udText(16, weight: FontWeight.w700)),
      ],
    ),
  );

  Widget _card(List<Widget> children) => Material(
    color: Colors.white,
    borderRadius: BorderRadius.circular(20),
    clipBehavior: Clip.antiAlias,
    child: Column(children: children),
  );
}

/// How a chosen phone voice is shown in the settings ("te-in-x-tem-network" needs internet).
String voiceLabel(String name) => name.contains('network') ? 'Chosen voice (needs internet)' : 'Chosen voice';

/// The phone's voices for the voice language, each with a sample to hear first.
/// Pops the chosen name; '' = the phone's usual voice.
class _VoiceSheet extends StatelessWidget {
  const _VoiceSheet({required this.voices, required this.current, required this.language, required this.onPlay});

  final List<String> voices;
  final String? current;
  final AppLanguage language;
  final Future<void> Function(String? voice) onPlay;

  @override
  Widget build(BuildContext context) {
    Widget row(String? voice, String title, String? subtitle) => ListTile(
      key: Key('voice-${voice ?? 'usual'}'),
      leading: Icon(
        (voice ?? '') == (current ?? '') ? Icons.radio_button_checked_rounded : Icons.radio_button_off_rounded,
        color: udPurple,
      ),
      title: Text(title, style: udText(15, weight: FontWeight.w600)),
      subtitle: subtitle == null ? null : Text(subtitle, style: udText(12, color: udBody)),
      trailing: IconButton(
        key: Key('voice-play-${voice ?? 'usual'}'),
        icon: const Icon(Icons.play_circle_outline_rounded, color: udPurple, size: 30),
        tooltip: 'Hear it',
        onPressed: () => onPlay(voice),
      ),
      onTap: () => Navigator.of(context).pop(voice ?? ''),
    );
    return SafeArea(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
        child: ListView(
          shrinkWrap: true,
          padding: const EdgeInsets.symmetric(vertical: 12),
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
              child: Text('Voice for alerts (${language.nativeName})', style: udText(17, weight: FontWeight.w700)),
            ),
            row(null, 'Phone\'s usual voice', null),
            for (final (i, v) in voices.indexed)
              row(v, 'Voice ${i + 1}', v.contains('network') ? 'Needs internet' : null),
            if (voices.isEmpty)
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
                child: Text(
                  'This phone has no other voices for ${language.nativeName}. More can be added in the phone\'s '
                  'Settings, Text-to-speech, Google, Install voice data.',
                  key: const Key('voice-none'),
                  style: udText(12, color: udBody),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
