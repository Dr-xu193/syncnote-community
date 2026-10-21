import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:google_generative_ai/google_generative_ai.dart';
import 'package:syncnote/core/app_config.dart';
import 'package:syncnote/shared/models/task_model.dart';
import 'package:syncnote/shared/models/diary_model.dart';
import 'package:http/http.dart' as http;
import 'package:youtube_explode_dart/youtube_explode_dart.dart' as yt_explode;

enum SummaryStyle { outline, insight, actionable }

// ---------------------------------------------------------------------------
// AIService — singleton
// ---------------------------------------------------------------------------

/// DeepSeek Flash AI service; Gemini Flash is used only for audio transcription.
///
/// Features:
/// - Note summarisation (Chinese output)
/// - Subtask suggestion (Chinese output)
/// - Task prioritisation
/// - Semantic / smart search
///
/// All public methods return `null` / empty collections on error so that
/// callers do not need to handle exceptions.
///
/// Rate limiting: a simple in-memory counter resets every calendar day
/// (UTC). The limit comes from [AppConfig.maxDailyAiRequests].
class AIService {
  AIService._() {
    _model = GenerativeModel(
      model: AppConfig.geminiModel,
      apiKey: AppConfig.geminiApiKey,
      generationConfig: GenerationConfig(
        temperature: 0.2,
        maxOutputTokens: 8192,
      ),
    );
  }

  /// The single shared instance.
  static final AIService instance = AIService._();

  late final GenerativeModel _model;

  static String _clipSourceText(String text, {int maxLength = 8000}) {
    return text.length > maxLength
        ? '${text.substring(0, maxLength)}...'
        : text;
  }

  @visibleForTesting
  static List<Map<String, dynamic>> buildDailyBriefingDiaryPayload(
    List<DiaryEntry> recentDiaries,
  ) {
    return recentDiaries
        .map(
          (d) => {
            'date': d.date.toIso8601String().split('T').first,
            'content': d.content,
            'mood': d.mood.name,
          },
        )
        .toList();
  }

  @visibleForTesting
  static List<Map<String, dynamic>> buildEveningReflectionDiaryPayload(
    List<DiaryEntry> todayDiaries,
  ) {
    return todayDiaries
        .map((d) => {'content': d.content, 'mood': d.mood.name})
        .toList();
  }

  // ── Rate-limiting state ──────────────────────────────────────────────────

  int _requestCount = 0;
  DateTime _windowDate = _todayUtc();

  static DateTime _todayUtc() {
    final now = DateTime.now().toUtc();
    return DateTime.utc(now.year, now.month, now.day);
  }

  /// Returns `true` if the daily quota has not been exceeded.
  bool get _hasQuota {
    final today = _todayUtc();
    if (today != _windowDate) {
      // New calendar day — reset the counter.
      _windowDate = today;
      _requestCount = 0;
    }
    return _requestCount < AppConfig.maxDailyAiRequests;
  }

  /// Increments the request counter.
  void _consumeQuota() => _requestCount++;

  // ── Internal helper ──────────────────────────────────────────────────────

  /// Sends [prompt] to DeepSeek Flash and returns the trimmed text response.
  ///
  /// Returns `null` if the quota is exceeded or if an error occurs.
  Future<String?> _generate(
    String prompt, {
    Uint8List? imageBytes,
    bool useThinking = false,
  }) async {
    if (!_hasQuota) return null;

    const maxRetries = 3;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        if (attempt == 1) {
          _consumeQuota();
        }

        final List<Map<String, dynamic>> requestMessages;
        if (imageBytes != null) {
          final base64Image = base64Encode(imageBytes);
          requestMessages = [
            {
              'role': 'user',
              'content': [
                {'type': 'text', 'text': prompt},
                {
                  'type': 'image_url',
                  'image_url': {'url': 'data:image/jpeg;base64,$base64Image'},
                },
              ],
            },
          ];
        } else {
          requestMessages = [
            {'role': 'user', 'content': prompt},
          ];
        }

        final requestBody = {
          'model': AppConfig.deepseekModel,
          'messages': requestMessages,
          'thinking': {'type': useThinking ? 'enabled' : 'disabled'},
          if (useThinking) 'reasoning_effort': 'high',
          if (!useThinking) 'temperature': 0.4,
          'max_tokens': useThinking ? 12000 : 8192,
        };

        final response = await http
            .post(
              Uri.parse(AppConfig.deepseekBaseUrl),
              headers: {
                'Content-Type': 'application/json; charset=utf-8',
                'Authorization': 'Bearer ${AppConfig.deepseekApiKey}',
              },
              body: jsonEncode(requestBody),
            )
            .timeout(Duration(seconds: useThinking ? 90 : 30));

        if (response.statusCode == 200) {
          final Map<String, dynamic> jsonResponse = jsonDecode(
            utf8.decode(response.bodyBytes),
          );
          final List<dynamic>? choices = jsonResponse['choices'];
          if (choices != null && choices.isNotEmpty) {
            final String? content = choices.first['message']?['content'];
            if (content != null && content.isNotEmpty) {
              return content.trim();
            }
          }
        } else {
          debugPrint(
            '[AIService] DeepSeek status: ${response.statusCode}, Body: ${response.body}',
          );
        }
      } catch (e) {
        debugPrint('[AIService] DeepSeek request attempt $attempt failed: $e');
        if (attempt == maxRetries) {
          assert(() {
            debugPrint(
              '[AIService] DeepSeek error after $maxRetries attempts: $e',
            );
            return true;
          }());
          return null;
        }
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    return null;
  }

