import 'package:appflowy/features/assistant/data/assistant_models.dart';
import 'package:appflowy/features/assistant/logic/action_handler.dart';
import 'package:appflowy/generated/locale_keys.g.dart';
import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';

/// One row per proposed action: checkbox, text, before -> after, and a field
/// per editable key. Destructive rows are error-coloured. Defaults come from
/// [Proposal.ticked] / [Proposal.edits].
class ProposalPreview extends StatefulWidget {
  const ProposalPreview({
    super.key,
    required this.proposal,
    required this.describe,
    required this.onApply,
  });

  final Proposal proposal;
  final ActionPreview Function(AssistAction) describe;
  final void Function(Set<int> ticked, Map<int, Map<String, dynamic>> edits)
      onApply;

  @override
  State<ProposalPreview> createState() => _ProposalPreviewState();
}

class _ProposalPreviewState extends State<ProposalPreview> {
  late final Set<int> _ticked = {...widget.proposal.ticked};
  late final Map<int, Map<String, dynamic>> _edits = {
    for (final e in widget.proposal.edits.entries) e.key: {...e.value},
  };
  final _controllers = <(int, String), TextEditingController>{};

  @override
  void dispose() {
    for (final c in _controllers.values) {
      c.dispose();
    }
    super.dispose();
  }

  /// A key missing from the action's fields may be one of its `cells`.
  TextEditingController _controller(int i, String key) =>
      _controllers.putIfAbsent((i, key), () {
        final f = widget.proposal.actions[i].fields;
        final v = _edits[i]?[key] ?? f[key] ?? (f['cells'] as Map?)?[key];
        return TextEditingController(text: v?.toString() ?? '');
      });

  Widget _row(int i) {
    final a = widget.proposal.actions[i];
    final p = widget.describe(a);
    final color = p.destructive ? Theme.of(context).colorScheme.error : null;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Checkbox(
          value: _ticked.contains(i),
          onChanged: (v) => setState(
            () => v == true ? _ticked.add(i) : _ticked.remove(i),
          ),
        ),
        Expanded(
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(p.text, style: TextStyle(color: color)),
                if (p.before != null || p.after != null)
                  Text(
                    '${p.before ?? ''} → ${p.after ?? ''}',
                    style: TextStyle(
                      fontSize: 12,
                      color: color ?? Theme.of(context).hintColor,
                    ),
                  ),
                for (final key in p.editable)
                  TextField(
                    controller: _controller(i, key),
                    decoration: InputDecoration(
                      isDense: true,
                      // A cell's box is named after its field.
                      labelText:
                          (a.fields['cells'] as Map?)?.containsKey(key) ?? false
                              ? widget.proposal.labels[key]
                              : null,
                    ),
                    onChanged: (v) => _edits.putIfAbsent(i, () => {})[key] = v,
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (var i = 0; i < widget.proposal.actions.length; i++) _row(i),
            ],
          ),
        ),
        const SizedBox(height: 8),
        FilledButton(
          onPressed: _ticked.isEmpty
              ? null
              : () => widget.onApply(
                    {..._ticked},
                    {
                      for (final e in _edits.entries)
                        if (_ticked.contains(e.key)) e.key: e.value,
                    },
                  ),
          child: Text(LocaleKeys.assistant_applySelected.tr()),
        ),
      ],
    );
  }
}
