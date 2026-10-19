import 'package:appflowy/features/assistant/logic/assistant_service.dart';
import 'package:flutter/material.dart';

/// Shows [builder] only while Ask InkNest is available, and hides it live when
/// the switch is turned off.
class AssistantAvailabilityBuilder extends StatefulWidget {
  const AssistantAvailabilityBuilder({super.key, required this.builder});

  final WidgetBuilder builder;

  @override
  State<AssistantAvailabilityBuilder> createState() =>
      _AssistantAvailabilityBuilderState();
}

class _AssistantAvailabilityBuilderState
    extends State<AssistantAvailabilityBuilder> {
  @override
  void initState() {
    super.initState();
    AssistantService.isAvailable().catchError((_) => false);
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: AssistantService.availability,
      builder: (context, ok, _) =>
          ok ? widget.builder(context) : const SizedBox.shrink(),
    );
  }
}