  // ==========================================================================
  // PUBLIC API
  // ==========================================================================

  // ── Image OCR ────────────────────────────────────────────────────────────

  /// Extracts text from an image using DeepSeek's vision capabilities.
  Future<String?> extractTextFromImage(Uint8List imageBytes) async {
    const prompt =
        'Please extract all the text from this image exactly as it appears. Do not add any additional commentary.';
    return _generate(prompt, imageBytes: imageBytes);
  }

  // ── Audio Transcription ──────────────────────────────────────────────────

  /// Transcribes audio to Chinese text using Gemini.
  Future<String?> transcribeAudio(Uint8List audioBytes) async {
    if (!_hasQuota) return null;

    const maxRetries = 3;
    for (int attempt = 1; attempt <= maxRetries; attempt++) {
      try {
        if (attempt == 1) {
          _consumeQuota();
        }
        final content = <Part>[
          TextPart(
            '你是一个高精度的语音识别助手。请将此音频文件转写为中文文本。如果是闲聊或不相关的杂音，请返回空。不要输出除了转写结果以外的任何其他内容，也不要包含解释。',
          ),
          DataPart('audio/mp4', audioBytes),
        ];
        final response = await _model
            .generateContent([Content('user', content)])
            .timeout(const Duration(seconds: 60));

        return response.text?.trim();
      } catch (e) {
        debugPrint('[AIService] Audio transcribe attempt $attempt failed: $e');
        if (attempt == maxRetries) {
          assert(() {
            debugPrint('[AIService] Audio transcribe error: $e');
            return true;
          }());
          return null;
        }
        await Future.delayed(const Duration(seconds: 1));
      }
    }
    return null;
  }

  // ── Web Summarization ──────────────────────────────────────────────────

  bool _isVideoUrl(String url) {
    final cleanUrl = url.toLowerCase();
    return cleanUrl.contains('bilibili.com') ||
        cleanUrl.contains('b23.tv') ||
        cleanUrl.contains('youtube.com') ||
        cleanUrl.contains('youtu.be');
  }

  Future<String?> _extractVideoTranscript(String urlStr) async {
    final cleanUrl = urlStr.toLowerCase();
    if (cleanUrl.contains('bilibili.com') || cleanUrl.contains('b23.tv')) {
      return _extractBilibiliTranscript(urlStr);
    } else if (cleanUrl.contains('youtube.com') ||
        cleanUrl.contains('youtu.be')) {
      return _extractYoutubeTranscript(urlStr);
    }
    return null;
  }

  Future<String?> _extractBilibiliTranscript(String urlStr) async {
    try {
      var resolvedUrl = urlStr;
      if (urlStr.contains('b23.tv')) {
        resolvedUrl = await _resolveRedirects(urlStr);
      }

      final bvRegex = RegExp(r'(BV[a-zA-Z0-9]{10})');
      final match = bvRegex.firstMatch(resolvedUrl);
      if (match == null) return null;
      final bvid = match.group(1);

      // 1. Get video details (aid, cid, title, desc)
      final viewUrl = Uri.parse(
        'https://api.bilibili.com/x/web-interface/view?bvid=$bvid',
      );
      final viewResp = await http
          .get(viewUrl)
          .timeout(const Duration(seconds: 10));
      if (viewResp.statusCode != 200) return null;

      final viewJson = jsonDecode(viewResp.body);
      if (viewJson['code'] != 0) return null;

      final data = viewJson['data'];
      final aid = data['aid'];
      final cid = data['cid'];
      final title = data['title'] ?? '';
      final desc = data['desc'] ?? '';

      // 2. Get subtitles list
      final playerUrl = Uri.parse(
        'https://api.bilibili.com/x/player/v2?cid=$cid&aid=$aid',
      );
      final playerResp = await http
          .get(playerUrl)
          .timeout(const Duration(seconds: 10));
      if (playerResp.statusCode != 200) return '视频标题: $title\n视频描述: $desc';

      final playerJson = jsonDecode(playerResp.body);
      if (playerJson['code'] != 0) return '视频标题: $title\n视频描述: $desc';

      final subtitlesList =
          playerJson['data']?['subtitle']?['subtitles'] as List<dynamic>?;
      if (subtitlesList == null || subtitlesList.isEmpty) {
        return '视频标题: $title\n视频描述: $desc';
      }

      // Find the first subtitle track (e.g. Chinese)
      var subUrlStr = subtitlesList.first['subtitle_url'] as String;
      if (subUrlStr.startsWith('//')) {
        subUrlStr = 'https:$subUrlStr';
      }

      // 3. Download and parse subtitle JSON
      final subResp = await http
          .get(Uri.parse(subUrlStr))
          .timeout(const Duration(seconds: 10));
      if (subResp.statusCode != 200) return '视频标题: $title\n视频描述: $desc';

      final subJson = jsonDecode(subResp.body);
      final body = subJson['body'] as List<dynamic>?;
      if (body == null || body.isEmpty) return '视频标题: $title\n视频描述: $desc';

      final transcriptBuffer = StringBuffer();
      for (final item in body) {
        final content = item['content'] as String? ?? '';
        final from = item['from'] as double? ?? 0.0;
        final min = (from / 60).floor();
        final sec = (from % 60).floor();
        final timeStr =
            '[${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}]';
        transcriptBuffer.writeln('$timeStr $content');
      }

      return '视频标题: $title\n视频内容字幕:\n${transcriptBuffer.toString()}';
    } catch (e) {
      debugPrint('Error Bilibili transcript: $e');
      return null;
    }
  }

