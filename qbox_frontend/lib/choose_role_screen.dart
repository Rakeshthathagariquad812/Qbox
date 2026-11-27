import 'dart:async';

import 'package:flutter/material.dart';

import 'widgets/qbox_brand.dart';

import 'customer_home_screen.dart';
import 'onboarding_draft.dart';
import 'profile/log_out.dart';
import 'profile/notices_screen.dart';
import 'services/app_services.dart';
import 'services/push_notifications.dart';
import 'shop_home_screen.dart';
import 'supplier_home_screen.dart';
import 'widgets/qbox_wave.dart';
import 'widgets/signup_column.dart';
import 'widgets/signup_motion.dart';
import 'widgets/signup_route.dart';

/// Shown after login. Only the roles picked during signup are listed.
class ChooseRoleScreen extends StatefulWidget {
  const ChooseRoleScreen({super.key});

  @override
  State<ChooseRoleScreen> createState() => _ChooseRoleScreenState();
}

class _ChooseRoleScreenState extends State<ChooseRoleScreen> {
  bool _reminded = false;
  PushNotifications? _push;

  /// Just logged in, or QBOX was opened: calendar reminders are set again, and
  /// this phone gets push notifications.
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reminded) return;
    _reminded = true;
    final services = context.getInheritedWidgetOfExactType<ServicesScope>()?.services;
    if (services == null) return;
    unawaited(services.calendar.remindAgain(OnboardingScope.of(context).orderedRoles()));
    _push = services.push..opened.addListener(_openBell);
    unawaited(services.push.start());
    WidgetsBinding.instance.addPostFrameCallback((_) => _openBell());
  }

  @override
  void dispose() {
    _push?.opened.removeListener(_openBell);
    super.dispose();
  }

  /// A push notification was tapped: that role's home, then its bell.
  void _openBell() {
    final role = _push?.opened.value;
    if (role == null || !mounted) return;
    if (!OnboardingScope.of(context).orderedRoles().contains(role)) return;
    final navigator = Navigator.of(context);
    navigator.popUntil((route) => route.isFirst);
    unawaited(navigator.push(signupRoute(_home(role))));
    unawaited(navigator.push(MaterialPageRoute<void>(builder: (_) => NoticesScreen(role: role))));
    _push?.handled();
  }

  static Widget _home(QboxRole role) => switch (role) {
    QboxRole.business => const ShopHomeScreen(),
    QboxRole.customer => const CustomerHomeScreen(),
    QboxRole.supplier => const SupplierHomeScreen(),
  };

  @override
  Widget build(BuildContext context) {
    final roles = OnboardingScope.of(context).orderedRoles();
    return Scaffold(
      backgroundColor: const Color(0xFFF7F4FF),
      body: Stack(
        children: [
          const Align(
            alignment: Alignment.bottomCenter,
            child: QboxWaveFooter(),
          ),
          SafeArea(
            bottom: false,
            child: SignupMotionHost(
              child: SignupColumn(
                padding: const EdgeInsets.fromLTRB(20, 28, 20, 108),
                children: [
                  const QboxWordmark(fontSize: 34, letterSpacing: 0.6, textAlign: TextAlign.center),
                  const SizedBox(height: 22),
                  const Text(
                    'Choose Your Role',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 26,
                      height: 1.2,
                      fontWeight: FontWeight.w700,
                      color: _ink,
                    ),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Select how you want to use QBOX',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontFamily: 'Poppins',
                      fontSize: 15,
                      height: 1.4,
                      fontWeight: FontWeight.w500,
                      color: _body,
                    ),
                  ),
                  const SizedBox(height: 24),
                  for (final role in roles) ...[
                    _RoleChoice(
                      role: role,
                      onTap: switch (role) {
                        QboxRole.business => () {
                            Navigator.of(context).push(
                              signupRoute(const ShopHomeScreen()),
                            );
                          },
                        QboxRole.customer => () {
                            Navigator.of(context).push(
                              signupRoute(const CustomerHomeScreen()),
                            );
                          },
                        QboxRole.supplier => () {
                            Navigator.of(context).push(
                              signupRoute(const SupplierHomeScreen()),
                            );
                          },
                      },
                    ),
                    if (role != roles.last) const SizedBox(height: 16),
                  ],
                  const SizedBox(height: 20),
                  Center(
                    child: TextButton.icon(
                      key: const Key('log-out'),
                      onPressed: () => logOut(context),
                      icon: const Icon(Icons.logout, size: 18),
                      label: const Text('Log out'),
                      style: TextButton.styleFrom(
                        foregroundColor: _purple,
                        textStyle: const TextStyle(
                          fontFamily: 'Poppins',
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _RoleChoice extends StatelessWidget {
  const _RoleChoice({required this.role, this.onTap});

  final QboxRole role;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final details = _details[role]!;
    final card = Container(
      constraints: const BoxConstraints(minHeight: 128),
      padding: const EdgeInsets.fromLTRB(8, 10, 6, 10),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFFE6E0F2)),
        boxShadow: const [
          BoxShadow(
            color: Color(0x120E1B4D),
            blurRadius: 14,
            offset: Offset(0, 6),
          ),
        ],
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          SizedBox(
            width: 118,
            height: 108,
            child: Image(
              image: AssetImage(details.asset),
              fit: BoxFit.contain,
              alignment: Alignment.center,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  details.title,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontSize: 17,
                    height: 1.2,
                    fontWeight: FontWeight.w700,
                    color: _ink,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  details.subtitle,
                  style: const TextStyle(
                    fontFamily: 'Poppins',
                    fontSize: 13,
                    height: 1.35,
                    fontWeight: FontWeight.w500,
                    color: _body,
                  ),
                ),
              ],
            ),
          ),
          const Icon(Icons.chevron_right, color: _purple, size: 26),
        ],
      ),
    );
    if (onTap == null) return card;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(20),
        child: card,
      ),
    );
  }
}

class _RoleDetails {
  const _RoleDetails(this.asset, this.title, this.subtitle);

  final String asset;
  final String title;
  final String subtitle;
}

const _details = {
  QboxRole.business: _RoleDetails(
    'assets/images/art_shop.png',
    'Business / Shop',
    'Run your shop, manage sales, stock, udhaar and more',
  ),
  QboxRole.customer: _RoleDetails(
    'assets/images/art_customer.png',
    'Customer',
    'Track purchases, manage udhaar and make payments',
  ),
  QboxRole.supplier: _RoleDetails(
    'assets/images/art_supplier.png',
    'Supplier',
    'Manage orders, merchants, products and ledger',
  ),
};

const _ink = Color(0xFF1C0E57);
const _body = Color(0xFF5C5872);
const _purple = Color(0xFF651CE4);
