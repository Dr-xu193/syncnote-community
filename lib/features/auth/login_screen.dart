import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:syncnote/core/providers/auth_provider.dart';
import 'package:syncnote/features/settings/community_setup_screen.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _fadeIn;
  late final Animation<Offset> _slideUp;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );

    _fadeIn = CurvedAnimation(
      parent: _controller,
      curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
    );

    _slideUp = Tween<Offset>(begin: const Offset(0, 0.08), end: Offset.zero)
        .animate(
          CurvedAnimation(
            parent: _controller,
            curve: const Interval(0.0, 0.7, curve: Curves.easeOut),
          ),
        );

    // Start the entrance animation after the first frame.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _controller.forward();
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<void> _handleGoogleSignIn(BuildContext context) async {
    final authProvider = context.read<AuthProvider>();
    await authProvider.signInWithGoogle();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);

    return Scaffold(
      body: Stack(
        children: [
          // Background gradient -----------------------------------------------
          _GradientBackground(size: size),

          // Decorative glowing circles ----------------------------------------
          _DecorativeBlobs(size: size),

          // Content -----------------------------------------------------------
          SafeArea(
            child: Center(
              child: SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 32),
                child: FadeTransition(
                  opacity: _fadeIn,
                  child: SlideTransition(
                    position: _slideUp,
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 400),
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const SizedBox(height: 40),

                          // Logo --------------------------------------------
                          _AppLogo(),

                          const SizedBox(height: 32),

                          // App name ----------------------------------------
                          Text(
                            'SyncNote Community',
                            style: GoogleFonts.inter(
                              fontSize: 40,
                              fontWeight: FontWeight.w800,
                              color: Colors.white,
                              letterSpacing: -1.0,
                            ),
                          ),

                          const SizedBox(height: 10),

                          // Tagline -----------------------------------------
                          Text(
                            '随手记录，随时同步',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w400,
                              color: Colors.white.withValues(alpha: 0.65),
                              letterSpacing: 1.5,
                            ),
                          ),

                          const SizedBox(height: 64),

                          // Google sign-in button ---------------------------
                          _GoogleSignInButton(onPressed: _handleGoogleSignIn),

                          const SizedBox(height: 20),

                          // Error message -----------------------------------
                          _ErrorMessage(),

                          const SizedBox(height: 16),
                          TextButton.icon(
                            onPressed: () => Navigator.of(context).push(
                              MaterialPageRoute<void>(
                                builder: (_) => const CommunitySetupScreen(),
                              ),
                            ),
                            icon: const Icon(Icons.settings_outlined),
                            label: const Text('服务配置'),
                          ),
                          const SizedBox(height: 40),

                          // Footer text -------------------------------------
                          Text(
                            '登录将连接你配置的 Firebase 项目。服务政策请参考相应提供商。',
                            textAlign: TextAlign.center,
                            style: GoogleFonts.inter(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.4),
                              height: 1.6,
                            ),
                          ),

                          const SizedBox(height: 40),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Background gradient
// ---------------------------------------------------------------------------

class _GradientBackground extends StatelessWidget {
  const _GradientBackground({required this.size});

  final Size size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size.width,
      height: size.height,
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          stops: [0.0, 0.45, 1.0],
          colors: [Color(0xFF0D0B1A), Color(0xFF1A1035), Color(0xFF0E0820)],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Decorative glowing blobs
// ---------------------------------------------------------------------------

class _DecorativeBlobs extends StatelessWidget {
  const _DecorativeBlobs({required this.size});

  final Size size;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        // Top-left blob
        Positioned(
          top: -size.height * 0.15,
          left: -size.width * 0.2,
          child: Container(
            width: size.width * 0.7,
            height: size.width * 0.7,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(0xFF6C63FF).withValues(alpha: 0.25),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        // Bottom-right blob
        Positioned(
          bottom: -size.height * 0.1,
          right: -size.width * 0.25,
          child: Container(
            width: size.width * 0.75,
            height: size.width * 0.75,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  const Color(0xFF9C27B0).withValues(alpha: 0.2),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
        // Centre subtle glow
        Positioned(
          top: size.height * 0.35,
          left: size.width * 0.2,
          right: size.width * 0.2,
          child: Container(
            height: size.height * 0.3,
            decoration: BoxDecoration(
              gradient: RadialGradient(
                colors: [
                  const Color(0xFF6C63FF).withValues(alpha: 0.08),
                  Colors.transparent,
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// App logo
// ---------------------------------------------------------------------------

class _AppLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Stack(
      alignment: Alignment.center,
      children: [
        // Outer glow ring
        Container(
          width: 108,
          height: 108,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            gradient: RadialGradient(
              colors: [
                const Color(0xFF6C63FF).withValues(alpha: 0.35),
                Colors.transparent,
              ],
            ),
          ),
        ),
        // Icon container
        Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(24),
            gradient: const LinearGradient(
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
              colors: [Color(0xFF8A82FF), Color(0xFF6C63FF), Color(0xFF5147E8)],
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF6C63FF).withValues(alpha: 0.6),
                blurRadius: 30,
                spreadRadius: 2,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: const Icon(Icons.sync_rounded, color: Colors.white, size: 44),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Google sign-in button
// ---------------------------------------------------------------------------

class _GoogleSignInButton extends StatefulWidget {
  const _GoogleSignInButton({required this.onPressed});

  final Future<void> Function(BuildContext) onPressed;

  @override
  State<_GoogleSignInButton> createState() => _GoogleSignInButtonState();
}

class _GoogleSignInButtonState extends State<_GoogleSignInButton> {
  bool _isHovering = false;

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        final isLoading = auth.isLoading;

        return MouseRegion(
          onEnter: (_) => setState(() => _isHovering = true),
          onExit: (_) => setState(() => _isHovering = false),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            curve: Curves.easeInOut,
            transform: Matrix4.identity()
              ..translateByDouble(
                0.0,
                _isHovering && !isLoading ? -2.0 : 0.0,
                0.0,
                1.0,
              ),
            child: SizedBox(
              width: double.infinity,
              height: 58,
              child: ElevatedButton(
                onPressed: isLoading ? null : () => widget.onPressed(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.white,
                  foregroundColor: const Color(0xFF3C4043),
                  disabledBackgroundColor: Colors.white.withValues(alpha: 0.85),
                  elevation: _isHovering ? 8 : 4,
                  shadowColor: const Color(0xFF6C63FF).withValues(alpha: 0.3),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(16),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                ),
                child: isLoading
                    ? const SizedBox(
                        width: 24,
                        height: 24,
                        child: CircularProgressIndicator(
                          strokeWidth: 2.5,
                          valueColor: AlwaysStoppedAnimation<Color>(
                            Color(0xFF6C63FF),
                          ),
                        ),
                      )
                    : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          // Google 'G' logo (coloured text representation)
                          _GoogleLogo(),
                          const SizedBox(width: 14),
                          Text(
                            '使用 Google 账号登录',
                            style: GoogleFonts.inter(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: const Color(0xFF3C4043),
                              letterSpacing: 0.2,
                            ),
                          ),
                        ],
                      ),
              ),
            ),
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// Google 'G' logo painted with CustomPaint
// ---------------------------------------------------------------------------

class _GoogleLogo extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 24,
      height: 24,
      child: CustomPaint(painter: _GoogleLogoPainter()),
    );
  }
}

class _GoogleLogoPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final cx = size.width / 2;
    final cy = size.height / 2;
    final r = math.min(cx, cy);

    // Colours from the official Google logo
    const blue = Color(0xFF4285F4);
    const red = Color(0xFFEA4335);
    const yellow = Color(0xFFFBBC05);
    const green = Color(0xFF34A853);

    final paint = Paint()..style = PaintingStyle.fill;

    // Draw four coloured arcs to approximate the G shape
    final rect = Rect.fromCircle(center: Offset(cx, cy), radius: r);

    // Red arc (top-right, going counter-clockwise)
    paint.color = red;
    canvas.drawArc(rect, -math.pi / 2, -math.pi / 2, true, paint);

    // Blue arc (top-left)
    paint.color = blue;
    canvas.drawArc(rect, math.pi, -math.pi / 2, true, paint);

    // Green arc (bottom-right)
    paint.color = green;
    canvas.drawArc(rect, 0, math.pi / 2, true, paint);

    // Yellow arc (bottom-left)
    paint.color = yellow;
    canvas.drawArc(rect, math.pi / 2, math.pi / 2, true, paint);

    // White centre
    paint.color = Colors.white;
    canvas.drawCircle(Offset(cx, cy), r * 0.6, paint);

    // White horizontal bar (right half of the G)
    canvas.drawRect(
      Rect.fromLTRB(cx, cy - r * 0.18, cx + r, cy + r * 0.18),
      paint,
    );
  }

  @override
  bool shouldRepaint(_GoogleLogoPainter oldDelegate) => false;
}

// ---------------------------------------------------------------------------
// Error message
// ---------------------------------------------------------------------------

class _ErrorMessage extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, auth, _) {
        final error = auth.errorMessage;
        if (error == null || error.isEmpty) return const SizedBox.shrink();

        return AnimatedOpacity(
          opacity: 1.0,
          duration: const Duration(milliseconds: 300),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            decoration: BoxDecoration(
              color: const Color(0xFFEF5350).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: const Color(0xFFEF5350).withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                const Icon(
                  Icons.error_outline_rounded,
                  color: Color(0xFFEF5350),
                  size: 18,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    error,
                    style: GoogleFonts.inter(
                      fontSize: 13,
                      color: const Color(0xFFEF9090),
                      height: 1.4,
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
}