  Future<String> _resolveRedirects(String urlStr) async {
    var uri = Uri.parse(urlStr);
    var client = http.Client();
    try {
      var request = http.Request('GET', uri)..followRedirects = false;
      var response = await client.send(request);
      if (response.isRedirect) {
        final redirectUrl = response.headers['location'];
        if (redirectUrl != null) {
          return redirectUrl;
        }
      }
    } catch (_) {}
    return urlStr;
  }

  Future<String?> _extractYoutubeTranscript(String urlStr) async {
    try {
      var videoId = '';
      if (urlStr.contains('youtu.be/')) {
        videoId = urlStr.split('youtu.be/')[1].split('?')[0];
      } else if (urlStr.contains('v=')) {
        videoId = urlStr.split('v=')[1].split('&')[0];
      }

      if (videoId.isEmpty) return null;

      final yt = yt_explode.YoutubeExplode();
      try {
        final video = await yt.videos.get(videoId);
        final title = video.title;

        final manifest = await yt.videos.closedCaptions.getManifest(videoId);
        if (manifest.tracks.isEmpty) {
          return '视频标题: $title\n(该视频未提供字幕轨道)';
        }

        final trackInfo = manifest.tracks.firstWhere(
          (t) =>
              t.language.code.startsWith('zh') ||
              t.language.code.startsWith('cn'),
          orElse: () => manifest.tracks.first,
        );

        final track = await yt.videos.closedCaptions.get(trackInfo);
        final transcriptBuffer = StringBuffer();
        for (final caption in track.captions) {
          final min = (caption.offset.inSeconds / 60).floor();
          final sec = (caption.offset.inSeconds % 60).floor();
          final timeStr =
              '[${min.toString().padLeft(2, '0')}:${sec.toString().padLeft(2, '0')}]';
          transcriptBuffer.writeln('$timeStr ${caption.text}');
        }

        return '视频标题: $title\n视频内容字幕:\n${transcriptBuffer.toString()}';
      } finally {
        yt.close();
      }
    } catch (e) {
      debugPrint('Error YouTube transcript via youtube_explode: $e');
      return null;
    }
  }

  /// Fetches a web page or video captions, extracts its text, and returns a markdown summary.
  Future<String?> summarizeWebPage(
    String urlStr, {
    SummaryStyle style = SummaryStyle.insight,
  }) async {
    try {
      String? textContent;
      bool isVideo = _isVideoUrl(urlStr);

      if (isVideo) {
        textContent = await _extractVideoTranscript(urlStr);
      }

      // If it's not a video or video transcript extraction returned null, fallback to Jina Reader
      if (textContent == null || textContent.trim().isEmpty) {
        final jinaUrl = Uri.parse('https://r.jina.ai/$urlStr');
        final resp = await http
            .get(jinaUrl)
            .timeout(const Duration(seconds: 15));
        if (resp.statusCode == 200) {
          textContent = resp.body.trim();
        }
      }

      if (textContent == null || textContent.isEmpty) {
        final searchPrompt = '请总结以下网站核心内容: $urlStr';
        return _generate(searchPrompt);
      }

      final clippedTextContent = _clipSourceText(textContent);
      String promptText = '';
      switch (style) {
        case SummaryStyle.outline:
          promptText =
              '''
请作为内容提取助手，为以下网页或视频内容生成一份极简大纲。
要求：
1. 提取视频/文章标题与一句话核心观点。
2. 列出核心篇章脉络和核心要点。
3. 全程使用中文，字数控制在150字以内，排版要紧凑美观。

网页或视频内容：
$clippedTextContent
''';
          break;
        case SummaryStyle.insight:
          promptText =
              '''
请作为深度内容分析助手，总结以下网页或视频的详细核心内容。
要求：
1. 提取文章/视频标题、核心观点以及主要论据。
2. 使用 Markdown 格式输出，如果文本中含有视频时间戳字幕，请按照章节段落和大致时间线锚点进行段落划分并总结。
3. 解释文中包含的核心概念或专业名词。
4. 全程使用中文，深度整理并生成一份详实、深刻的阅读摘要，字数限制在 300 至 500 字之间（不多不少刚刚好，保证高信息浓度，绝无废话）。

网页或视频内容：
$clippedTextContent
''';
          break;
        case SummaryStyle.actionable:
          promptText =
              '''
请作为高效任务转化助手，将以下网页或视频中的内容提炼并转化为实际可执行的“行动指南”。
要求：
1. 提取文章/视频的主题。
2. 剔除废话，直接将内容中的步骤、建议、方法转化为标准的 Checkbox 待办事项列表（例如 `- [ ] 行动项1`）。
3. 全程使用中文，直接输出待办列表，排版清晰。

网页或视频内容：
$clippedTextContent
''';
          break;
      }

      return _generate(promptText);
    } catch (e) {
      assert(() {
        debugPrint('[AIService] Web/Video summarize error: $e');
        return true;
      }());
      return null;
    }
  }

