import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:syncnote/shared/services/ai_service.dart';

/// Adds the same SyncNote AI entry to editable and read-only text selections.
///
/// Editable fields can replace their original selection after an AI action;
/// read-only content (for example, AI chat messages) exposes the result in a
/// copyable preview instead.
class AiContextMenuHelper {
  static Widget editableTextContextMenuBuilder(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: editableTextState.contextMenuAnchors,
      buttonItems: buildButtonItems(context, editableTextState),
    );
  }

  /// Builds the custom text selection toolbar items including SyncNote AI.
  static List<ContextMenuButtonItem> buildButtonItems(
    BuildContext context,
    EditableTextState editableTextState,
  ) {
    final buttonItems = List<ContextMenuButtonItem>.from(
      editableTextState.contextMenuButtonItems,
    );
    final textValue = editableTextState.textEditingValue;
    final selectedText = textValue.selection.textInside(textValue.text).trim();

    if (selectedText.isNotEmpty) {
      final selection = textValue.selection;
      buttonItems.insert(
        0,
        ContextMenuButtonItem(
          label: '✨ SyncNote AI',
          onPressed: () {
            ContextMenuController.removeAny();
            _showAiMenu(
              editableTextState.context,
              selectedText,
              onAccept: (replacement) {
                if (!editableTextState.mounted) return;
                final currentValue = editableTextState.textEditingValue;
                final start = selection.start.clamp(
                  0,
                  currentValue.text.length,
                );
                final end = selection.end.clamp(
                  start,
                  currentValue.text.length,
                );
                final newText = currentValue.text.replaceRange(
                  start,
                  end,
                  replacement,
                );
                editableTextState.userUpdateTextEditingValue(
                  TextEditingValue(
                    text: newText,
                    selection: TextSelection.collapsed(
                      offset: start + replacement.length,
                    ),
                  ),
                  SelectionChangedCause.keyboard,
                );
              },
            );
          },
        ),
      );
    }
    return buttonItems;
  }

  /// Builds a context menu for text selected through [SelectionArea].
  static Widget selectableRegionContextMenuBuilder(
    BuildContext context,
    SelectableRegionState selectableRegionState,
    String selectedText,
  ) {
    final buttonItems = List<ContextMenuButtonItem>.from(
      selectableRegionState.contextMenuButtonItems,
    );
    final normalizedText = selectedText.trim();
    if (normalizedText.isNotEmpty) {
      buttonItems.insert(
        0,
        ContextMenuButtonItem(
          label: '✨ SyncNote AI',
          onPressed: () {
            ContextMenuController.removeAny();
            _showAiMenu(context, normalizedText);
          },
        ),
      );
    }
    return AdaptiveTextSelectionToolbar.buttonItems(
      anchors: selectableRegionState.contextMenuAnchors,
      buttonItems: buttonItems,
    );
  }

  static void _showAiMenu(
    BuildContext context,
    String selectedText, {
    ValueChanged<String>? onAccept,
  }) {
    showModalBottomSheet(
      context: context,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (bottomSheetContext) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  'SyncNote AI 文本助手',
                  style: Theme.of(bottomSheetContext).textTheme.titleMedium
                      ?.copyWith(fontWeight: FontWeight.bold),
                ),
              ),
              const Divider(height: 1),
              _AiActionTile(
                icon: Icons.auto_fix_high_rounded,
                color: Colors.purple,
                title: '智能润色',
                subtitle: '修复语法和错别字，优化表达与排版。',
                onTap: () => _startAction(
                  bottomSheetContext,
                  context,
                  selectedText,
                  'polish',
                  onAccept,
                ),
              ),
              _AiActionTile(
                icon: Icons.format_list_bulleted_rounded,
                color: Colors.blue,
                title: '结构化整理',
                subtitle: '提炼核心要点，并整理为清晰的列表。',
                onTap: () => _startAction(
                  bottomSheetContext,
                  context,
                  selectedText,
                  'structure',
                  onAccept,
                ),
              ),
              _AiActionTile(
                icon: Icons.translate_rounded,
                color: Colors.green,
                title: '中英互译',
                subtitle: '自动识别中文或英文并进行翻译。',
                onTap: () => _startAction(
                  bottomSheetContext,
                  context,
                  selectedText,
                  'translate',
                  onAccept,
                ),
              ),
              _AiActionTile(
                icon: Icons.add_circle_outline_rounded,
                color: Colors.orange,
                title: '扩写内容',
                subtitle: '补充必要的背景、细节和论据。',
                onTap: () => _startAction(
                  bottomSheetContext,
                  context,
                  selectedText,
                  'expand',
                  onAccept,
                ),
              ),
              const SizedBox(height: 8),
            ],
          ),
        );
      },
    );
  }

  static void _startAction(
    BuildContext bottomSheetContext,
    BuildContext context,
    String selectedText,
    String action,
    ValueChanged<String>? onAccept,
  ) {
    Navigator.of(bottomSheetContext).pop();
    _runAiAction(context, selectedText, action, onAccept: onAccept);
  }

  static Future<void> _runAiAction(
    BuildContext context,
    String selectedText,
    String action, {
    ValueChanged<String>? onAccept,
  }) async {
    BuildContext? dialogContext;
    final dialogNavigator = Navigator.of(context, rootNavigator: true);
    showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogBuildContext) {
        dialogContext = dialogBuildContext;
        return const AlertDialog(
          content: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(width: 16),
              Text('AI 正在处理选中的文本…'),
            ],
          ),
        );
      },
    );

    final prompt = _promptFor(action, selectedText);
    try {
      final result = await AIService.instance.requestCustomPrompt(prompt);
      if ((dialogContext?.mounted ?? false) && dialogNavigator.mounted) {
        dialogNavigator.pop();
      }

      if (result == null || result.trim().isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('AI 操作未返回结果，请检查网络后重试。')));
        }
        return;
      }
      if (context.mounted) {
        _showResultPreviewDialog(context, result.trim(), onAccept: onAccept);
      }
    } catch (error) {
      if ((dialogContext?.mounted ?? false) && dialogNavigator.mounted) {
        dialogNavigator.pop();
      }
      if (context.mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('AI 处理出错：$error')));
      }
    }
  }

  static String _promptFor(String action, String selectedText) {
    switch (action) {
      case 'polish':
        return '你是一名中文文字润色专家。请修正错别字、语法问题并优化表达和分段。直接输出润色后的文本，不要解释：\n\n$selectedText';
      case 'structure':
        return '你是一名知识整理专家。请提取以下文本的核心要点，整理为清晰的 Markdown 列表，并标出可执行的待办事项。直接输出结果，不要解释：\n\n$selectedText';
      case 'translate':
        return '你是一名专业翻译。若以下文本为中文则译为自然英文，若为英文则译为自然中文。直接输出译文，不要解释：\n\n$selectedText';
      case 'expand':
        return '请对以下文本进行合理扩写，补充必要的背景、细节或论据，并以 Markdown 输出。直接输出结果，不要添加引言：\n\n$selectedText';
      default:
        return selectedText;
    }
  }

  static void _showResultPreviewDialog(
    BuildContext context,
    String aiResultText, {
    ValueChanged<String>? onAccept,
  }) {
    final textController = TextEditingController(text: aiResultText);
    showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Row(
          children: [
            Icon(Icons.auto_awesome, color: Colors.purple),
            SizedBox(width: 8),
            Text('SyncNote AI 处理结果'),
          ],
        ),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: textController,
            contextMenuBuilder: editableTextContextMenuBuilder,
            maxLines: 12,
            minLines: 5,
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          if (onAccept == null)
            TextButton.icon(
              onPressed: () async {
                await Clipboard.setData(
                  ClipboardData(text: textController.text),
                );
                if (dialogContext.mounted) Navigator.of(dialogContext).pop();
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('AI 结果已复制。')));
                }
              },
              icon: const Icon(Icons.copy_rounded),
              label: const Text('复制结果'),
            )
          else
            ElevatedButton(
              onPressed: () {
                final replacement = textController.text;
                Navigator.of(dialogContext).pop();
                onAccept(replacement);
                if (context.mounted) {
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('已替换选中的文本。')));
                }
              },
              child: const Text('替换选中文本'),
            ),
        ],
      ),
    );
  }
}

class AiSelectionArea extends StatefulWidget {
  const AiSelectionArea({required this.child, super.key});

  final Widget child;

  @override
  State<AiSelectionArea> createState() => _AiSelectionAreaState();
}

class _AiSelectionAreaState extends State<AiSelectionArea> {
  String _selectedText = '';

  @override
  Widget build(BuildContext context) {
    return SelectionArea(
      onSelectionChanged: (content) {
        _selectedText = content?.plainText ?? '';
      },
      contextMenuBuilder: (context, selectableRegionState) =>
          AiContextMenuHelper.selectableRegionContextMenuBuilder(
            context,
            selectableRegionState,
            _selectedText,
          ),
      child: widget.child,
    );
  }
}

class _AiActionTile extends StatelessWidget {
  const _AiActionTile({
    required this.icon,
    required this.color,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final IconData icon;
  final Color color;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => ListTile(
    leading: Icon(icon, color: color),
    title: Text(title),
    subtitle: Text(subtitle),
    onTap: onTap,
  );
}
