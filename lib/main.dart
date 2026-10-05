import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:video_player/video_player.dart';
import 'package:cached_network_image/cached_network_image.dart';
import 'package:dio/dio.dart';
import 'package:gal/gal.dart';
import 'package:path_provider/path_provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'AI Studio',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        primaryColor: const Color(0xFF6366F1),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF6366F1),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const HomeScreen(),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final TextEditingController _promptController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();

  bool _isVideo = false;
  String _aspectRatio = "9:16";
  bool _isLoading = false;
  bool _isSaving = false;
  String _loadingMessage = "";
  String? _resultUrl;
  VideoPlayerController? _videoController;

  @override
  void initState() {
    super.initState();
    _loadApiKey();
  }

  Future<void> _loadApiKey() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _apiKeyController.text = prefs.getString("FAL_API_KEY") ?? "";
    });
  }

  Future<void> _saveApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString("FAL_API_KEY", key.trim());
  }

  Future<void> _generateImage(String apiKey, String prompt) async {
    setState(() => _loadingMessage = "ဓါတ်ပုံ ဖန်တီးနေပါသည်...");

    final response = await http.post(
      Uri.parse("https://fal.run/fal-ai/flux/schnell"),
      headers: {
        "Authorization": "Key $apiKey",
        "Content-Type": "application/json",
      },
      body: jsonEncode({
        "prompt": prompt,
        "image_size": _aspectRatio == "9:16"
            ? "portrait_16_9"
            : (_aspectRatio == "16:9" ? "landscape_16_9" : "square_hd"),
        "num_images": 1,
      }),
    );

    if (response.statusCode == 200) {
      final data = jsonDecode(response.body);
      final imageUrl = data["images"][0]["url"];
      setState(() {
        _resultUrl = imageUrl;
        _isLoading = false;
      });
    } else {
      throw Exception("Image error: ${response.body}");
    }
  }

  Future<void> _generateVideo(String apiKey, String prompt) async {
    setState(() => _loadingMessage = "Queue စောင့်ဆိုင်းနေပါသည်...");

    final queueResponse = await http.post(
      Uri.parse("https://queue.fal.run/fal-ai/ltx-video"),
      headers: {
        "Authorization": "Key $apiKey",
        "Content-Type": "application/json",
      },
      body: jsonEncode({
        "prompt": prompt,
        "aspect_ratio": _aspectRatio,
      }),
    );

    if (queueResponse.statusCode != 200 && queueResponse.statusCode != 201) {
      throw Exception("Queue request failed: ${queueResponse.body}");
    }

    final queueData = jsonDecode(queueResponse.body);
    final statusUrl = queueData["status_url"];
    final responseUrl = queueData["response_url"];

    bool completed = false;
    int attempts = 0;

    while (!completed && attempts < 40) {
      await Future.delayed(const Duration(seconds: 3));
      attempts++;

      final statusCheck = await http.get(
        Uri.parse(statusUrl),
        headers: {"Authorization": "Key $apiKey"},
      );

      if (statusCheck.statusCode == 200) {
        final statusBody = jsonDecode(statusCheck.body);
        final status = statusBody["status"];

        if (status == "COMPLETED") {
          completed = true;
          setState(() => _loadingMessage = "ဗီဒီယို ရယူနေပါသည်...");

          final resultCheck = await http.get(
            Uri.parse(responseUrl),
            headers: {"Authorization": "Key $apiKey"},
          );

          if (resultCheck.statusCode == 200) {
            final resultBody = jsonDecode(resultCheck.body);
            final videoUrl = resultBody["video"]["url"];

            _videoController = VideoPlayerController.networkUrl(Uri.parse(videoUrl))
              ..initialize().then((_) {
                setState(() {
                  _resultUrl = videoUrl;
                  _isLoading = false;
                });
                _videoController?.setLooping(true);
                _videoController?.play();
              });
          }
        } else {
          setState(() => _loadingMessage = "ဗီဒီယို ဖန်တီးနေဆဲဖြစ်ပါသည် ($status)...");
        }
      }
    }

    if (!completed) {
      throw Exception("Video generation အချိန်ကြာမြင့်နေပါသည်။ နောက်မှ ထပ်စမ်းပါ။");
    }
  }

  Future<void> _startGeneration() async {
    final apiKey = _apiKeyController.text.trim();
    final prompt = _promptController.text.trim();

    if (apiKey.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Fal.ai API Key အရင်ထည့်ပေးပါ")),
      );
      return;
    }

    if (prompt.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Prompt စာသား ရိုက်ထည့်ပေးပါ")),
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _resultUrl = null;
      _videoController?.dispose();
      _videoController = null;
    });

    try {
      if (_isVideo) {
        await _generateVideo(apiKey, prompt);
      } else {
        await _generateImage(apiKey, prompt);
      }
    } catch (e) {
      setState(() => _isLoading = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("Error: $e")),
      );
    }
  }

  Future<void> _saveToGallery() async {
    if (_resultUrl == null) return;
    setState(() => _isSaving = true);

    try {
      final tempDir = await getTemporaryDirectory();
      final ext = _isVideo ? "mp4" : "png";
      final filePath = "${tempDir.path}/ai_${DateTime.now().millisecondsSinceEpoch}.$ext";

      await Dio().download(_resultUrl!, filePath);

      if (_isVideo) {
        await Gal.putVideo(filePath);
      } else {
        await Gal.putImage(filePath);
      }

      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text("Gallery ထဲသို့ သိမ်းဆည်းပြီးပါပြီ!")),
      );
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text("သိမ်းဆည်း၍ မရပါ: $e")),
      );
    } finally {
      setState(() => _isSaving = false);
    }
  }

  @override
  void dispose() {
    _promptController.dispose();
    _apiKeyController.dispose();
    _videoController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("AI Studio"),
        centerTitle: true,
        backgroundColor: const Color(0xFF1E293B),
        actions: [
          IconButton(
            icon: const Icon(Icons.vpn_key),
            onPressed: () {
              showDialog(
                context: context,
                builder: (ctx) => AlertDialog(
                  title: const Text("Fal.ai API Key ထည့်ရန်"),
                  content: TextField(
                    controller: _apiKeyController,
                    decoration: const InputDecoration(
                      hintText: "Key ထည့်ပါ (fal_key_...)",
                    ),
                  ),
                  actions: [
                    TextButton(
                      onPressed: () {
                        _saveApiKey(_apiKeyController.text);
                        Navigator.pop(ctx);
                      },
                      child: const Text("Save"),
                    )
                  ],
                ),
              );
            },
          )
        ],
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(16.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: FilterChip(
                    label: const Center(child: Text("Text to Image")),
                    selected: !_isVideo,
                    onSelected: (val) {
                      setState(() {
                        _isVideo = false;
                        _resultUrl = null;
                      });
                    },
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: FilterChip(
                    label: const Center(child: Text("Text to Video")),
                    selected: _isVideo,
                    onSelected: (val) {
                      setState(() {
                        _isVideo = true;
                        _resultUrl = null;
                      });
                    },
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            TextField(
              controller: _promptController,
              maxLines: 4,
              decoration: InputDecoration(
                hintText: _isVideo
                    ? "ဖန်တီးလိုသော Video prompt ကို ရိုက်ထည့်ပါ..."
                    : "ဖန်တီးလိုသော Image prompt ကို ရိုက်ထည့်ပါ...",
                filled: true,
                fillColor: const Color(0xFF1E293B),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              value: _aspectRatio,
              decoration: InputDecoration(
                labelText: "Aspect Ratio",
                filled: true,
                fillColor: const Color(0xFF1E293B),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
              items: const [
                DropdownMenuItem(value: "9:16", child: Text("9:16 (Shorts / TikTok)")),
                DropdownMenuItem(value: "16:9", child: Text("16:9 (Landscape)")),
                DropdownMenuItem(value: "1:1", child: Text("1:1 (Square)")),
              ],
              onChanged: (val) => setState(() => _aspectRatio = val!),
            ),
            const SizedBox(height: 16),
            ElevatedButton(
              onPressed: _isLoading ? null : _startGeneration,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF6366F1),
                padding: const EdgeInsets.symmetric(vertical: 14),
                shape: BorderRadius.circular(12),
              ),
              child: _isLoading
                  ? const SizedBox(
                      height: 20,
                      width: 20,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : Text(
                      _isVideo ? "Generate Video" : "Generate Image",
                      style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
            ),
            const SizedBox(height: 20),
            if (_isLoading)
              Center(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: Column(
                    children: [
                      const CircularProgressIndicator(),
                      const SizedBox(height: 14),
                      Text(
                        _loadingMessage,
                        textAlign: TextAlign.center,
                        style: const TextStyle(color: Colors.white70),
                      ),
                    ],
                  ),
                ),
              )
            else if (_resultUrl != null) ...[
              Container(
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(12),
                  color: const Color(0xFF1E293B),
                ),
                clipBehavior: Clip.antiAlias,
                child: _isVideo && _videoController != null && _videoController!.value.isInitialized
                    ? AspectRatio(
                        aspectRatio: _videoController!.value.aspectRatio,
                        child: VideoPlayer(_videoController!),
                      )
                    : CachedNetworkImage(
                        imageUrl: _resultUrl!,
                        placeholder: (ctx, url) =>
                            const Center(child: CircularProgressIndicator()),
                        errorWidget: (ctx, url, err) => const Icon(Icons.error),
                      ),
              ),
              const SizedBox(height: 12),
              ElevatedButton.icon(
                onPressed: _isSaving ? null : _saveToGallery,
                icon: const Icon(Icons.download),
                label: Text(_isSaving ? "သိမ်းဆည်းနေပါသည်..." : "Save to Gallery"),
                style: ElevatedButton.styleFrom(
                  backgroundColor: Colors.teal,
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  shape: BorderRadius.circular(10),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