  /// Refines a voice input draft converting oral speech to formal structured text.
  Future<String?> polishVoiceDraft(String rawDraft) async {
    if (rawDraft.trim().isEmpty) return null;

    final prompt =
        '''
你是一个专业的语音草稿深度重塑与精修写作助手。
请在【保持用户原本核心意思完全不变】的前提下完成以下润色：
1. 修复明显的字词和听写错漏。
2. 剔除一切口语语气词（如“呃”、“啊”、“然后”），用紧凑书面语代替。
3. 根据语义逻辑合理进行结构化分段，并使用 Markdown 加粗关键事实/结论句以提升可读性。
4. 输出字数长度必须与原文相近，禁止大幅扩写或引入新主题。

请直接输出修改后的文本，禁止任何解释或引导性前言。

语音输入原文：
$rawDraft
''';
    return _generate(prompt);
  }

  /// Summarizes a mixed note containing text, OCR results of images, and potentially audio transcripts.
  Future<String?> summarizeMixedNote(
    String noteTitle,
    String content,
    List<Uint8List> images,
  ) async {
    final ocrBuffer = StringBuffer();
    for (int i = 0; i < images.length; i++) {
      try {
        final text = await extractTextFromImage(images[i]);
        if (text != null && text.trim().isNotEmpty) {
          ocrBuffer.writeln('【图片 ${i + 1} 提取出的文字】:\n$text\n');
        }
      } catch (e) {
        debugPrint('OCR extraction failed for image $i: $e');
      }
    }

    final ocrCombinedText = ocrBuffer.toString();
    final prompt =
        '''
你是一个专业的多媒体笔记整理助手。
当前笔记包含文本正文，以及通过图片提取出的文字内容。
请将以下所有零碎内容融合，提炼并生成一份排版美观、重点突出的深度笔记总结。

笔记标题：$noteTitle
笔记正文：
$content

图片中提取出的文本：
$ocrCombinedText

请直接输出中文总结，并使用 Markdown 格式（包含小标题、重点加粗和核心要点列表）排版，字数必须控制在 250 至 400 字之间（不多不少刚刚好，禁止任何总结性前缀引导句，直入重点）。
''';
    return _generate(prompt);
  }

  // ==========================================================================
  // PUBLIC API
  // ==========================================================================

  // ── Note summarisation ───────────────────────────────────────────────────

  /// Returns a 2-3 sentence Chinese summary of the note, or `null` on failure.
  ///
  /// [title] — the note's display title.
  /// [content] — the note's body text (plain text or markdown).
  Future<String?> summarizeNote(String title, String content) async {
    if (title.trim().isEmpty && content.trim().isEmpty) return null;

    final prompt =
        '''
你是一个高级知识整理专家。请为这篇笔记内容进行深度结构化总结。
要求：
1. 总结字数必须控制在 250 至 400 字之间。
2. 采用以下排版规范：先用一句话概括核心观点，再用 Markdown 无序列表整理出结构清晰的核心知识要点树，禁止任何“根据笔记显示”等引导性前导句。

笔记标题：$title

笔记内容：
$content
''';

    return _generate(prompt);
  }

  // ── Subtask suggestion ───────────────────────────────────────────────────

  /// Returns a list of 3-5 suggested subtask titles in Chinese.
  ///
  /// Returns an empty list on failure or if DeepSeek returns no usable output.
  Future<List<String>> suggestSubTasks(
    String taskTitle,
    String? description,
  ) async {
    final descPart = (description != null && description.trim().isNotEmpty)
        ? '\n任务描述：$description'
        : '';

    final prompt =
        '''
你是一位任务管理专家。请为以下任务拆解出 3 到 8 个具体的高质量子任务。
要求：
- 每个子任务用一个明确的动作词开头描述（如“收集数据”、“起草方案”），每行一个子任务
- 只输出子任务列表，不要添加序号、符号或额外说明

任务名称：$taskTitle$descPart
''';

    final raw = await _generate(prompt);
    if (raw == null || raw.isEmpty) return const [];

    final lines = raw
        .split('\n')
        .map((l) => l.trim())
        .where((l) => l.isNotEmpty)
        .toList(growable: false);

    // Return at most 5 items.
    return lines.length > 5 ? lines.sublist(0, 5) : lines;
  }

  // ── Task prioritisation ──────────────────────────────────────────────────

