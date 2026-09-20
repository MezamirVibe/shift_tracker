import 'package:flutter/material.dart';

/// Centers short forms, but lets the whole form scroll above the keyboard.
class ResponsiveFormBody extends StatelessWidget {
  final Widget child;
  final double maxWidth;
  const ResponsiveFormBody(
      {super.key, required this.child, this.maxWidth = 420});

  @override
  Widget build(BuildContext context) => SafeArea(
        child: LayoutBuilder(
            builder: (context, constraints) => SingleChildScrollView(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  padding: const EdgeInsets.all(16),
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                        minHeight: (constraints.maxHeight - 32)
                            .clamp(0, double.infinity)),
                    child: Center(
                        child: ConstrainedBox(
                            constraints: BoxConstraints(maxWidth: maxWidth),
                            child: child)),
                  ),
                )),
      );
}
