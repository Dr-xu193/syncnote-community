import 'package:flutter/material.dart';

enum _NullableStringFilterChoice { all }

/// A popup filter whose explicit "all" option is reported as `null`.
///
/// [PopupMenuButton] treats a popped `null` value as cancellation and skips
/// `onSelected`. This widget uses a non-null sentinel internally so choosing
/// "all" always invokes [onSelected].
class NullableStringFilterMenu extends StatelessWidget {
  const NullableStringFilterMenu({
    required this.values,
    required this.selectedValue,
    required this.allLabel,
    required this.onSelected,
    required this.child,
    this.tooltip,
    super.key,
  });

  final List<String> values;
  final String? selectedValue;
  final String allLabel;
  final ValueChanged<String?> onSelected;
  final Widget child;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<Object>(
      tooltip: tooltip,
      initialValue: selectedValue ?? _NullableStringFilterChoice.all,
      onSelected: (value) {
        onSelected(value is String ? value : null);
      },
      itemBuilder: (_) => [
        PopupMenuItem<Object>(
          value: _NullableStringFilterChoice.all,
          child: Text(allLabel),
        ),
        ...values.map(
          (value) => PopupMenuItem<Object>(value: value, child: Text(value)),
        ),
      ],
      child: child,
    );
  }
}