  /// Asks DeepSeek to reorder [tasks] by smart priority.
  ///
  /// The AI considers urgency, importance, due dates, and dependencies.
  /// Returns the reordered list, or the original list on failure.
  Future<List<Task>> prioritizeTasks(List<Task> tasks) async {
    if (tasks.isEmpty) return tasks;

    // Build the exact format requested by the user: title, time, priority/urgency, and current index.
    final tasksJson = [];
    for (int i = 0; i < tasks.length; i++) {
      final t = tasks[i];
      tasksJson.add({
        'id': t.id,
        '任务标题':
            t.title +
            (t.description.isNotEmpty ? '（任务描述：${t.description}）' : ''),
        '任务时间': t.dueDate?.toIso8601String() ?? '无截止时间',
        '紧急情况': t.priority.name, // low, normal, high, urgent
        '当前在任务列表中的顺序': i,
      });
    }

    final prompt =
        '''
你是一个极其聪明的个人助理与时间管理大师。请根据用户提供的待办任务列表，为它们安排最科学、最符合人类实际工作直觉的执行顺序。

当前系统时间：${DateTime.now().toIso8601String()}

输入任务列表（JSON格式）：
${jsonEncode(tasksJson)}

排序指导原则（根据任务的时间和紧急情况进行智能编排）：
1. 【语义理解优先】：分析“任务标题”，优先将真实的、有明确工作意义且急需处理的实际工作（如“去看备忘录里到底有什么错误，记得做”）排在前面；而将无实质意义的临时测试任务（如“111”、“测试”、“sss”）排在后面。
2. 【时间与紧急程度智能结合】：
   - 标注为“urgent(紧急)”或“high(高)”的重点任务应当优先。
   - 刚过期不久或截止时间临近的任务，比起已经过期很久且无实质内容的任务，更应优先处理。
   - 无截止时间的任务统一排在有截止时间任务的后面。
3. 【任务依赖关系】：如果任务之间存在逻辑依赖，前置任务必须排在后置任务的前面。

要求：
- 请分析所有任务的优选顺序，最后仅输出一个包含排序后任务 ID 的 JSON 字符串数组，例如：["id_1", "id_2", "id_3"]
- 绝对不要添加任何 markdown 代码块标识（如 ```json 等），只返回该 JSON 数组本身。
''';

    final raw = await _generate(prompt);
    if (raw == null || raw.trim().isEmpty) return tasks;

    List<String> orderedIds = [];
    try {
      final jsonStart = raw.indexOf('[');
      final jsonEnd = raw.lastIndexOf(']');
      if (jsonStart != -1 && jsonEnd != -1 && jsonEnd > jsonStart) {
        final jsonStr = raw.substring(jsonStart, jsonEnd + 1);
        final list = jsonDecode(jsonStr);
        if (list is List) {
          orderedIds = list.map((e) => e.toString().trim()).toList();
        }
      }
    } catch (_) {
      // Fallback
    }

    if (orderedIds.isEmpty) {
      orderedIds = raw
          .split('\n')
          .map((l) {
            var cleaned = l.trim();
            cleaned = cleaned.replaceFirst(RegExp(r'^[-*+]\s+'), '');
            cleaned = cleaned.replaceFirst(RegExp(r'^\d+\.\s+'), '');
            cleaned = cleaned.replaceAll('"', '').replaceAll("'", '');
            return cleaned.trim();
          })
          .where((l) => l.isNotEmpty)
          .toList();
    }

    if (orderedIds.isEmpty) return tasks;

    // Map id → Task for quick lookup.
    final taskMap = {for (final t in tasks) t.id: t};

    // Build result in AI-specified order; append any tasks the AI omitted.
    final result = <Task>[];
    final seen = <String>{};

    for (final id in orderedIds) {
      final task = taskMap[id];
      if (task != null && seen.add(id)) {
        result.add(task);
      }
    }

    // Append tasks not returned by the AI (safety net).
    for (final task in tasks) {
      if (seen.add(task.id)) {
        result.add(task);
      }
    }

    return result;
  }

  // ── Smart / semantic search ───────────────────────────────────────────────

  /// Performs a semantic search over [contents] using the given [query].
  ///
  /// Returns the single best-matching content string, or `null` if nothing
  /// is relevant or an error occurs.
  ///
  /// [contents] — list of plain-text strings to search within.
  Future<String?> smartSearch(String query, List<String> contents) async {
    if (query.trim().isEmpty || contents.isEmpty) return null;

    // Keep content concise to stay within token limits.
    const maxLength = 300;
    final truncated = contents
        .map((c) => c.length > maxLength ? '${c.substring(0, maxLength)}…' : c)
        .toList();

    final indexed = truncated
        .asMap()
        .entries
        .map((e) => '[${e.key}] ${e.value}')
        .join('\n');

    final prompt =
        '''
你是一个语义搜索引擎。根据用户的搜索词，从以下内容列表中找出语义上最相关的一条。

搜索词：$query

内容列表：
$indexed

要求：
- 只输出最相关的那条内容的完整原文（不要包含前缀序号）
- 如果没有相关内容，只输出"无匹配结果"
''';

    final result = await _generate(prompt);
    if (result == null || result == '无匹配结果') return null;
    return result;
  }

  // ── Ask Knowledge Base ───────────────────────────────────────────────────

  /// Q&A over retrieved context items.
  Future<String?> askKnowledgeBase(
    String question,
    List<Map<String, String>> contextItems, {
    List<Map<String, String>> conversationHistory = const [],
    String memorySummary = '',
    bool includeReferenceDocuments = true,
  }) async {
    if (question.trim().isEmpty) return null;

    final contextBuffer = StringBuffer();
    for (
      int i = 0;
      i < (includeReferenceDocuments ? contextItems.length : 0);
      i++
    ) {
      final item = contextItems[i];
      contextBuffer.writeln(
        '=== 文档内容 #${i + 1} [类型: ${item['type'] ?? '未指定'}, 标题: ${item['title'] ?? '未指定'}] ===',
      );
      contextBuffer.writeln(item['content'] ?? '');
      contextBuffer.writeln(
        '==================================================\n',
      );
    }

    final prompt =
        '''
你是一个 SyncNote 智能知识库专属助理。请根据用户提供的参考文档内容回答问题。
优化标准：
1. 动态字数：如果问题简单，请用 100-150 字精练回答；如果问题复杂，可使用 Markdown 用 300-500 字详尽拆解。
2. 拒绝废话：禁止任何开头客套或引导词，字字珠玑，每一句都必须正面回答核心问题。
3. 严格受限：如果文档无匹配信息，请明确说明“知识库未找到相关记录”，接着结合你的知识友好地给出推测性答复。

用户问题：$question

对话长期记忆摘要：
${memorySummary.isEmpty ? '无' : memorySummary}

最近对话（按时间顺序）：
${jsonEncode(conversationHistory)}

参考文档内容：
${contextBuffer.toString()}
''';

    return _generate(prompt);
  }

  Future<String?> summarizeConversationMemory(
    String previousSummary,
    List<Map<String, String>> messages,
  ) {
    return _generate('''
请把已有记忆摘要与最近对话压缩成不超过 800 字的中文事实记忆，只保留用户目标、约束、决定和未解决问题，不保存寒暄或推理过程。
已有摘要：$previousSummary
最近对话：${jsonEncode(messages)}
''');
  }

  // ── Daily Briefing & Evening Reflection ───────────────────────────────────

  /// Generates a customized, encouraging daily briefing based on tasks and diaries.
  Future<String?> generateDailyBriefing(
    List<Task> todayTasks,
    List<DiaryEntry> recentDiaries,
  ) async {
    final tasksJson = todayTasks
        .map(
          (t) => {
            'title': t.title,
            'priority': t.priority.name,
            'dueDate': t.dueDate?.toIso8601String(),
            'description': t.description,
          },
        )
        .toList();

    final diariesJson = buildDailyBriefingDiaryPayload(recentDiaries);

    final prompt =
        '''
你是一个温暖且充满智慧的个人生活教练。请根据用户今天的待办任务和最近的日记，为用户生成今日行程简报与心灵航标。
要求：
1. 报告总字数必须控制在 250 至 350 字之间（不多不少刚刚好）。
2. 第一部分（约 150 字）：分析今天有哪些重要/紧急的任务，给出科学合理的精力分配建议，并精简列出。
3. 第二部分（约 100 字）：结合最近的日记和心情状态，给出一两句直击心灵的温暖鼓励与反馈。
4. 排版规范：使用 Markdown。第一行直接以主标题开始，禁止包含“以下是为您生成的行程简报”等任何铺垫性客套话。

今日待办任务：
${jsonEncode(tasksJson)}

最近日记内容与心情：
${jsonEncode(diariesJson)}
''';

    return _generate(prompt);
  }

  /// Generates a dynamic, sympathetic evening review report.
  Future<String?> generateEveningReflection(
    List<Task> todayTasks,
    List<DiaryEntry> todayDiaries,
  ) async {
    final tasksJson = todayTasks
        .map(
          (t) => {
            'title': t.title,
            'priority': t.priority.name,
            'status': t.status.name,
          },
        )
        .toList();

    final diariesJson = buildEveningReflectionDiaryPayload(todayDiaries);

    final prompt =
        '''
你是一个富有共情力的晚间生活教练。请根据用户今天的任务完成情况和记录的日记，生成今日暮省总结。
要求：
1. 报告总字数必须控制在 200 至 300 字之间（不多不少刚刚好）。
2. 第一部分（约 120 字）：以温暖的口吻梳理今日已完成与未完成的任务，对未完成的任务给予合理安慰并引导用户释怀。
3. 第二部分（约 100 字）：根据今天日记透露的情绪进行温柔的心灵对话，提供放松身心、安然入睡的暖心赠言。
4. 排版规范：使用 Markdown 形式，禁止任何前置废话或总结引导，直接以 Markdown 标题或核心金句开始。

今日任务列表：
${jsonEncode(tasksJson)}

今日日记与心情：
${jsonEncode(diariesJson)}
''';

    return _generate(prompt);
  }

  // ── Mood and Life Analysis ───────────────────────────────────────────────

  /// Reviews the user's emotional and lifestyle patterns based on past diaries.
  Future<String?> analyzeMoodAndLife(List<DiaryEntry> entries) async {
    if (entries.isEmpty) return '暂无足够的日记记录进行心灵复盘分析。';

    final diariesJson = entries
        .map(
          (d) => {
            'date': d.date.toIso8601String().split('T').first,
            'content': d.content,
            'mood': d.mood.name,
          },
        )
        .toList();

    final prompt =
        '''
你是一位专业的心理咨询师与生活教练。请根据用户提供的一段时间内的日记和心情记录，生成一份深度的“心灵/情绪健康复盘报告”。
要求：
1. 报告字数必须限制在 300 至 500 字之间。
2. 包含以下板块：
   - 📈 【情绪走势分析】：提炼本阶段的情绪曲线规律，分析可能的焦虑/平静成因。
   - 💡 【心理疗愈建议】：针对发现的心理压力，提供 2 条具体、非套路、可操作的自我调节建议。
   - 🌱 【心灵赠言】：以一两句极具共鸣和治愈力量的金句作为结尾。
3. 风格规范：使用 Markdown 排版。语言要有同理心且精炼，禁止客套前缀。

日记记录列表：
${jsonEncode(diariesJson)}
''';

    return _generate(prompt, useThinking: true);
  }

  // ── Growth / Achievement Analysis ────────────────────────────────────────

  /// Analyzes tasks completed and diaries to generate a weekly achievement and growth report.
  Future<String?> analyzeGrowth(
    List<Task> completedTasks,
    List<DiaryEntry> diaries,
  ) async {
    final tasksJson = completedTasks
        .map(
          (t) => {
            'title': t.title,
            'priority': t.priority.name,
            'dueDate': t.dueDate?.toIso8601String(),
            'completedAt': t.effectiveCompletedAt?.toIso8601String(),
          },
        )
        .toList();

    final diariesJson = diaries
        .map(
          (d) => {
            'date': d.date.toIso8601String().split('T').first,
            'mood': d.mood.name,
          },
        )
        .toList();

    final prompt =
        '''
你是一个自我管理与个人效能导师。请根据用户本周完成的任务与心情记录，撰写“周度成长与目标达成分析”。
要求：
1. 字数必须限制在 300 至 500 字之间。
2. 包含以下板块：
   - 🎯 【成就与驱动力】：梳理进展，肯定高优先级任务的完成，分析背后的习惯。
   - 📊 【效能短板与反思】：对照情绪波动，找出精力流失的时间节点。
   - 🚀 【下周战术建议】：提供 2 个实用的微小改变建议。
3. 风格规范：使用 Markdown，字字珠玑，重点突出。

本周已完成任务：
${jsonEncode(tasksJson)}

本周心情与日记概要：
${jsonEncode(diariesJson)}
''';

    return _generate(prompt, useThinking: true);
  }

  // ── Note Keywords Extraction & Recommendations (Semantic Linking) ─────────

  /// Generates 3-4 semantic keywords/tags representing the note's core topics.
  Future<List<String>> generateKeywordsForNote(
    String title,
    String content,
  ) async {
    if (title.trim().isEmpty && content.trim().isEmpty) return const [];

    final prompt =
        '''
你是一个语义分析专家。请根据以下笔记的标题和内容，提炼出 3 至 4 个最能代表该笔记核心技术、话题或主题的专业词/核心词。
要求：
- 仅返回一个包含这些核心词的 JSON 字符串数组，例如：["Firestore", "代理", "Flutter"]
- 绝对不要添加任何 markdown 代码块标识（如 ```json 等），只返回该 JSON 数组本身
- 若无法提炼出任何有意义的概念，返回空数组 []

笔记标题：$title
笔记正文：
$content
''';

    final result = await _generate(prompt);
    if (result == null) return const [];

    try {
      var jsonStr = result.trim();
      if (jsonStr.startsWith('```')) {
        final lines = jsonStr.split('\n');
        if (lines.first.startsWith('```json') ||
            lines.first.startsWith('```')) {
          lines.removeAt(0);
        }
        if (lines.isNotEmpty && lines.last.startsWith('```')) {
          lines.removeLast();
        }
        jsonStr = lines.join('\n').trim();
      }
      final parsed = jsonDecode(jsonStr);
      if (parsed is List) {
        return parsed.map((e) => e.toString()).toList();
      }
    } catch (e) {
      debugPrint(
        'Error parsing keywords JSON response: $e\nResponse raw: $result',
      );
    }
    return const [];
  }

  /// Evaluates candidates and returns the IDs of the 2-3 most semantically related notes.
  Future<List<String>> recommendRelatedNotes({
    required String currentId,
    required String currentTitle,
    required String currentContent,
    required List<String> currentKeywords,
    required List<Map<String, dynamic>> candidateNotes,
  }) async {
    if (candidateNotes.isEmpty) return const [];

    final prompt =
        '''
你是一个知识关联专家。请从给定的候选笔记列表中，挑选出与当前编辑笔记语义关联最密切的 2-3 篇笔记。

当前编辑的笔记：
ID: $currentId
标题：$currentTitle
正文内容：
$currentContent
核心概念词：${jsonEncode(currentKeywords)}

候选笔记列表（包含ID、标题和核心词）：
${jsonEncode(candidateNotes)}

要求：
- 请仅返回一个包含最相关候选笔记 ID 的 JSON 字符串数组，如：["id_1", "id_2"]
- 绝对不要添加任何 markdown 代码块标识（如 ```json 等），只返回该 JSON 数组本身。
- 若没有语义关联的笔记，请直接返回空数组 []
''';

    final result = await _generate(prompt);
    if (result == null) return const [];

    try {
      var jsonStr = result.trim();
      if (jsonStr.startsWith('```')) {
        final lines = jsonStr.split('\n');
        if (lines.first.startsWith('```json') ||
            lines.first.startsWith('```')) {
          lines.removeAt(0);
        }
        if (lines.isNotEmpty && lines.last.startsWith('```')) {
          lines.removeLast();
        }
        jsonStr = lines.join('\n').trim();
      }
      final parsed = jsonDecode(jsonStr);
      if (parsed is List) {
        return parsed.map((e) => e.toString()).toList();
      }
    } catch (e) {
      debugPrint(
        'Error parsing related notes JSON response: $e\nResponse raw: $result',
      );
    }
    return const [];
  }

  // ── Memo Smart Conversion ───────────────────────────────────────────────

  /// Parses memo content and decides whether to output JSON for task conversion
  /// or markdown for note extension.
  Future<Map<String, dynamic>?> convertMemo(String content) async {
    if (content.trim().isEmpty) return null;

    final nowStr = DateTime.now().toLocal().toString();
    final prompt =
        '''
你是一个备忘录转换专家。今天的当前日期和时间是：$nowStr。
用户有一条备忘录内容如下：
"""
$content
"""
请分析该内容，并【只返回一个 JSON 对象】（不要包含 ```json 等标记，禁止任何引导词）：
如果更适合转为待办任务（包含动作、时间暗示、清单）：
- 返回格式：
{
  "type": "task",
  "title": "任务标题",
  "dueDate": "YYYY-MM-DDTHH:mm:ss（如果推断不出具体时间，则设为 null。请根据当前系统时间：$nowStr，结合备忘录中的相对时间词如'今晚'、'明天'、'今天下午'等，精准换算出绝对的年-月-日及时间格式）",
  "priority": "优先级，必须是 'low'、'normal'、'high'、'urgent' 之一。判断准则：
    - 'low': 琐碎日常小事、备忘、无截止时间压力（如：去超市买水，有空看看书）
    - 'normal': 常规学习/工作事务，无明确催促语气词（如：写作业，完成周报）
    - 'high': 有明确截止时间、较重要或带有催促或警告字眼（如：今晚八点前交材料，今天必须搞定PPT）
    - 'urgent': 极其紧急、有核心危机或明确命令语气立即执行（如：明早九点开会千万别迟到！服务器崩了，立刻修复！）"
}

如果更适合转为知识笔记（日记片段、技术概念、读书笔记、长文）：
- 返回格式：
{
  "type": "note",
  "title": "概括主题标题",
  "content": "格式化排版并合理扩写的 Markdown 正文"
}

【边界容错规则】：
- 若输入是无意义内容（如"111"、"sss"、乱码），请判定为 task，返回：{"type": "task", "title": "临时未分类备忘录", "dueDate": null, "priority": "normal"}

【示例一】
当前时间为：2026-07-09 12:13:00.000
输入：今晚8点和李明打电话商量项目
输出：{"type": "task", "title": "和李明打电话商量项目", "dueDate": "2026-07-09T20:00:00", "priority": "normal"}

【示例二】
当前时间为：2026-07-09 12:13:00.000
输入：明天下午三点前必须交周报，不然扣工资
输出：{"type": "task", "title": "提交周报", "dueDate": "2026-07-10T15:00:00", "priority": "high"}
''';

    final result = await _generate(prompt);
    if (result == null) return null;

    try {
      // Strip markdown code block wrappers if any
      var jsonStr = result.trim();
      if (jsonStr.startsWith('```')) {
        final lines = jsonStr.split('\n');
        if (lines.first.startsWith('```json') ||
            lines.first.startsWith('```')) {
          lines.removeAt(0);
        }
        if (lines.isNotEmpty && lines.last.startsWith('```')) {
          lines.removeLast();
        }
        jsonStr = lines.join('\n').trim();
      }
      return jsonDecode(jsonStr) as Map<String, dynamic>;
    } catch (e) {
      debugPrint(
        'Error parsing convertMemo JSON response: $e\nResponse raw: $result',
      );
      return null;
    }
  }

  /// Sends a custom prompt to DeepSeek and returns the response.
  Future<String?> requestCustomPrompt(String prompt) async {
    return _generate(prompt);
  }

  // ── Diagnostics ───────────────────────────────────────────────────────────

  /// Returns how many AI requests have been made today.
  int get todayRequestCount => _requestCount;

  /// Returns how many requests remain in today's quota.
  int get remainingQuota => AppConfig.maxDailyAiRequests - _requestCount;
}
